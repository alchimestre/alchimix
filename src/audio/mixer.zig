//! The internal mixer.
//!
//! One SDL output stream plays a single mixed signal. Every lane is a decoder
//! process piping `f32le` into a ring buffer, and this file does the summing and
//! the EQ. Lanes therefore share one clock: no player starts before another,
//! and no change to one lane interrupts the rest.

const std = @import("std");
const device_mod = @import("device.zig");
const Track = @import("../domain/track.zig").Track;

/// Low shelf, bell, high shelf, in that order.
pub const band_count = 3;
pub const eq_max_gain_db: f32 = 12;
pub const trim_max_db: f32 = 12;
pub const eq_min_hz: f32 = 40;
pub const eq_max_hz: f32 = 16000;

pub const EqPreset = enum(u2) { none, lpf, hpf, bpf };

pub fn presetEq(preset: EqPreset) EqParams {
    return switch (preset) {
        .none => .{},
        .lpf => .{
            .gain_db = .{ 0, 0, -eq_max_gain_db },
            .freq_hz = .{ 120, 1000, 2000 },
        },
        .hpf => .{
            .gain_db = .{ -eq_max_gain_db, 0, 0 },
            .freq_hz = .{ 200, 1000, 8000 },
        },
        .bpf => .{
            .gain_db = .{ -eq_max_gain_db, eq_max_gain_db, -eq_max_gain_db },
            .freq_hz = .{ 200, 1000, 3000 },
        },
    };
}

/// One band per entry: low shelf, bell, high shelf.
pub const EqParams = struct {
    gain_db: [band_count]f32 = .{ 0, 0, 0 },
    freq_hz: [band_count]f32 = .{ 120, 1000, 8000 },
    q: [band_count]f32 = .{ 0.707, 1.0, 0.707 },

    /// All bands at unity: the mix can skip the biquads entirely.
    pub fn isFlat(self: EqParams) bool {
        for (self.gain_db) |gain| {
            if (@abs(gain) >= 0.01) return false;
        }
        return true;
    }
};

pub const Lane = struct {
    /// Slot identity. A crate may hold the same track twice, so the track id
    /// alone cannot name a lane.
    uid: u64 = 0,
    track: Track,
    /// Where playback starts, in seconds into the track.
    start_s: f64,
    /// Master BPM divided by the track's BPM.
    tempo: f32,
    /// Three-band EQ, applied in place without restarting the decoder.
    eq: EqParams = .{},
    /// Keeps the lane playing and its clock running, but adds no samples.
    muted: bool = false,
    /// Per-lane gain after the EQ, in dB.
    trim_db: f32 = 0,
    /// Keep the pitch while the tempo changes; otherwise pitch follows speed.
    keylock: bool,
    /// Audio-clock time at which the lane may become audible, so it starts on
    /// a master bar. Zero means as soon as the decoder is ready.
    start_at_ns: i128 = 0,
    /// Forces a decoder restart even when position and tempo look unchanged.
    restart: bool = false,
};

const sample_rate = device_mod.sample_rate;
const channels = device_mod.channels;
/// Bins drawn across the EQ panel, log-spaced.
pub const spectrum_bins = 32;
/// Analysis window; filled over three pump ticks.
const fft_size = 1024;
/// Ten milliseconds per pump tick.
const tick_frames = sample_rate / 100;
/// Meter fall per pump tick.
const level_decay: f32 = 0.86;
const ring_frames = sample_rate * 2;
pub const max_lanes = 8;
/// Audio buffered before a lane starts playing, 100 ms.
const prefill_frames = sample_rate / 10;

/// What the audio side knows about a lane, for a transport that must not guess.
pub const LaneState = union(enum) {
    /// No decoder exists for this track: it never started.
    missing,
    /// The decoder is buffering or waiting for its start time.
    pending,
    /// Audio-clock time the lane first produced samples.
    started: i128,
    /// The decoder is gone and its buffer is drained.
    ended,
};

