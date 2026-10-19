//! Playback transport: which lanes play, where each one sits, and the mixer
//! batch that makes it audible.
//!
//! The transport never guesses how long a decoder takes to start. It asks the
//! mixer when a lane actually began producing samples, and derives the master
//! beat from that audio clock. A lane that is still buffering sits at its
//! start beat, so a cold start or a late join cannot run ahead of the sound.

const std = @import("std");
const analysis_mod = @import("../domain/analysis.zig");
const track_mod = @import("../domain/track.zig");
const mixer = @import("mixer.zig");

pub const max_lanes = mixer.max_lanes;

/// Everything the transport needs about one grid lane that the app owns.
pub const LaneInfo = struct {
    track: track_mod.Track,
    analysis: ?*const analysis_mod.Analysis = null,
    /// Tempo of the track's own grid, or the track's tagged tempo.
    grid_bpm: f32 = 128,
    /// Length of the analysed grid, in beats.
    total_beats: f32 = 0,
    /// Beats to subtract from a local beat to land on a downbeat.
    offset: f32 = 0,
    /// Beat index of the first downbeat.
    first_downbeat: f32 = 0,
};

pub const Clock = struct {
    context: *anyopaque,
    nowNs: *const fn (*anyopaque) i128,
};

pub const Output = struct {
    context: *anyopaque,
    play: *const fn (*anyopaque, lanes: []const mixer.Lane) void,
    stop: *const fn (*anyopaque) void,
    laneState: *const fn (*anyopaque, uid: u64) mixer.LaneState,
    spectrum: *const fn (*anyopaque, uid: u64, out: []f32) void,
    level: *const fn (*anyopaque, uid: u64) f32,
};

/// Whether a fresh lane waits for the next master bar or starts at once.
pub const Join = enum { bar, now, next_bar };

const Slot = struct {
    /// Unique identity for the mixer: a crate may hold the same track twice.
    uid: u64 = 0,
    track_id: u64 = 0,
    index: usize = 0,
    track: track_mod.Track = .{ .id = 0, .title = "", .artist = "" },
    analysis: ?*const analysis_mod.Analysis = null,
    grid_bpm: f32 = 128,
    total_beats: f32 = 0,
    offset: f32 = 0,
    first_downbeat: f32 = 0,
    /// Pose the lane plays from, or its resting beat when stopped.
    beat: f32 = 0,
    /// Unrounded pose, so sub-beat drags are not lost to snapping.
    beat_raw: f32 = 0,
    /// The waveform was dragged by hand, so starts keep the jogged beat.
    manual: bool = false,
    playing: bool = false,
    /// True once the mixer's reported start time is known; audio time zero is
    /// a valid start, so this cannot be a sentinel.
    start_latched: bool = false,
    /// Master beat when the lane's audio actually began.
    started_master: f32 = 0,
    /// Audio-clock time the lane may become audible; zero means as soon as the
    /// decoder is ready. Absolute so a repeated mix cannot push it later.
    start_at_ns: i128 = 0,
    eq: mixer.EqParams = .{},
    eq_preset: mixer.EqPreset = .none,
    /// Plays on silently: the lane keeps its clock and position.
    muted: bool = false,
    /// Post-EQ lane gain, in dB.
    trim_db: f32 = 0,
    /// True when this start rejoins other lanes mid-song, so a missed bar must
    /// be retried rather than joined late.
    rejoin: bool = false,
    /// Set for a retune, so the mixer restarts this decoder even when the
    /// folded position and tempo round to the same values.
    restart: bool = false,
    /// Set while the grid sync walks the crate.
    seen: bool = false,
};

/// How late a lane may start before it is moved to the next bar.
const start_grace_ns: i128 = 100_000_000;

