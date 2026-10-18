//! The internal mixer.
//!
//! One SDL output stream plays a single mixed signal. Every lane is a decoder
//! process piping `f32le` into a ring buffer, and this file does the summing and
//! the filter. Lanes therefore share one clock: no player starts before another,
//! and no change to one lane interrupts the rest.

const std = @import("std");
const device_mod = @import("device.zig");
const Track = @import("../domain/track.zig").Track;

pub const Lane = struct {
    track: Track,
    /// Where playback starts, in seconds into the track.
    start_s: f64,
    /// Master BPM divided by the track's BPM.
    tempo: f32,
    /// Low pass position: 0 closed, 1 open.
    filter: f32,
    /// Keep the pitch while the tempo changes; otherwise pitch follows speed.
    keylock: bool,
    /// Silence before the audio, so the lane starts on a master bar.
    delay_ms: u32 = 0,
};

const sample_rate = device_mod.sample_rate;
const channels = device_mod.channels;
/// Ten milliseconds per pump tick.
const tick_frames = sample_rate / 100;
const ring_frames = sample_rate * 2;
const max_lanes = 8;
/// Audio buffered before a lane starts playing, 100 ms.
const prefill_frames = sample_rate / 10;

/// Milliseconds of decoder buffering before a lane produces sound. The app
/// leads its clock by this much so the playhead matches what is heard.
pub const prefill_ms: u32 = prefill_frames * 1000 / sample_rate;

const Biquad = struct {
    b0: f32 = 1,
    b1: f32 = 0,
    b2: f32 = 0,
    a1: f32 = 0,
    a2: f32 = 0,
    z1: f32 = 0,
    z2: f32 = 0,

    fn setLowPass(self: *Biquad, cutoff_hz: f32) void {
        const hz = std.math.clamp(cutoff_hz, 20, sample_rate * 0.45);
        const w0 = 2 * std.math.pi * hz / sample_rate;
        const cos = @cos(w0);
        const alpha = @sin(w0) / (2 * 0.707);
        const a0 = 1 + alpha;
        self.b0 = ((1 - cos) / 2) / a0;
        self.b1 = (1 - cos) / a0;
        self.b2 = self.b0;
        self.a1 = (-2 * cos) / a0;
        self.a2 = (1 - alpha) / a0;
    }

    fn process(self: *Biquad, input: f32) f32 {
        const out = self.b0 * input + self.z1;
        self.z1 = self.b1 * input - self.a1 * out + self.z2;
        self.z2 = self.b2 * input - self.a2 * out;
        return out;
    }
};

const Slot = struct {
    active: bool = false,
    track_id: u64 = 0,
    start_s: f64 = -1,
    tempo: f32 = 1,
    keylock: bool = true,
    filter: f32 = 1,
    applied_filter: f32 = -1,
    child: ?std.process.Child = null,
    /// Decoder stdout, nonblocking, drained by the pump thread.
    file: ?std.Io.File = null,
    quit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ring: []f32 = &.{},
    head: usize = 0,
    tail: usize = 0,
    /// Channel of the next sample, so a split read keeps frame alignment.
    channel_cursor: usize = 0,
    eq: [channels]Biquad = @splat(.{}),
    /// False until the decoder has buffered enough to start cleanly. A lane
    /// that starts mid-stream is offset from every other lane.
    ready: bool = false,
    mute_until_ns: i128 = 0,
};