const Biquad = struct {
    b0: f32 = 1,
    b1: f32 = 0,
    b2: f32 = 0,
    a1: f32 = 0,
    a2: f32 = 0,
    z1: f32 = 0,
    z2: f32 = 0,

    fn setBand(self: *Biquad, band: usize, params: EqParams) void {
        const gain_db = std.math.clamp(params.gain_db[band], -24, 24);
        const hz = std.math.clamp(params.freq_hz[band], 20, sample_rate * 0.45);
        const q = std.math.clamp(params.q[band], 0.1, 10);
        const w0 = 2 * std.math.pi * hz / sample_rate;
        const cos = @cos(w0);
        const sin = @sin(w0);
        const a = std.math.pow(f32, 10, gain_db / 40);
        switch (band) {
            // Low shelf and high shelf use S = 1: the steepest slope that
            // still meets the plateau without a resonant overshoot.
            0 => {
                const alpha = sin / 2 * @sqrt(@as(f32, 2));
                const two_sqrt_a_alpha = 2 * @sqrt(a) * alpha;
                const a_plus = a + 1;
                const a_minus = a - 1;
                self.setCoefficients(
                    a * (a_plus - a_minus * cos + two_sqrt_a_alpha),
                    2 * a * (a_minus - a_plus * cos),
                    a * (a_plus - a_minus * cos - two_sqrt_a_alpha),
                    a_plus + a_minus * cos + two_sqrt_a_alpha,
                    -2 * (a_minus + a_plus * cos),
                    a_plus + a_minus * cos - two_sqrt_a_alpha,
                );
            },
            1 => {
                const alpha = sin / (2 * q);
                self.setCoefficients(
                    1 + alpha * a,
                    -2 * cos,
                    1 - alpha * a,
                    1 + alpha / a,
                    -2 * cos,
                    1 - alpha / a,
                );
            },
            else => {
                const alpha = sin / 2 * @sqrt(@as(f32, 2));
                const two_sqrt_a_alpha = 2 * @sqrt(a) * alpha;
                const a_plus = a + 1;
                const a_minus = a - 1;
                self.setCoefficients(
                    a * (a_plus + a_minus * cos + two_sqrt_a_alpha),
                    -2 * a * (a_minus + a_plus * cos),
                    a * (a_plus + a_minus * cos - two_sqrt_a_alpha),
                    a_plus - a_minus * cos + two_sqrt_a_alpha,
                    2 * (a_minus - a_plus * cos),
                    a_plus - a_minus * cos - two_sqrt_a_alpha,
                );
            },
        }
    }

    fn setCoefficients(self: *Biquad, b0: f32, b1: f32, b2: f32, a0: f32, a1: f32, a2: f32) void {
        self.b0 = b0 / a0;
        self.b1 = b1 / a0;
        self.b2 = b2 / a0;
        self.a1 = a1 / a0;
        self.a2 = a2 / a0;
    }

    /// Magnitude response at `hz`, in dB, for drawing the curve.
    fn responseDb(self: *const Biquad, hz: f32) f32 {
        const clamped = std.math.clamp(hz, 1, sample_rate * 0.49);
        const w = 2 * std.math.pi * clamped / sample_rate;
        const cos1 = @cos(w);
        const sin1 = @sin(w);
        const cos2 = @cos(2 * w);
        const sin2 = @sin(2 * w);
        const num_re = self.b0 + self.b1 * cos1 + self.b2 * cos2;
        const num_im = -(self.b1 * sin1 + self.b2 * sin2);
        const den_re = 1 + self.a1 * cos1 + self.a2 * cos2;
        const den_im = -(self.a1 * sin1 + self.a2 * sin2);
        const num = @sqrt(num_re * num_re + num_im * num_im);
        const den = @sqrt(den_re * den_re + den_im * den_im);
        return 20 * @log10(@max(num / den, 1e-6));
    }

    fn process(self: *Biquad, input: f32) f32 {
        const out = self.b0 * input + self.z1;
        self.z1 = self.b1 * input - self.a1 * out + self.z2;
        self.z2 = self.b2 * input - self.a2 * out;
        return out;
    }
};

/// Combined magnitude of the three bands at `hz`, in dB.
pub fn responseDb(params: EqParams, hz: f32) f32 {
    var total: f32 = 0;
    for (0..band_count) |band| {
        var bq: Biquad = .{};
        bq.setBand(band, params);
        total += bq.responseDb(hz);
    }
    return total;
}

fn trimGain(db: f32) f32 {
    return std.math.pow(f32, 10, db / 20);
}

fn processBands(bands: *[band_count]Biquad, sample: f32) f32 {
    var out = sample;
    for (bands) |*bq| out = bq.process(out);
    return out;
}

const Complex = struct { re: f32, im: f32 };