pub const Transport = struct {
    allocator: std.mem.Allocator,
    output: Output,
    clock: Clock,
    /// One entry per crate lane, in call order after a sync. Only lanes that
    /// are playing are handed to the mixer, capped at its lane count.
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    next_uid: u64 = 1,
    /// Master beat at `clock_base_ns`, advanced at `bpm`.
    running: bool = false,
    clock_base_ns: i128 = 0,
    clock_base_beat: f32 = 0,
    bpm: f32 = 128,
    keylock: bool = true,
    /// Lane held by the pointer: paused for the jog, resumed on release.
    jog: ?usize = null,
    /// How the release rejoins: the waveform resumes at once, the navigator
    /// waits for the next master bar so the lane stays on the grid.
    jog_join: Join = .now,
    /// True while the mixer holds a batch, so an identical one is not resent.
    mixed: bool = false,
    mix_key: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, output: Output, clock: Clock) Transport {
        return .{ .allocator = allocator, .output = output, .clock = clock };
    }

    pub fn deinit(self: *Transport) void {
        self.slots.deinit(self.allocator);
        self.* = undefined;
    }

    /// Starts a grid sync. Every known lane is marked unseen; `endSync`
    /// releases the ones that the app did not resolve again.
    pub fn beginSync(self: *Transport) void {
        for (self.slots.items) |*slot| slot.seen = false;
    }

    /// Shifts lane positions for a crate insert at `index`. Playback state
    /// follows the track it belongs to.
    pub fn insert(self: *Transport, index: usize) void {
        for (self.slots.items) |*slot| {
            if (slot.index >= index) slot.index += 1;
        }
        if (self.jog) |jog| {
            if (jog >= index) self.jog = jog + 1;
        }
    }

    /// Deletes the lane at `index` and shifts the positions after it.
    pub fn remove(self: *Transport, index: usize) void {
        var dropped = false;
        var i: usize = 0;
        while (i < self.slots.items.len) {
            const slot = &self.slots.items[i];
            if (slot.index == index) {
                if (slot.playing) dropped = true;
                _ = self.slots.swapRemove(i);
                continue;
            }
            if (slot.index > index) slot.index -= 1;
            i += 1;
        }
        if (self.jog) |jog| {
            if (jog == index) {
                self.jog = null;
            } else if (jog > index) {
                self.jog = jog - 1;
            }
        }
        if (dropped) {
            self.pushMix();
            if (!self.anyPlaying()) self.stopClock();
        }
    }

    /// Remaps lane positions for a crate move to a gap index, matching
    /// `Crate.moveTo`.
    pub fn move(self: *Transport, from: usize, gap: usize) void {
        const target = if (from < gap) gap - 1 else gap;
        if (target == from) return;
        for (self.slots.items) |*slot| {
            if (slot.index == from) {
                slot.index = target;
            } else if (from < target and slot.index > from and slot.index <= target) {
                slot.index -= 1;
            } else if (target < from and slot.index >= target and slot.index < from) {
                slot.index += 1;
            }
        }
        if (self.jog) |jog| {
            if (jog == from) {
                self.jog = target;
            } else if (from < jog and jog <= target) {
                self.jog = jog - 1;
            } else if (target <= jog and jog < from) {
                self.jog = jog + 1;
            }
        }
    }

    pub fn resolve(self: *Transport, index: usize, info: LaneInfo) void {
        const slot = self.slotFor(index, info) orelse return;
        self.fill(slot, index, info);
    }

    /// Releases lanes no longer in the grid. Must run before the app frees
    /// their analysis, which the slots point at.
    pub fn endSync(self: *Transport) void {
        var dropped = false;
        var i = self.slots.items.len;
        while (i > 0) {
            i -= 1;
            if (self.slots.items[i].seen) continue;
            if (self.slots.items[i].playing) dropped = true;
            _ = self.slots.swapRemove(i);
        }
        if (dropped) {
            self.pushMix();
            if (!self.anyPlaying()) self.stopClock();
        }
    }

    /// Advances the playing lanes from the audio clock, starts lanes the mixer
    /// has begun, and stops lanes that reached their end or lost their decoder.
    pub fn sync(self: *Transport) void {
        const now = self.nowNs();
        var changed = false;
        for (self.slots.items) |*slot| {
            if (!slot.playing) continue;
            switch (self.output.laneState(self.output.context, slot.uid)) {
                .missing, .ended => {
                    self.finishAt(slot, now);
                    changed = true;
                    continue;
                },
                .busy => {},
                .pending => {
                    // A rejoin can miss its bar while the decoder prefills.
                    // Put it back on the next bar instead of joining mid-bar.
                    // A joint start keeps its bar: its lanes start together,
                    // so they stay in sync with each other.
                    if (slot.rejoin and !slot.start_latched and slot.start_at_ns != 0 and now > slot.start_at_ns + start_grace_ns) {
                        slot.start_at_ns = self.nextBarAt(now);
                        changed = true;
                    }
                },
                .started => |started| {
                    if (!slot.start_latched) {
                        if (!self.running) {
                            self.running = true;
                            self.clock_base_ns = started;
                            self.clock_base_beat = 0;
                        }
                        slot.start_latched = true;
                        slot.started_master = self.masterBeatAt(started);
                    }
                },
            }
            if (slot.start_latched and slot.total_beats > 0) {
                if (self.beatAt(slot, now) >= slot.total_beats) {
                    self.finishAt(slot, now);
                    changed = true;
                }
            }
        }
        if (changed) self.pushMix();
        if (!self.anyPlaying()) self.stopClock();
    }

    pub fn start(self: *Transport, index: usize, join: Join) void {
        const slot = self.slotAt(index) orelse return;
        self.beginStart(slot, join);
    }

    /// Starts every playable lane in one mixer batch, so the joint gate makes
    /// them begin on the same audio sample.
    pub fn startAll(self: *Transport) void {
        const now = self.nowNs();
        const start_at = self.barStartAt(now);
        var any = false;
        while (self.playingCount() < max_lanes) {
            var best: ?*Slot = null;
            for (self.slots.items) |*slot| {
                if (slot.playing or slot.analysis == null) continue;
                if (best == null or slot.index < best.?.index) best = slot;
            }
            const slot = best orelse break;
            self.poseForStart(slot);
            slot.playing = true;
            slot.start_latched = false;
            slot.rejoin = false;
            slot.start_at_ns = start_at;
            any = true;
        }
        if (any) self.pushMix();
    }

    /// Starts just these lanes in one batch, on the same bar.
    pub fn startGroup(self: *Transport, indices: []const usize) void {
        const now = self.nowNs();
        const start_at = self.barStartAt(now);
        var any = false;
        for (indices) |index| {
            if (self.playingCount() >= max_lanes) break;
            const slot = self.slotAt(index) orelse continue;
            if (slot.playing or slot.analysis == null) continue;
            self.poseForStart(slot);
            slot.playing = true;
            slot.start_latched = false;
            slot.rejoin = false;
            slot.start_at_ns = start_at;
            any = true;
        }
        if (any) self.pushMix();
    }

    /// Stops just these lanes, leaving the rest untouched.
    pub fn stopGroup(self: *Transport, indices: []const usize) void {
        var any = false;
        const now = self.nowNs();
        for (indices) |index| {
            const slot = self.slotAt(index) orelse continue;
            if (!slot.playing) continue;
            self.finishAt(slot, now);
            any = true;
        }
        if (!any) return;
        self.pushMix();
        if (!self.anyPlaying()) self.stopClock();
    }

    pub fn stop(self: *Transport, index: usize) void {
        const slot = self.slotAt(index) orelse return;
        if (self.jog == index) self.jog = null;
        if (!slot.playing) return;
        self.finishAt(slot, self.nowNs());
        self.pushMix();
        if (!self.anyPlaying()) self.stopClock();
    }

    pub fn stopAll(self: *Transport) void {
        const now = self.nowNs();
        self.jog = null;
        for (self.slots.items) |*slot| {
            if (slot.playing) self.finishAt(slot, now);
        }
        self.pushMix();
        self.stopClock();
    }

    pub fn seek(self: *Transport, index: usize, target: f32) void {
        const slot = self.slotAt(index) orelse return;
        const was_playing = slot.playing;
        if (was_playing) self.foldAt(slot, self.nowNs());
        slot.playing = false;
        slot.start_latched = false;
        slot.beat_raw = target;
        self.snapToBar(slot);
        slot.manual = false;
        if (was_playing) self.beginStart(slot, .next_bar);
    }

    /// Waveform drag: move by beats and land on the nearest beat.
    pub fn dragBeats(self: *Transport, index: usize, delta: f32) void {
        const slot = self.slotAt(index) orelse return;
        if (slot.playing) return;
        slot.beat_raw = std.math.clamp(slot.beat_raw + delta, 0, slot.total_beats);
        snapToBeat(slot);
        slot.manual = true;
    }

    /// Navigator drag: move by beats and land on the nearest bar.
    pub fn dragBar(self: *Transport, index: usize, delta: f32) void {
        const slot = self.slotAt(index) orelse return;
        if (slot.playing) return;
        slot.beat_raw = std.math.clamp(slot.beat_raw + delta, 0, slot.total_beats);
        self.snapToBar(slot);
        slot.manual = false;
    }

    pub fn jogPause(self: *Transport, index: usize, join: Join) void {
        const slot = self.slotAt(index) orelse return;
        if (!slot.playing) return;
        self.foldAt(slot, self.nowNs());
        snapToBeat(slot);
        slot.playing = false;
        slot.start_latched = false;
        self.jog = index;
        self.jog_join = join;
        self.pushMix();
        if (!self.anyPlaying()) self.stopClock();
    }

    /// Ends the jog and resumes the lane from the nearest beat.
    pub fn jogResume(self: *Transport) void {
        const index = self.jog orelse return;
        self.jog = null;
        const slot = self.slotAt(index) orelse return;
        snapToBeat(slot);
        const join: Join = if (self.jog_join == .bar) .next_bar else self.jog_join;
        self.beginStart(slot, join);
    }

    /// Applies a whole EQ without restarting the decoder.
    pub fn setEq(self: *Transport, index: usize, params: mixer.EqParams) void {
        const slot = self.slotAt(index) orelse return;
        slot.eq = params;
        slot.eq_preset = .none;
        for (&slot.eq.gain_db) |*gain| gain.* = std.math.clamp(gain.*, -mixer.eq_max_gain_db, mixer.eq_max_gain_db);
        if (slot.playing) self.pushMix();
    }

    pub fn setEqGain(self: *Transport, index: usize, band: usize, gain_db: f32) void {
        const slot = self.slotAt(index) orelse return;
        if (band >= mixer.band_count) return;
        slot.eq.gain_db[band] = std.math.clamp(gain_db, -mixer.eq_max_gain_db, mixer.eq_max_gain_db);
        slot.eq_preset = .none;
        if (slot.playing) self.pushMix();
    }

    /// Moves one node: frequency and gain together, as the ball drags.
    pub fn setEqNode(self: *Transport, index: usize, band: usize, gain_db: f32, freq_hz: f32) void {
        const slot = self.slotAt(index) orelse return;
        if (band >= mixer.band_count) return;
        slot.eq.gain_db[band] = std.math.clamp(gain_db, -mixer.eq_max_gain_db, mixer.eq_max_gain_db);
        slot.eq.freq_hz[band] = std.math.clamp(freq_hz, mixer.eq_min_hz, mixer.eq_max_hz);
        slot.eq_preset = .none;
        if (slot.playing) self.pushMix();
    }

    pub fn setEqPreset(self: *Transport, index: usize, preset: mixer.EqPreset) void {
        const slot = self.slotAt(index) orelse return;
        slot.eq = mixer.presetEq(preset);
        slot.eq_preset = preset;
        if (slot.playing) self.pushMix();
    }

    pub fn eqParams(self: *Transport, index: usize) mixer.EqParams {
        const slot = self.slotAt(index) orelse return .{};
        return slot.eq;
    }

    pub fn eqPreset(self: *Transport, index: usize) mixer.EqPreset {
        const slot = self.slotAt(index) orelse return .none;
        return slot.eq_preset;
    }

    /// Silences a lane without stopping it: the decoder, position and clock
    /// all carry on.
    pub fn setMute(self: *Transport, index: usize, on: bool) void {
        const slot = self.slotAt(index) orelse return;
        if (slot.muted == on) return;
        slot.muted = on;
        if (slot.playing) self.pushMix();
    }

    pub fn muted(self: *Transport, index: usize) bool {
        const slot = self.slotAt(index) orelse return false;
        return slot.muted;
    }

    /// Applies the lane's trim without restarting its decoder.
    pub fn setTrim(self: *Transport, index: usize, db: f32) void {
        const slot = self.slotAt(index) orelse return;
        slot.trim_db = std.math.clamp(db, -mixer.trim_max_db, mixer.trim_max_db);
        if (slot.playing) self.pushMix();
    }

    pub fn trim(self: *Transport, index: usize) f32 {
        const slot = self.slotAt(index) orelse return 0;
        return slot.trim_db;
    }

    /// The lane's live post-trim peak, for its meter.
    pub fn level(self: *Transport, index: usize) f32 {
        const slot = self.slotAt(index) orelse return 0;
        return self.output.level(self.output.context, slot.uid);
    }

    /// The lane's live spectrum, for the EQ panel.
    pub fn spectrum(self: *Transport, index: usize, out: []f32) void {
        const slot = self.slotAt(index) orelse {
            @memset(out, 0);
            return;
        };
        self.output.spectrum(self.output.context, slot.uid, out);
    }


    /// Rebases the master clock before the tempo change so the playhead does
    /// not jump, then restarts the decoders from their folded positions.
    pub fn setTempo(self: *Transport, bpm: f32) void {
        if (@abs(bpm - self.bpm) < 0.0005) return;
        const now = self.nowNs();
        for (self.slots.items) |*slot| {
            if (slot.playing) self.foldAt(slot, now);
        }
        if (self.running) {
            self.clock_base_beat = self.masterBeatAt(now);
            self.clock_base_ns = now;
        }
        self.bpm = bpm;
        for (self.slots.items) |*slot| {
            if (!slot.playing) continue;
            slot.start_latched = false;
            slot.start_at_ns = 0;
            slot.restart = true;
        }
        self.pushMix();
    }

    pub fn setKeylock(self: *Transport, keylock: bool) void {
        if (keylock == self.keylock) return;
        const now = self.nowNs();
        for (self.slots.items) |*slot| {
            if (slot.playing) self.foldAt(slot, now);
        }
        self.keylock = keylock;
        for (self.slots.items) |*slot| {
            if (!slot.playing) continue;
            slot.start_latched = false;
            slot.start_at_ns = 0;
            slot.restart = true;
        }
        self.pushMix();
    }

    pub fn keylocked(self: *const Transport) bool {
        return self.keylock;
    }

    pub fn beat(self: *Transport, index: usize) f32 {
        const slot = self.slotAt(index) orelse return 0;
        if (!slot.playing) return slot.beat;
        return self.beatAt(slot, self.nowNs());
    }

    pub fn isPlaying(self: *Transport, index: usize) bool {
        const slot = self.slotAt(index) orelse return false;
        return slot.playing;
    }

    pub fn anyPlaying(self: *const Transport) bool {
        for (self.slots.items) |*slot| {
            if (slot.playing) return true;
        }
        return false;
    }

    fn playingCount(self: *const Transport) usize {
        var count: usize = 0;
        for (self.slots.items) |*slot| {
            if (slot.playing) count += 1;
        }
        return count;
    }

    pub fn nowNs(self: *const Transport) i128 {
        return self.clock.nowNs(self.clock.context);
    }

    fn slotFor(self: *Transport, index: usize, info: LaneInfo) ?*Slot {
        // Identity is the crate position: the same track may appear twice, so
        // a track id alone cannot pick a lane.
        for (self.slots.items) |*slot| {
            if (slot.index != index or slot.track_id != info.track.id) continue;
            return slot;
        }
        return self.appendSlot(index, info.track.id);
    }

    fn appendSlot(self: *Transport, index: usize, track_id: u64) ?*Slot {
        self.slots.append(self.allocator, .{
            .uid = self.next_uid,
            .track_id = track_id,
            .index = index,
        }) catch return null;
        self.next_uid += 1;
        return &self.slots.items[self.slots.items.len - 1];
    }

    fn fill(self: *Transport, slot: *Slot, index: usize, info: LaneInfo) void {
        _ = self;
        slot.index = index;
        slot.seen = true;
        slot.track_id = info.track.id;
        slot.track = info.track;
        slot.analysis = info.analysis;
        slot.grid_bpm = if (info.grid_bpm > 0) info.grid_bpm else 128;
        slot.total_beats = info.total_beats;
        slot.offset = info.offset;
        slot.first_downbeat = info.first_downbeat;
    }

    fn slotAt(self: *Transport, index: usize) ?*Slot {
        for (self.slots.items) |*slot| {
            if (slot.index == index) return slot;
        }
        return null;
    }

    fn beginStart(self: *Transport, slot: *Slot, join: Join) void {
        if (slot.playing or slot.analysis == null) return;
        if (self.playingCount() >= max_lanes) return;
        self.poseForStart(slot);
        const now = self.nowNs();
        const start_at = switch (join) {
            .bar => self.barStartAt(now),
            .next_bar => self.nextBarAt(now),
            .now => 0,
        };
        slot.playing = true;
        slot.start_latched = false;
        slot.rejoin = join == .next_bar;
        slot.start_at_ns = start_at;
        self.pushMix();
    }

    /// Audio-clock time of the next master bar, or now when a bar is close
    /// enough that another bar of silence would be worse than a small offset.
    fn barStartAt(self: *Transport, now: i128) i128 {
        if (!self.running) return 0;
        const phase = @mod(self.masterBeatAt(now), 4);
        const wait: f32 = if (phase > 0.25) 4 - phase else 0;
        return now + @as(i128, @intFromFloat(@as(f64, wait) * 60 / self.bpm * 1_000_000_000));
    }

    /// The next master bar in audio-clock time; zero when the clock is stopped.
    pub fn nextBarTime(self: *Transport) i128 {
        return self.nextBarAt(self.nowNs());
    }

    /// The first master bar strictly after `time_ns`; zero when stopped.
    pub fn nextBarAfter(self: *Transport, time_ns: i128) i128 {
        if (!self.running) return 0;
        const phase = @mod(self.masterBeatAt(time_ns), 4);
        const wait = 4 - phase;
        return time_ns + @as(i128, @intFromFloat(@as(f64, wait) * 60 / self.bpm * 1_000_000_000));
    }

    /// The next master bar after `now`, never the current one: a lane rejoining
    /// mid-song must not land a fraction of a beat after the other lanes.
    fn nextBarAt(self: *Transport, now: i128) i128 {
        if (!self.running) return 0;
        const phase = @mod(self.masterBeatAt(now), 4);
        const wait = 4 - phase;
        return now + @as(i128, @intFromFloat(@as(f64, wait) * 60 / self.bpm * 1_000_000_000));
    }

    fn poseForStart(self: *Transport, slot: *Slot) void {
        _ = self;
        if (slot.manual) return;
        if (slot.beat < slot.first_downbeat) {
            slot.beat = slot.first_downbeat;
            slot.beat_raw = slot.beat;
        }
    }

    fn finishAt(self: *Transport, slot: *Slot, now: i128) void {
        self.foldAt(slot, now);
        self.snapToBar(slot);
        slot.manual = false;
        slot.playing = false;
        slot.start_latched = false;
    }

    fn foldAt(self: *Transport, slot: *Slot, now: i128) void {
        slot.beat = self.beatAt(slot, now);
        slot.beat_raw = slot.beat;
        slot.start_latched = false;
    }

    fn beatAt(self: *Transport, slot: *Slot, now: i128) f32 {
        if (!slot.playing or !slot.start_latched) return slot.beat;
        const master = self.masterBeatAt(now);
        if (master <= slot.started_master) return slot.beat;
        return slot.beat + (master - slot.started_master);
    }

    fn masterBeatAt(self: *Transport, time_ns: i128) f32 {
        if (!self.running) return self.clock_base_beat;
        const elapsed = @max(0, time_ns - self.clock_base_ns);
        const seconds: f64 = @as(f64, @floatFromInt(elapsed)) / 1_000_000_000;
        return self.clock_base_beat + @as(f32, @floatCast(seconds * self.bpm / 60));
    }

    fn stopClock(self: *Transport) void {
        if (!self.running) return;
        const now = self.nowNs();
        self.clock_base_beat = self.masterBeatAt(now);
        self.clock_base_ns = now;
        self.running = false;
    }

    fn snapToBar(self: *Transport, slot: *Slot) void {
        _ = self;
        const total = slot.total_beats;
        slot.beat_raw = std.math.clamp(slot.beat_raw, 0, total);
        const offset = slot.offset;
        const snapped = @round((slot.beat_raw + offset) / 4) * 4 - offset;
        // A rounded pose can sit past the last full bar of a short track.
        const last_bar = @max(0, @floor((total + offset) / 4) * 4 - offset);
        slot.beat = std.math.clamp(snapped, 0, last_bar);
        slot.beat_raw = slot.beat;
    }

    fn secondsAt(slot: *const Slot, at: f32) f64 {
        if (slot.analysis) |analysis| return analysis.beatTimeMs(at) / 1000;
        return @as(f64, at) * 60 / slot.grid_bpm;
    }

    fn spec(self: *const Transport, slot: *const Slot) mixer.Lane {
        return .{
            .uid = slot.uid,
            .track = slot.track,
            .start_s = secondsAt(slot, slot.beat),
            .tempo = self.bpm / slot.grid_bpm,
            .eq = slot.eq,
            .muted = slot.muted,
            .trim_db = slot.trim_db,
            .keylock = self.keylock,
            .start_at_ns = slot.start_at_ns,
            .restart = slot.restart,
        };
    }

    fn pushMix(self: *Transport) void {
        var specs: [max_lanes]mixer.Lane = undefined;
        var count: usize = 0;
        var key: u64 = 1469598103934665603;
        for (self.slots.items) |*slot| {
            if (!slot.playing) continue;
            if (count >= specs.len) break;
            const lane = self.spec(slot);
            specs[count] = lane;
            count += 1;
            key = mixHash(key, lane.uid);
            key = mixHash(key, @bitCast(lane.start_s));
            key = mixHash(key, @as(u32, @bitCast(lane.tempo)));
            key = hashEq(key, lane.eq);
            key = mixHash(key, @intFromBool(lane.muted));
            key = mixHash(key, @as(u32, @bitCast(lane.trim_db)));
            key = mixHash(key, @intFromBool(lane.keylock));
            key = mixHash(key, @intFromBool(lane.restart));
            key = mixHash(key, @as(u64, @intCast(@max(0, lane.start_at_ns) / 1_000_000)));
        }
        if (count == 0) {
            if (self.mixed) self.output.stop(self.output.context);
            self.mixed = false;
            self.mix_key = 0;
            return;
        }
        if (self.mixed and key == self.mix_key) return;
        self.output.play(self.output.context, specs[0..count]);
        self.mixed = true;
        self.mix_key = key;
        for (self.slots.items) |*slot| slot.restart = false;
    }

    fn mixHash(seed: u64, value: u64) u64 {
        return (seed ^ value) *% 1099511628211;
    }

    fn hashEq(seed: u64, eq: mixer.EqParams) u64 {
        var key = seed;
        for (eq.gain_db) |gain| key = mixHash(key, @as(u32, @bitCast(gain)));
        for (eq.freq_hz) |hz| key = mixHash(key, @as(u32, @bitCast(hz)));
        for (eq.q) |q| key = mixHash(key, @as(u32, @bitCast(q)));
        return key;
    }
};