pub const Mixer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    device: device_mod.Device = .{},
    slots: [max_lanes]Slot = undefined,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    out: []f32 = &.{},
    ticks: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Mixer {
        var self = Mixer{
            .allocator = allocator,
            .io = io,
            .out = allocator.alloc(f32, tick_frames * channels) catch &.{},
        };
        for (&self.slots) |*slot| slot.* = .{};
        for (&self.slots) |*slot| {
            slot.ring = allocator.alloc(f32, ring_frames * channels) catch break;
        }
        return self;
    }

    pub fn deinit(self: *Mixer) void {
        self.stop();
        self.running.store(false, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.device.close();
        for (&self.slots) |*slot| {
            if (slot.ring.len > 0) self.allocator.free(slot.ring);
        }
        if (self.out.len > 0) self.allocator.free(self.out);
        self.* = undefined;
    }

    /// Replaces the set of playing lanes. Lanes already playing keep their
    /// decoder unless their position or tempo changed; filter changes are
    /// applied in place, so they never interrupt the audio.
    pub fn play(self: *Mixer, lanes: []const Lane) void {
        self.ensureThread();
        self.device.open() catch return;

        self.mutex.lockUncancelable(self.io);

        var used: [max_lanes]bool = @splat(false);
        var finished: [max_lanes]*Slot = @splat(undefined);
        var finished_count: usize = 0;
        for (lanes) |lane| {
            var target: ?*Slot = null;
            for (&self.slots, 0..) |*slot, index| {
                if (!used[index] and slot.active and slot.track_id == lane.track.id) {
                    used[index] = true;
                    target = slot;
                    break;
                }
            }
            if (target == null) {
                for (&self.slots, 0..) |*slot, index| {
                    if (!used[index] and !slot.active) {
                        used[index] = true;
                        target = slot;
                        break;
                    }
                }
            }
            if (target) |slot| self.apply(slot, lane);
        }

        for (&self.slots, 0..) |*slot, index| {
            if (used[index] or !slot.active) continue;
            self.beginRelease(slot);
            finished[finished_count] = slot;
            finished_count += 1;
        }

        self.mutex.unlock(self.io);
        for (finished[0..finished_count]) |slot| self.endRelease(slot);
    }

    pub fn stop(self: *Mixer) void {
        var finished: [max_lanes]*Slot = @splat(undefined);
        var finished_count: usize = 0;

        self.mutex.lockUncancelable(self.io);
        for (&self.slots) |*slot| {
            if (slot.active) {
                self.beginRelease(slot);
                finished[finished_count] = slot;
                finished_count += 1;
            }
        }
        self.mutex.unlock(self.io);

        for (finished[0..finished_count]) |slot| self.endRelease(slot);
    }

    pub fn active(self: *const Mixer) bool {
        for (&self.slots) |*slot| {
            if (slot.active) return true;
        }
        return false;
    }

    fn ensureThread(self: *Mixer) void {
        if (self.thread != null) return;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, pumpMain, .{self}) catch null;
    }

    fn apply(self: *Mixer, slot: *Slot, lane: Lane) void {
        const same_track = slot.active and slot.track_id == lane.track.id;
        const same_start = @abs(slot.start_s - lane.start_s) < 0.001;
        const same_tempo = @abs(slot.tempo - lane.tempo) < 0.0005 and slot.keylock == lane.keylock;

        if (!same_track or !same_start or !same_tempo) {
            self.beginRelease(slot);
            self.endRelease(slot);
            self.start(slot, lane);
        }

        slot.filter = lane.filter;
        if (lane.delay_ms > 0) {
            slot.mute_until_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds +
                @as(i128, lane.delay_ms) * std.time.ns_per_ms;
        } else {
            slot.mute_until_ns = 0;
        }
    }

    fn start(self: *Mixer, slot: *Slot, lane: Lane) void {
        if (lane.track.file_path.len == 0) return;
        if (slot.ring.len == 0) return;

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.allocator);

        var owned: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (owned.items) |text| self.allocator.free(text);
            owned.deinit(self.allocator);
        }

        const start_arg = std.fmt.allocPrint(self.allocator, "{d:.3}", .{lane.start_s}) catch return;
        owned.append(self.allocator, start_arg) catch return;

        const ratio = std.math.clamp(lane.tempo, 0.5, 2.0);
        const chain = if (lane.keylock)
            std.fmt.allocPrint(self.allocator, "atempo={d:.4}", .{ratio}) catch return
        else
            std.fmt.allocPrint(self.allocator, "asetrate={d:.0},aresample={d}", .{ 44100 * ratio, sample_rate }) catch return;
        owned.append(self.allocator, chain) catch return;

        const rate = std.fmt.allocPrint(self.allocator, "{d}", .{sample_rate}) catch return;
        owned.append(self.allocator, rate) catch return;

        // A zero seek still makes ffmpeg seek, and MP3 seek granularity shifts
        // the audio by more than a millisecond. Start at the file head instead.
        argv.appendSlice(self.allocator, &.{
            "ffmpeg", "-hide_banner", "-loglevel", "error",
        }) catch return;
        if (lane.start_s > 0.001) {
            argv.appendSlice(self.allocator, &.{ "-ss", start_arg }) catch return;
        }
        argv.appendSlice(self.allocator, &.{
            "-i", lane.track.file_path, "-af", chain,
            "-f", "f32le",              "-ac", "2",
            "-ar", rate,                "-",
        }) catch return;

        _ = &argv;
        const child = std.process.spawn(self.io, .{
            .argv = argv.items,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .inherit,
        }) catch return;

        slot.active = true;
        slot.track_id = lane.track.id;
        slot.start_s = lane.start_s;
        slot.tempo = lane.tempo;
        slot.keylock = lane.keylock;
        slot.filter = lane.filter;
        slot.applied_filter = -1;
        slot.head = 0;
        slot.tail = 0;
        slot.channel_cursor = 0;
        slot.ready = false;
        for (&slot.eq) |*eq| eq.* = .{};
        slot.quit.store(false, .release);
        slot.child = child;
        const pipe = child.stdout orelse {
            self.beginRelease(slot);
            self.endRelease(slot);
            return;
        };
        // The descriptor itself must be nonblocking: the Io layer reads it
        // directly, and a blocking read there stalls the whole pump.
        _ = std.c.fcntl(pipe.handle, 4, @as(c_int, 0x0004));
        slot.file = .{ .handle = pipe.handle, .flags = .{ .nonblocking = true } };
    }

    fn beginRelease(self: *Mixer, slot: *Slot) void {
        slot.active = false;
        slot.quit.store(true, .release);
        slot.file = null;
        if (slot.child) |*child| {
            if (child.id) |pid| std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            _ = child.wait(self.io) catch {};
        }
    }

    fn endRelease(_: *Mixer, slot: *Slot) void {
        slot.child = null;
        slot.head = 0;
        slot.tail = 0;
        slot.channel_cursor = 0;
    }

    /// Moves what the decoder produced into the lane's ring, then stops at
    /// WouldBlock. Runs on the pump thread with the lock held.
    fn drain(self: *Mixer, slot: *Slot) void {
        var buffer: [32768]u8 align(@alignOf(f32)) = undefined;
        const file = slot.file orelse return;

        while (true) {
            const free = freeFrames(slot);
            if (free == 0) return;

            // Never read more than the ring can hold: a read larger than the
            // free space would drop the overflow and granularise the audio.
            const max_frames: usize = buffer.len / (channels * @sizeOf(f32));
            const frames_to_read: usize = if (free < max_frames) free else max_frames;
            const want: usize = frames_to_read * channels * @sizeOf(f32);

            const count = file.readStreaming(self.io, &.{buffer[0..want]}) catch |err| {
                switch (err) {
                    error.WouldBlock => return,
                    else => {
                        slot.file = null;
                        return;
                    },
                }
            };
            if (count == 0) {
                slot.file = null;
                return;
            }

            const samples: []const f32 = @as([*]const f32, @ptrCast(@alignCast(&buffer)))[0 .. count / @sizeOf(f32)];
            for (samples) |sample| {
                slot.ring[slot.head * channels + slot.channel_cursor] = sample;
                if (slot.channel_cursor + 1 == channels) {
                    slot.channel_cursor = 0;
                    slot.head = (slot.head + 1) % ring_frames;
                } else {
                    slot.channel_cursor += 1;
                }
            }
        }
    }

    fn bufferedFrames(slot: *const Slot) usize {
        return (slot.head + ring_frames - slot.tail) % ring_frames;
    }

    fn freeFrames(slot: *const Slot) usize {
        const occupied = (slot.head + ring_frames - slot.tail) % ring_frames;
        return ring_frames - 1 - occupied;
    }

    /// Mixes `frames` frames of every audible lane into `out`.
    fn mixFrames(self: *Mixer, frames: usize, now: i128) void {
        @memset(self.out[0 .. frames * channels], 0);

        for (&self.slots) |*slot| {
            if (!slot.active or slot.mute_until_ns > now) continue;

            // Wait for a real buffer before the first sample: otherwise the
            // lane begins wherever the decoder happened to be by the time the
            // pump looked.
            if (!slot.ready) {
                if (bufferedFrames(slot) < prefill_frames and slot.file != null) continue;
                slot.ready = true;
            }
            // Fully open means no filtering at all: a 20 kHz biquad still
            // colours the top octave.
            const bypass = slot.filter >= 0.999;
            if (!bypass and slot.applied_filter != slot.filter) {
                slot.applied_filter = slot.filter;
                const cutoff = 200 * std.math.pow(f32, 100, std.math.clamp(slot.filter, 0, 1));
                for (&slot.eq) |*eq| eq.setLowPass(cutoff);
            }
            var frame: usize = 0;
            while (frame < frames and slot.tail != slot.head) : (frame += 1) {
                for (0..channels) |channel| {
                    const sample = slot.ring[slot.tail * channels + channel];
                    self.out[frame * channels + channel] += if (bypass) sample else slot.eq[channel].process(sample);
                }
                slot.tail = (slot.tail + 1) % ring_frames;
            }
        }

        for (self.out[0 .. frames * channels]) |*sample| {
            sample.* = std.math.clamp(sample.*, -0.98, 0.98);
        }
    }

    /// Renders the same pipeline to a raw f32le file with no audio device, so
    /// the mix can be compared against a reference render.
    pub fn render(self: *Mixer, lanes: []const Lane, seconds: f64, out: std.Io.File) !void {
        for (&self.slots) |*slot| {
            if (slot.active) {
                self.beginRelease(slot);
                self.endRelease(slot);
            }
        }
        for (lanes, 0..) |lane, index| {
            if (index >= max_lanes) break;
            self.start(&self.slots[index], lane);
        }

        const total: usize = @intFromFloat(seconds * sample_rate);
        var written: usize = 0;
        while (written < total) {
            for (&self.slots) |*slot| {
                if (slot.active) self.drain(slot);
            }

            // Do not advance the output until the decoders have produced
            // something: writing silence here is what shifted the render.
            var waited: usize = 0;
            while (waited < 2000) : (waited += 1) {
                var starved = false;
                for (&self.slots) |*slot| {
                    if (!slot.active or slot.file == null) continue;
                    if (bufferedFrames(slot) < prefill_frames) starved = true;
                }
                if (!starved) break;
                for (&self.slots) |*slot| {
                    if (slot.active) self.drain(slot);
                }
                self.io.sleep(.{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
            }

            const frames: usize = if (total - written < tick_frames) total - written else tick_frames;
            self.mixFrames(frames, std.math.maxInt(i128));
            try out.writeStreamingAll(self.io, std.mem.sliceAsBytes(self.out[0 .. frames * channels]));
            written += frames;

            var empty = true;
            for (&self.slots) |*slot| {
                if (slot.active and slot.head != slot.tail) empty = false;
            }
            if (empty) self.io.sleep(.{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
        }

        for (&self.slots) |*slot| {
            if (slot.active) {
                self.beginRelease(slot);
                self.endRelease(slot);
            }
        }
    }

    fn pumpMain(self: *Mixer) void {
        while (self.running.load(.acquire)) {
            self.io.sleep(.{ .nanoseconds = 5 * std.time.ns_per_ms }, .awake) catch {};

            // Top the device queue up to ~40 ms and no further: mixing a fixed
            // 10 ms per wake-up drifts against the device clock.
            const target_bytes = sample_rate * channels * @sizeOf(f32) * 40 / 1000;
            const queued = self.device.queued();
            if (queued >= target_bytes) continue;
            var frames = (target_bytes - queued) / (channels * @sizeOf(f32));
            if (frames > tick_frames) frames = tick_frames;
            if (frames == 0) frames = 64;

            const now = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
            if (self.mutex.tryLock()) {
                for (&self.slots) |*slot| {
                    if (!slot.active) continue;
                    self.drain(slot);
                }
                self.mixFrames(frames, now);
                self.mutex.unlock(self.io);
            }

            self.device.write(self.out[0 .. frames * channels]);
        }
    }
};