fn fft(buffer: []Complex) void {
    const n = buffer.len;
    var reversed: usize = 0;
    for (1..n) |i| {
        var bit = n >> 1;
        while (reversed & bit != 0) : (bit >>= 1) reversed ^= bit;
        reversed ^= bit;
        if (i < reversed) std.mem.swap(Complex, &buffer[i], &buffer[reversed]);
    }
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const step = -2 * std.math.pi / @as(f32, @floatFromInt(len));
        const root = Complex{ .re = @cos(step), .im = @sin(step) };
        var start: usize = 0;
        while (start < n) : (start += len) {
            var w = Complex{ .re = 1, .im = 0 };
            for (0..len / 2) |k| {
                const u = buffer[start + k];
                const v = buffer[start + k + len / 2];
                const vr = v.re * w.re - v.im * w.im;
                const vi = v.re * w.im + v.im * w.re;
                buffer[start + k] = .{ .re = u.re + vr, .im = u.im + vi };
                buffer[start + k + len / 2] = .{ .re = u.re - vr, .im = u.im - vi };
                w = .{ .re = w.re * root.re - w.im * root.im, .im = w.re * root.im + w.im * root.re };
            }
        }
    }
}

/// Lower edge of a drawn spectrum band, in Hz.
pub fn spectrumFreq(band: usize) f32 {
    return eq_min_hz * std.math.pow(f32, eq_max_hz / eq_min_hz, @as(f32, @floatFromInt(band)) / spectrum_bins);
}

fn pushSpectrum(slot: *Slot, sample: f32) void {
    slot.fft_window[slot.fft_fill] = sample;
    slot.fft_fill += 1;
    if (slot.fft_fill < fft_size) return;
    slot.fft_fill = 0;
    computeSpectrum(slot);
}

fn computeSpectrum(slot: *Slot) void {
    var buffer: [fft_size]Complex = undefined;
    const last = @as(f32, @floatFromInt(fft_size - 1));
    for (0..fft_size) |i| {
        const phase = 2 * std.math.pi * @as(f32, @floatFromInt(i)) / last;
        buffer[i] = .{ .re = slot.fft_window[i] * (0.5 - 0.5 * @cos(phase)), .im = 0 };
    }
    fft(&buffer);
    const bin_hz = @as(f32, sample_rate) / fft_size;
    for (0..spectrum_bins) |band| {
        const low = spectrumFreq(band) / bin_hz;
        const high = spectrumFreq(band + 1) / bin_hz;
        var first: usize = @intFromFloat(low);
        var end: usize = @intFromFloat(high);
        first = @min(first, fft_size / 2 - 1);
        end = @min(@max(end, first + 1), fft_size / 2);
        var peak: f32 = 0;
        for (first..end) |bin| {
            const re = buffer[bin].re;
            const im = buffer[bin].im;
            peak = @max(peak, @sqrt(re * re + im * im));
        }
        const magnitude = peak / (@as(f32, fft_size) / 2);
        const db = 20 * @log10(@max(magnitude, 1e-5));
        const value = std.math.clamp((db + 80) / 80, 0, 1);
        slot.spectrum[band] = @max(value, slot.spectrum[band] * 0.86);
    }
}

const Slot = struct {
    active: bool = false,
    uid: u64 = 0,
    track_id: u64 = 0,
    start_s: f64 = -1,
    tempo: f32 = 1,
    keylock: bool = true,
    muted: bool = false,
    eq: EqParams = .{},
    /// Bands changed; recompute the shared coefficients before the next block.
    eq_dirty: bool = false,
    trim_db: f32 = 0,
    /// Post-trim peak of the last block, decayed once per pump tick.
    level: f32 = 0,
    child: ?std.process.Child = null,
    /// Decoder stdout, nonblocking, drained by the pump thread.
    file: ?std.Io.File = null,
    quit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ring: []f32 = &.{},
    head: usize = 0,
    tail: usize = 0,
    /// Channel of the next sample, so a split read keeps frame alignment.
    channel_cursor: usize = 0,
    biquads: [channels][band_count]Biquad = @splat(@splat(.{})),
    fft_window: [fft_size]f32 = @splat(0),
    fft_fill: usize = 0,
    /// Smoothed 0..1 energy per log band, read by the EQ panel.
    spectrum: [spectrum_bins]f32 = @splat(0),
    /// False until the decoder has buffered enough to start cleanly. A lane
    /// that starts mid-stream is offset from every other lane.
    ready: bool = false,
    /// Audio-clock time this lane first produced samples.
    started_ns: i128 = 0,
    /// True once this lane produced its first sample; audio time zero is a
    /// valid start, so this cannot be a sentinel.
    started: bool = false,
    /// Absolute audio-clock time the lane may become audible.
    start_at_ns: i128 = 0,
};