/// Rounds the audible pose to the nearest beat. `beat_raw` keeps the sub-beat
/// remainder so slow drags still accumulate instead of sticking.
fn snapToBeat(slot: *Slot) void {
    slot.beat = @round(slot.beat_raw);
}

test {
    _ = std.testing.refAllDecls(@This());
}

const testing = std.testing;

var test_waveform = [_]u8{0};

var test_beats: [16]analysis_mod.Beat = blk: {
    var beats: [16]analysis_mod.Beat = undefined;
    for (&beats, 0..) |*beat, i| {
        beat.* = .{
            .time_ms = @intCast(i * 500),
            .bpm = 120,
            .position = @intCast(i % 4 + 1),
        };
    }
    break :blk beats;
};

const test_analysis = analysis_mod.Analysis{
    .bands = &.{},
    .beats = &test_beats,
    .waveform = &test_waveform,
    .peak = 0,
};

fn laneInfo(id: u64) LaneInfo {
    return .{
        .track = .{ .id = id, .title = "", .artist = "" },
        .analysis = &test_analysis,
        .grid_bpm = 120,
        .total_beats = 16,
        .offset = 0,
        .first_downbeat = 0,
    };
}

const TestClock = struct {
    now: i128 = 0,

    fn nowNs(context: *anyopaque) i128 {
        const self: *TestClock = @ptrCast(@alignCast(context));
        return self.now;
    }

    fn clock(self: *TestClock) Clock {
        return .{ .context = self, .nowNs = nowNs };
    }
};

const FakeEntry = struct {
    uid: u64 = 0,
    track_id: u64 = 0,
    state: mixer.LaneState = .missing,
    start_s: f64 = 0,
    tempo: f32 = 0,
    keylock: bool = false,
    level: f32 = 0,
};

const FakeOutput = struct {
    lanes: [max_lanes]mixer.Lane = undefined,
    count: usize = 0,
    plays: usize = 0,
    stops: usize = 0,
    entries: [max_lanes]FakeEntry = @splat(.{}),

    fn output(self: *FakeOutput) Output {
        return .{
            .context = self,
            .play = play,
            .stop = stop,
            .laneState = laneState,
            .spectrum = spectrum,
            .level = level,
        };
    }

    fn spectrum(_: *anyopaque, _: u64, out: []f32) void {
        @memset(out, 0);
    }

    fn level(context: *anyopaque, uid: u64) f32 {
        const self: *FakeOutput = @ptrCast(@alignCast(context));
        const entry = self.find(uid) orelse return 0;
        return entry.level;
    }

    fn play(context: *anyopaque, lanes: []const mixer.Lane) void {
        const self: *FakeOutput = @ptrCast(@alignCast(context));
        self.plays += 1;
        self.count = lanes.len;
        for (lanes, 0..) |lane, i| self.lanes[i] = lane;
        for (&self.entries) |*entry| {
            if (entry.uid == 0) continue;
            var kept = false;
            for (lanes) |lane| {
                if (lane.uid != entry.uid) continue;
                kept = true;
                break;
            }
            if (!kept) entry.* = .{};
        }
        for (lanes) |lane| {
            const entry = self.find(lane.uid) orelse self.freeEntry();
            const restarted = lane.restart or entry.uid != lane.uid or
                @abs(entry.start_s - lane.start_s) >= 0.001 or
                entry.tempo != lane.tempo or entry.keylock != lane.keylock;
            if (restarted) entry.* = .{
                .uid = lane.uid,
                .track_id = lane.track.id,
                .state = .pending,
                .start_s = lane.start_s,
                .tempo = lane.tempo,
                .keylock = lane.keylock,
            };
        }
    }

    fn stop(context: *anyopaque) void {
        const self: *FakeOutput = @ptrCast(@alignCast(context));
        self.stops += 1;
        self.count = 0;
        self.entries = @splat(.{});
    }

    fn laneState(context: *anyopaque, uid: u64) mixer.LaneState {
        const self: *FakeOutput = @ptrCast(@alignCast(context));
        for (&self.entries) |*entry| {
            if (entry.uid != uid) continue;
            return entry.state;
        }
        return .missing;
    }

    /// Simulates the decoder producing its first samples.
    fn markStarted(self: *FakeOutput, track_id: u64, at_ns: i128) void {
        const entry = self.findByTrack(track_id) orelse return;
        entry.state = .{ .started = at_ns };
    }

    fn markStartedUid(self: *FakeOutput, uid: u64, at_ns: i128) void {
        const entry = self.find(uid) orelse return;
        entry.state = .{ .started = at_ns };
    }

    fn markEnded(self: *FakeOutput, track_id: u64) void {
        const entry = self.findByTrack(track_id) orelse return;
        entry.state = .ended;
    }

    fn find(self: *FakeOutput, uid: u64) ?*FakeEntry {
        for (&self.entries) |*entry| {
            if (entry.uid == uid) return entry;
        }
        return null;
    }

    fn findByTrack(self: *FakeOutput, track_id: u64) ?*FakeEntry {
        for (&self.entries) |*entry| {
            if (entry.track_id == track_id) return entry;
        }
        return null;
    }

    fn freeEntry(self: *FakeOutput) *FakeEntry {
        for (&self.entries) |*entry| {
            if (entry.uid == 0) return entry;
        }
        return &self.entries[0];
    }

    fn playingLane(self: *FakeOutput, track_id: u64) ?mixer.Lane {
        for (self.lanes[0..self.count]) |lane| {
            if (lane.track.id == track_id) return lane;
        }
        return null;
    }
};