pub const Mixer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    device: device_mod.Device = .{},
    slots: [max_lanes]Slot = undefined,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Frames actually written to the device, the transport's clock.
    clock_frames: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    out: []f32 = &.{},
    /// A fresh start holds the mix until every lane in the batch has its
    /// prefill, so lanes cannot begin tens of milliseconds apart.
    gate: bool = false,

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
    /// decoder unless their position or tempo changed; EQ changes are applied
    /// in place, so they never interrupt the audio.
    pub fn play(self: *Mixer, lanes: []const Lane) void {
        self.ensureThread();
        self.device.open() catch return;

        self.mutex.lockUncancelable(self.io);

        var used: [max_lanes]bool = @splat(false);
        var finished: [max_lanes]*Slot = @splat(undefined);
        var finished_count: usize = 0;
        var reused = false;
        var restarted_count: usize = 0;
        for (lanes) |lane| {
            var target: ?*Slot = null;
            for (&self.slots, 0..) |*slot, index| {
                if (!used[index] and slot.active and slot.uid == lane.uid) {
                    used[index] = true;
                    target = slot;
                    reused = true;
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
            if (target) |slot| {
                if (self.apply(slot, lane)) restarted_count += 1;
            }
        }

        for (&self.slots, 0..) |*slot, index| {
            if (used[index] or !slot.active) continue;
            self.beginRelease(slot);
            finished[finished_count] = slot;
            finished_count += 1;
        }

        // Only a batch where nothing was already playing needs the joint gate;
        // a lane joining a running mix must not stall the others.
        // Gate only when every audible lane was restarted by this call: a
        // single joining lane must not stall the lanes already playing.
        var active_count: usize = 0;
        for (&self.slots) |*slot| {
            if (slot.active) active_count += 1;
        }
        if (active_count > 0 and restarted_count >= active_count) self.gate = true;

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

    /// Audio-clock time: how much audio has actually been handed to the
    /// device. The transport derives its playhead from this, not from a wall
    /// clock or a guessed decoder delay.
    pub fn nowNs(self: *const Mixer) i128 {
        const frames = self.clock_frames.load(.monotonic);
        const ns = @as(u128, frames) * 1_000_000_000 / sample_rate;
        return @intCast(ns);
    }

    /// Reports what a lane's decoder is doing. Lock-free callers get `pending`
    /// rather than a wrong answer.
    pub fn laneState(self: *Mixer, uid: u64) LaneState {
        if (!self.mutex.tryLock()) return .pending;
        defer self.mutex.unlock(self.io);

        for (&self.slots) |*slot| {
            if (!slot.active or slot.uid != uid) continue;
            if (slot.file == null and slot.tail == slot.head) return .ended;
            if (slot.started) return .{ .started = slot.started_ns };
            return .pending;
        }
        return .missing;
    }

    /// Copies the smoothed spectrum of one lane into `out`. Never blocks the
    /// pump: a busy mix leaves the previous frame's bars on screen.
    pub fn spectrum(self: *Mixer, uid: u64, out: []f32) void {
        @memset(out, 0);
        if (!self.mutex.tryLock()) return;
        defer self.mutex.unlock(self.io);
        for (&self.slots) |*slot| {
            if (!slot.active or slot.uid != uid) continue;
            const count = @min(out.len, spectrum_bins);
            @memcpy(out[0..count], slot.spectrum[0..count]);
            return;
        }
    }

    /// The lane's post-trim peak level, 0..1, with the pump's decay applied.
    pub fn level(self: *Mixer, uid: u64) f32 {
        if (!self.mutex.tryLock()) return 0;
        defer self.mutex.unlock(self.io);
        for (&self.slots) |*slot| {
            if (!slot.active or slot.uid != uid) continue;
            return slot.level;
        }
        return 0;
    }

    fn ensureThread(self: *Mixer) void {
        if (self.thread != null) return;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, pumpMain, .{self}) catch null;
    }

    /// Returns true when the decoder was restarted, which needs the joint
    /// start gate: otherwise the restarted lanes begin at different times.
    fn apply(self: *Mixer, slot: *Slot, lane: Lane) bool {
        const same_track = slot.active and slot.uid == lane.uid;
        const same_start = @abs(slot.start_s - lane.start_s) < 0.001;
        const same_tempo = @abs(slot.tempo - lane.tempo) < 0.0005 and slot.keylock == lane.keylock;

        var restarted = false;
        if (lane.restart or !same_track or !same_start or !same_tempo) {
            self.beginRelease(slot);
            self.endRelease(slot);
            self.start(slot, lane);
            restarted = true;
        }

        slot.eq = lane.eq;
        slot.eq_dirty = true;
        slot.muted = lane.muted;
        slot.trim_db = lane.trim_db;
        slot.start_at_ns = lane.start_at_ns;
        return restarted;
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
        slot.uid = lane.uid;
        slot.track_id = lane.track.id;
        slot.start_s = lane.start_s;
        slot.tempo = lane.tempo;
        slot.keylock = lane.keylock;
        slot.eq = lane.eq;
        slot.eq_dirty = true;
        slot.muted = lane.muted;
        slot.trim_db = lane.trim_db;
        slot.level = 0;
        slot.head = 0;
        slot.tail = 0;
        slot.channel_cursor = 0;
        slot.ready = false;
        slot.started = false;
        slot.start_at_ns = lane.start_at_ns;
        slot.fft_fill = 0;
        @memset(&slot.spectrum, 0);
        for (&slot.biquads) |*channel| {
            for (channel) |*bq| bq.* = .{};
        }
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
        slot.started = false;
        slot.fft_fill = 0;
        slot.level = 0;
        @memset(&slot.spectrum, 0);
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

        if (self.gate) {
            var waiting = false;
            for (&self.slots) |*slot| {
                if (!slot.active) continue;
                if (slot.file != null and bufferedFrames(slot) < prefill_frames) waiting = true;
            }
            if (waiting) return;
            self.gate = false;
        }

        for (&self.slots) |*slot| {
            if (!slot.active or slot.start_at_ns > now) continue;

            // Wait for a real buffer before the first sample: otherwise the
            // lane begins wherever the decoder happened to be by the time the
            // pump looked.
            if (!slot.ready) {
                if (bufferedFrames(slot) < prefill_frames and slot.file != null) continue;
                slot.ready = true;
            }
            if (slot.muted) @memset(&slot.spectrum, 0);
            slot.level *= level_decay;
            if (slot.head == slot.tail) continue;
            // First audible frame: this is the time the transport must use,
            // whatever the decoder's own latency was.
            if (!slot.started) {
                slot.started = true;
                slot.started_ns = now;
            }
            // All bands at unity is a true bypass: three biquads still colour
            // the signal and cost cycles.
            const flat = slot.eq.isFlat();
            if (!flat and slot.eq_dirty) {
                slot.eq_dirty = false;
                for (&slot.biquads) |*channel| {
                    for (channel, 0..) |*bq, band| bq.setBand(band, slot.eq);
                }
            }
            const gain = trimGain(slot.trim_db);
            var peak: f32 = 0;
            var frame: usize = 0;
            while (frame < frames and slot.tail != slot.head) : (frame += 1) {
                if (slot.muted) {
                    slot.tail = (slot.tail + 1) % ring_frames;
                    continue;
                }
                var mono: f32 = 0;
                for (0..channels) |channel| {
                    const dry = slot.ring[slot.tail * channels + channel];
                    const shaped = if (flat) dry else processBands(&slot.biquads[channel], dry);
                    const sample = shaped * gain;
                    peak = @max(peak, @abs(sample));
                    self.out[frame * channels + channel] += sample;
                    mono += sample;
                }
                pushSpectrum(slot, mono / channels);
                slot.tail = (slot.tail + 1) % ring_frames;
            }
            slot.level = @max(peak, slot.level);
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

            // 100 ms of runway: at 40 ms a late wake-up emptied the queue and
            // clicked. The queue is capped so latency stays fixed.
            const target_bytes = sample_rate * channels * @sizeOf(f32) * 100 / 1000;
            const queued = self.device.queued();
            if (queued >= target_bytes) continue;
            var frames = (target_bytes - queued) / (channels * @sizeOf(f32));
            if (frames > tick_frames) frames = tick_frames;
            if (frames == 0) frames = 64;

            const now = self.nowNs();
            if (!self.mutex.tryLock()) continue;

            for (&self.slots) |*slot| {
                if (!slot.active) continue;
                self.drain(slot);
            }
            self.mixFrames(frames, now);
            self.mutex.unlock(self.io);

            self.device.write(self.out[0 .. frames * channels]);
            _ = self.clock_frames.fetchAdd(frames, .monotonic);
        }
    }
};

const testing = std.testing;

fn bandChain(params: EqParams) [band_count]Biquad {
    var bands: [band_count]Biquad = @splat(.{});
    for (&bands, 0..) |*bq, band| bq.setBand(band, params);
    return bands;
}

/// Steady-state gain of a chain at `hz`, in dB, measured on a sine.
fn sineGainDb(bands: []Biquad, hz: f32) f32 {
    const amplitude: f32 = 0.25;
    const settle = 8_000;
    const total = 24_000;
    const step = 2 * std.math.pi * hz / sample_rate;
    var phase: f32 = 0;
    var peak: f32 = 0;
    for (0..total) |i| {
        const input = amplitude * @sin(phase);
        phase += step;
        if (phase > 2 * std.math.pi) phase -= 2 * std.math.pi;
        var out = input;
        for (bands) |*bq| out = bq.process(out);
        if (i >= settle) peak = @max(peak, @abs(out));
    }
    return 20 * @log10(peak / amplitude);
}

test "a low shelf lifts the bass and leaves the treble alone" {
    var params: EqParams = .{};
    params.gain_db = .{ 12, 0, 0 };
    var bands = bandChain(params);
    try testing.expect(sineGainDb(&bands, 50) > 10);
    try testing.expect(@abs(sineGainDb(&bands, 8000)) < 1.5);
}

test "a bell touches its centre only" {
    var params: EqParams = .{};
    params.gain_db = .{ 0, 12, 0 };
    var bands = bandChain(params);
    try testing.expectApproxEqAbs(@as(f32, 12), sineGainDb(&bands, 1000), 0.5);
    try testing.expect(@abs(sineGainDb(&bands, 100)) < 1);
    try testing.expect(@abs(sineGainDb(&bands, 16000)) < 1);
}

test "a high shelf cuts the top without touching the bass" {
    var params: EqParams = .{};
    params.gain_db = .{ 0, 0, -12 };
    var bands = bandChain(params);
    try testing.expect(sineGainDb(&bands, 16000) < -8);
    try testing.expect(@abs(sineGainDb(&bands, 200)) < 1);
}

test "all bands at unity are flat" {
    const flat: EqParams = .{};
    try testing.expect(flat.isFlat());
    var params: EqParams = .{};
    params.gain_db = .{ 0, 0.5, 0 };
    try testing.expect(!params.isFlat());
}

test "responseDb agrees with the rendered shelf" {
    var params: EqParams = .{};
    params.gain_db = .{ 12, 0, 0 };
    try testing.expectApproxEqAbs(@as(f32, 11.54), responseDb(params, 50), 0.1);
}

test "presets shape the expected side of the spectrum" {
    const lpf = presetEq(.lpf);
    try testing.expect(responseDb(lpf, 4000) < -6);
    try testing.expect(@abs(responseDb(lpf, 100)) < 1);

    const hpf = presetEq(.hpf);
    try testing.expect(responseDb(hpf, 100) < -6);
    try testing.expect(@abs(responseDb(hpf, 8000)) < 1);

    const bpf = presetEq(.bpf);
    try testing.expect(responseDb(bpf, 1000) > 6);
    try testing.expect(responseDb(bpf, 100) < -6);
}

test "the spectrum peaks in the band that contains the tone" {
    var slot: Slot = .{};
    const tone_hz: f32 = 1000;
    for (0..fft_size) |i| {
        slot.fft_window[i] = 0.5 * @sin(2 * std.math.pi * tone_hz * @as(f32, @floatFromInt(i)) / sample_rate);
    }
    computeSpectrum(&slot);

    var best: usize = 0;
    for (slot.spectrum, 0..) |value, band| {
        if (value > slot.spectrum[best]) best = band;
    }
    try testing.expect(spectrumFreq(best) <= tone_hz);
    try testing.expect(tone_hz < spectrumFreq(best + 1));
}