fn expectApprox(expected: f32, actual: f32) !void {
    try testing.expect(@abs(expected - actual) < 0.01);
}

fn setup(fake: *FakeOutput, clock: *TestClock) Transport {
    var t = Transport.init(testing.allocator, fake.output(), clock.clock());
    t.setTempo(120);
    return t;
}

test "cold start waits for audio and advances from its own clock" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.resolve(1, laneInfo(2));
    t.endSync();
    t.startAll();

    try testing.expectEqual(@as(usize, 1), fake.plays);
    try testing.expectEqual(@as(usize, 2), fake.count);
    try testing.expect(t.anyPlaying());

    clock.now = 500_000_000;
    t.sync();
    try expectApprox(0, t.beat(0));

    fake.markStarted(1, 1_000_000_000);
    fake.markStarted(2, 1_000_000_000);
    t.sync();
    clock.now = 2_500_000_000;
    t.sync();
    // 1.5 s at 120 BPM.
    try expectApprox(3, t.beat(0));
    try expectApprox(3, t.beat(1));
}

test "mute reaches the mixer lane and the beat keeps advancing" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.endSync();
    t.startAll();

    fake.markStarted(1, 0);
    clock.now = 1_000_000_000;
    t.sync();
    const before = fake.playingLane(1) orelse return error.NoLane;
    try testing.expect(!before.muted);
    try expectApprox(2, t.beat(0));

    t.setMute(0, true);
    const muted = fake.playingLane(1) orelse return error.NoLane;
    try testing.expect(muted.muted);
    try testing.expect(@abs(before.start_s - muted.start_s) < 1e-9);
    try testing.expect(t.isPlaying(0));
    try expectApprox(2, t.beat(0));

    clock.now = 1_500_000_000;
    t.sync();
    try expectApprox(3, t.beat(0));

    t.setMute(0, false);
    const unmuted = fake.playingLane(1) orelse return error.NoLane;
    try testing.expect(!unmuted.muted);
}

test "late join waits for the next bar and starts pending" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.resolve(1, laneInfo(2));
    t.endSync();

    t.start(0, .now);
    fake.markStarted(1, 0);
    t.sync();

    clock.now = 1_500_000_000;
    t.sync();
    try expectApprox(3, t.beat(0));

    t.start(1, .bar);
    const joining = fake.playingLane(2) orelse return error.NoLane;
    // One beat until the next bar, at 120 BPM: half a second.
    try testing.expectEqual(@as(i128, 2_000_000_000), joining.start_at_ns);
    try expectApprox(0, t.beat(1));

    clock.now = 1_900_000_000;
    t.sync();
    try expectApprox(0, t.beat(1));

    fake.markStarted(2, 2_000_000_000);
    t.sync();
    clock.now = 2_500_000_000;
    t.sync();
    try expectApprox(1, t.beat(1));
}

test "stopping a pending cold start cannot be restarted by late audio" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.endSync();
    t.start(0, .now);
    try testing.expect(t.anyPlaying());

    t.stop(0);
    try testing.expect(!t.anyPlaying());
    try testing.expectEqual(@as(usize, 1), fake.stops);

    fake.markStarted(1, 0);
    clock.now = 1_000_000_000;
    t.sync();
    try testing.expect(!t.anyPlaying());
    try expectApprox(0, t.beat(0));
    try testing.expectEqual(@as(usize, 1), fake.plays);
}

test "jog stops, then resumes at the jogged beat without a bar wait" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.endSync();
    t.start(0, .now);
    fake.markStarted(1, 0);
    t.sync();

    clock.now = 1_000_000_000;
    t.sync();
    try expectApprox(2, t.beat(0));

    t.jogPause(0, .now);
    try testing.expect(!t.isPlaying(0));
    try expectApprox(2, t.beat(0));
    try testing.expectEqual(@as(usize, 1), fake.stops);

    t.jogResume();
    const resumed = fake.playingLane(1) orelse return error.NoLane;
    try testing.expectEqual(@as(i128, 0), resumed.start_at_ns);
    try expectApprox(1.0, @floatCast(resumed.start_s));
    try expectApprox(2, t.beat(0));

    fake.markStarted(1, 2_000_000_000);
    t.sync();
    clock.now = 2_250_000_000;
    t.sync();
    try expectApprox(2.5, t.beat(0));
}

test "jog release without a drag resumes on the nearest beat" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.endSync();
    t.start(0, .now);
    fake.markStarted(1, 0);
    t.sync();

    clock.now = 1_100_000_000;
    t.sync();
    try expectApprox(2.2, t.beat(0));

    t.jogPause(0, .now);
    try expectApprox(2, t.beat(0));

    t.jogResume();
    const resumed = fake.playingLane(1) orelse return error.NoLane;
    try expectApprox(1.0, @floatCast(resumed.start_s));
    try expectApprox(2, t.beat(0));
}

test "jog drag keeps sub-beat movement until the release snaps it" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.endSync();
    t.start(0, .now);
    fake.markStarted(1, 0);
    t.sync();

    clock.now = 1_100_000_000;
    t.sync();

    t.jogPause(0, .now);
    t.dragBeats(0, 0.2);
    try expectApprox(2, t.beat(0));
    t.dragBeats(0, 0.2);
    try expectApprox(3, t.beat(0));

    t.jogResume();
    const resumed = fake.playingLane(1) orelse return error.NoLane;
    try expectApprox(1.5, @floatCast(resumed.start_s));
}

test "preview click while playing joins the next master bar" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.endSync();
    t.start(0, .now);
    fake.markStarted(1, 0);
    t.sync();

    clock.now = 500_000_000;
    t.sync();
    t.seek(0, 8);

    const resumed = fake.playingLane(1) orelse return error.NoLane;
    try expectApprox(4.0, @floatCast(resumed.start_s));
    try testing.expect(@abs(@as(i128, 2_000_000_000) - resumed.start_at_ns) < 1_000);
}

test "preview drag release joins the next master bar" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.resolve(1, laneInfo(2));
    t.endSync();
    t.start(0, .now);
    t.start(1, .now);
    fake.markStarted(1, 0);
    fake.markStarted(2, 0);
    t.sync();

    clock.now = 500_000_000;
    t.sync();
    t.jogPause(0, .bar);
    t.dragBar(0, 2);
    t.jogResume();

    const resumed = fake.playingLane(1) orelse return error.NoLane;
    try expectApprox(2.0, @floatCast(resumed.start_s));
    try testing.expect(@abs(@as(i128, 2_000_000_000) - resumed.start_at_ns) < 1_000);
}

test "a seek just after a bar waits for the next one" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.endSync();
    t.start(0, .now);
    fake.markStarted(1, 0);
    t.sync();

    // 0.1 of a beat after the master bar: close enough for a joint start, not
    // for one lane rejoining the others.
    clock.now = 50_000_000;
    t.sync();
    t.seek(0, 8);

    const resumed = fake.playingLane(1) orelse return error.NoLane;
    try testing.expect(@abs(@as(i128, 2_000_000_000) - resumed.start_at_ns) < 1_000);
}

test "a rejoin that misses its bar moves to the next bar" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.resolve(1, laneInfo(2));
    t.endSync();
    t.start(0, .now);
    t.start(1, .now);
    fake.markStarted(1, 0);
    fake.markStarted(2, 0);
    t.sync();

    clock.now = 500_000_000;
    t.sync();
    t.seek(0, 8);
    // The restarted decoder has not prefilled by its bar.
    clock.now = 2_150_000_000;
    t.sync();

    const resumed = fake.playingLane(1) orelse return error.NoLane;
    try testing.expect(@abs(@as(i128, 4_000_000_000) - resumed.start_at_ns) < 1_000);
}

test "a busy probe does not move a rejoin" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.resolve(1, laneInfo(2));
    t.endSync();
    t.start(0, .now);
    t.start(1, .now);
    fake.markStarted(1, 0);
    fake.markStarted(2, 0);
    t.sync();

    clock.now = 500_000_000;
    t.sync();
    t.seek(0, 8);

    const probe = fake.find(1) orelse return error.NoLane;
    probe.state = .busy;
    clock.now = 2_050_000_000;
    t.sync();

    const resumed = fake.playingLane(1) orelse return error.NoLane;
    try testing.expect(@abs(@as(i128, 2_000_000_000) - resumed.start_at_ns) < 1_000);
}

test "a joint start keeps its bar while the decoder prefills" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.resolve(1, laneInfo(2));
    t.endSync();
    t.start(0, .now);
    fake.markStarted(1, 0);
    t.sync();

    clock.now = 500_000_000;
    t.sync();
    t.start(1, .bar);
    clock.now = 2_050_000_000;
    t.sync();

    const resumed = fake.playingLane(2) orelse return error.NoLane;
    try testing.expect(@abs(@as(i128, 2_000_000_000) - resumed.start_at_ns) < 1_000);
}

test "a group start starts only the given lanes" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    for (0..6) |index| t.resolve(index, laneInfo(index + 1));
    t.endSync();

    t.startGroup(&.{ 1, 3, 4, 5 });
    try testing.expect(!t.isPlaying(0));
    try testing.expect(t.isPlaying(1));
    try testing.expect(!t.isPlaying(2));
    try testing.expect(t.isPlaying(3));
    try testing.expect(t.isPlaying(4));
    try testing.expect(t.isPlaying(5));
}

test "the bar after a time skips the coming bar" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.endSync();
    t.start(0, .now);
    fake.markStarted(1, 0);
    t.sync();

    clock.now = 500_000_000;
    t.sync();
    const mid = t.nextBarAfter(clock.now);
    try testing.expect(@abs(@as(i128, 2_000_000_000) - mid) < 1_000);

    // Exactly on a bar, the next one is a full bar away.
    const on_bar = t.nextBarAfter(2_000_000_000);
    try testing.expect(@abs(@as(i128, 4_000_000_000) - on_bar) < 1_000);
}

test "presets reach the mixer and moving a node clears them" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.endSync();
    t.start(0, .now);
    fake.markStarted(1, 0);
    t.sync();

    t.setEqPreset(0, .lpf);
    const shaped = fake.playingLane(1) orelse return error.NoLane;
    try expectApprox(-mixer.eq_max_gain_db, shaped.eq.gain_db[2]);
    try testing.expectEqual(mixer.EqPreset.lpf, t.eqPreset(0));

    t.setEqNode(0, 2, 3, 4000);
    const moved = fake.playingLane(1) orelse return error.NoLane;
    try expectApprox(3, moved.eq.gain_db[2]);
    try expectApprox(4000, moved.eq.freq_hz[2]);
    try testing.expectEqual(mixer.EqPreset.none, t.eqPreset(0));
}

test "trim reaches the mixer lane without restarting it" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.endSync();
    t.start(0, .now);
    fake.markStarted(1, 0);
    t.sync();

    clock.now = 500_000_000;
    t.sync();
    const before = (fake.playingLane(1) orelse return error.NoLane).start_s;
    t.setTrim(0, -6);

    const lane = fake.playingLane(1) orelse return error.NoLane;
    try expectApprox(-6, lane.trim_db);
    try expectApprox(@floatCast(before), @floatCast(lane.start_s));
    try testing.expectEqual(@as(usize, 2), fake.plays);
    const entry = fake.findByTrack(1) orelse return error.NoLane;
    try testing.expectEqual(mixer.LaneState{ .started = 0 }, entry.state);

    fake.findByTrack(1).?.level = 0.5;
    try expectApprox(0.5, t.level(0));
}

test "tempo change folds the position before restarting" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.endSync();
    t.start(0, .now);
    fake.markStarted(1, 0);
    t.sync();

    clock.now = 1_000_000_000;
    t.sync();
    try expectApprox(2, t.beat(0));

    t.setTempo(240);
    try expectApprox(2, t.beat(0));
    const retuned = fake.playingLane(1) orelse return error.NoLane;
    try expectApprox(2.0, retuned.tempo);
    try expectApprox(1.0, @floatCast(retuned.start_s));

    fake.markStarted(1, 1_500_000_000);
    t.sync();
    clock.now = 1_750_000_000;
    t.sync();
    // A quarter second at 240 BPM.
    try expectApprox(3, t.beat(0));
}

test "EQ changes reach the running mixer without release or restart" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.endSync();
    t.start(0, .now);
    fake.markStarted(1, 0);
    t.sync();

    clock.now = 1_000_000_000;
    t.sync();
    const before = fake.playingLane(1) orelse return error.NoLane;
    const start_before = before.start_s;

    t.setEqGain(0, 1, 6);
    const boosted = fake.playingLane(1) orelse return error.NoLane;
    try expectApprox(6, boosted.eq.gain_db[1]);
    try expectApprox(@floatCast(start_before), @floatCast(boosted.start_s));
    try testing.expect(!boosted.restart);
    try expectApprox(2, t.beat(0));

    clock.now = 1_500_000_000;
    t.sync();
    try expectApprox(3, t.beat(0));
}

test "decoder end stops the lane on a bar" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.endSync();
    t.start(0, .now);
    fake.markStarted(1, 0);
    t.sync();

    clock.now = 1_000_000_000;
    t.sync();
    try expectApprox(2, t.beat(0));

    fake.markEnded(1);
    t.sync();
    try testing.expect(!t.anyPlaying());
    // 2 beats folded to the nearest bar.
    try expectApprox(4, t.beat(0));
    try testing.expectEqual(@as(usize, 1), fake.stops);
}

test "removing a playing lane leaves the others running" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.resolve(1, laneInfo(2));
    t.endSync();
    t.startAll();
    fake.markStarted(1, 0);
    fake.markStarted(2, 0);
    t.sync();

    clock.now = 1_000_000_000;
    t.sync();

    t.remove(1);
    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.endSync();

    try testing.expect(t.isPlaying(0));
    try testing.expectEqual(@as(usize, 1), fake.count);
    clock.now = 1_500_000_000;
    t.sync();
    try expectApprox(3, t.beat(0));
}

test "more crate lanes than mixer slots can play when others stop" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    for (0..9) |index| t.resolve(index, laneInfo(@intCast(index)));
    t.endSync();

    t.startAll();
    try testing.expectEqual(@as(usize, max_lanes), fake.count);
    try testing.expect(!t.isPlaying(8));

    t.stop(0);
    t.start(8, .now);
    try testing.expect(t.isPlaying(8));
    try testing.expectEqual(@as(usize, max_lanes), fake.count);
}

test "duplicate crate tracks keep separate playback state" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(7));
    t.resolve(1, laneInfo(7));
    t.endSync();

    t.startAll();
    try testing.expectEqual(@as(usize, 2), fake.count);
    const first = fake.lanes[0];
    const second = fake.lanes[1];
    try testing.expect(first.uid != second.uid);

    fake.markStartedUid(first.uid, 0);
    fake.markStartedUid(second.uid, 0);
    t.sync();
    clock.now = 1_000_000_000;
    t.sync();
    try expectApprox(2, t.beat(0));
    try expectApprox(2, t.beat(1));

    t.stop(1);
    try testing.expect(t.isPlaying(0));
    try testing.expect(!t.isPlaying(1));
}

fn laneInfoBars(id: u64, total: f32, offset: f32) LaneInfo {
    var info = laneInfo(id);
    info.total_beats = total;
    info.offset = offset;
    return info;
}

test "move keeps playback on the moved lane" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(1));
    t.resolve(1, laneInfo(2));
    t.resolve(2, laneInfo(3));
    t.endSync();
    t.start(0, .now);
    fake.markStarted(1, 0);
    t.sync();
    clock.now = 1_000_000_000;
    t.sync();
    try expectApprox(2, t.beat(0));

    t.move(0, 3);
    t.beginSync();
    t.resolve(0, laneInfo(2));
    t.resolve(1, laneInfo(3));
    t.resolve(2, laneInfo(1));
    t.endSync();

    try testing.expect(t.isPlaying(2));
    try testing.expect(!t.isPlaying(0));
    try testing.expectEqual(@as(usize, 1), fake.count);
    clock.now = 1_500_000_000;
    t.sync();
    try expectApprox(3, t.beat(2));
}

test "bar snap caps at the last full bar of a short track" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfoBars(1, 14, 0));
    t.resolve(1, laneInfoBars(2, 15, 0));
    t.resolve(2, laneInfoBars(3, 14, 1));
    t.resolve(3, laneInfoBars(4, 15, 1));
    t.endSync();

    t.seek(0, 13.9);
    t.seek(1, 14.9);
    t.seek(2, 13.9);
    t.seek(3, 14.9);
    try expectApprox(12, t.beat(0));
    try expectApprox(12, t.beat(1));
    try expectApprox(11, t.beat(2));
    try expectApprox(15, t.beat(3));
}

test "removing one of two duplicate tracks keeps the other playing" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(7));
    t.resolve(1, laneInfo(7));
    t.endSync();
    t.startAll();
    const first_uid = fake.lanes[0].uid;
    const second_uid = fake.lanes[1].uid;
    fake.markStartedUid(first_uid, 0);
    fake.markStartedUid(second_uid, 0);
    t.sync();
    clock.now = 1_000_000_000;
    t.sync();
    try expectApprox(2, t.beat(0));
    try expectApprox(2, t.beat(1));

    t.remove(0);
    t.beginSync();
    t.resolve(0, laneInfo(7));
    t.endSync();

    try testing.expect(t.isPlaying(0));
    try testing.expectEqual(@as(usize, 1), fake.count);
    try testing.expectEqual(second_uid, fake.lanes[0].uid);
    clock.now = 1_500_000_000;
    t.sync();
    try expectApprox(3, t.beat(0));
}

test "inserting before a playing duplicate shifts it, not its state" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(7));
    t.endSync();
    t.start(0, .now);
    const playing_uid = fake.lanes[0].uid;
    fake.markStartedUid(playing_uid, 0);
    t.sync();
    clock.now = 1_000_000_000;
    t.sync();
    try expectApprox(2, t.beat(0));

    t.insert(0);
    t.beginSync();
    t.resolve(0, laneInfo(7));
    t.resolve(1, laneInfo(7));
    t.endSync();

    try testing.expect(!t.isPlaying(0));
    try testing.expect(t.isPlaying(1));
    try testing.expectEqual(playing_uid, fake.lanes[0].uid);
    clock.now = 1_500_000_000;
    t.sync();
    try expectApprox(3, t.beat(1));
}

test "crate index zero is a real lane" {
    var fake = FakeOutput{};
    var clock = TestClock{};
    var t = setup(&fake, &clock);
    defer t.deinit();

    t.beginSync();
    t.resolve(0, laneInfo(0));
    t.endSync();

    t.start(0, .now);
    try testing.expect(t.isPlaying(0));
    try testing.expectEqual(@as(usize, 1), fake.count);
}
