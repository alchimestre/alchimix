//! Fifteen-second previews from the middle of a track.
//!
//! Decoding is delegated to ffplay, so every format rekordbox holds plays
//! without the app linking a codec. One preview at a time.
//!
//! Pause stops the process and remembers where it was, then resume starts again
//! from that point: a stopped ffplay would keep the audio device open for as
//! long as the pause lasted.

const std = @import("std");
const Track = @import("../domain/track.zig").Track;

pub const snippet_seconds: u32 = 15;
const max_path = 1024;

pub const Player = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    child: ?std.process.Child = null,
    track_id: ?u64 = null,
    paused: bool = false,

    path: [max_path]u8 = undefined,
    path_len: usize = 0,
    /// Seconds into the track where the current snippet starts.
    snippet_start_s: u32 = 0,
    /// How long the current snippet runs, in milliseconds.
    window_ms: i64 = 0,
    /// When it ends, on the awake clock.
    deadline_ms: i64 = 0,
    /// Where the bar sits while paused.
    frozen_progress: f32 = 0,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) Player {
        return .{ .io = io, .allocator = allocator };
    }

    pub fn deinit(self: *Player) void {
        self.stop();
    }

    pub fn clockMs(self: *const Player) i64 {
        return nowMs(self);
    }

    pub fn holds(self: *const Player, track_id: u64) bool {
        return self.track_id == track_id;
    }

    pub fn isPlaying(self: *const Player, track_id: u64) bool {
        return self.holds(track_id) and !self.paused;
    }

    /// True only while samples are moving: a paused preview needs no repaint,
    /// and forcing one every frame with software rendering is what made the
    /// window sluggish.
    pub fn animating(self: *const Player) bool {
        return self.child != null and !self.paused;
    }

    /// Position inside the snippet, 0 to 1.
    pub fn progress(self: *const Player, track_id: u64) f32 {
        if (!self.holds(track_id) or self.window_ms <= 0) return 0;

        if (self.paused) return self.frozen_progress;

        const left_ms = @max(0, self.deadline_ms - nowMs(self));
        const done = self.window_ms - left_ms;
        return std.math.clamp(@as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(self.window_ms)), 0, 1);
    }

    pub fn toggle(self: *Player, track: Track) void {
        if (self.holds(track.id)) {
            if (self.paused) self.resumePlayback() else self.pause();
            return;
        }
        self.stop();
        self.start(track, middleStart(track), snippet_seconds);
    }

    /// Jump to a fraction of the snippet and play what is left of it. On a
    /// stopped or paused track this starts playback at that point.
    pub fn seek(self: *Player, track: Track, fraction: f32) void {
        const clamped = std.math.clamp(fraction, 0, 1);

        const base = if (self.holds(track.id)) self.snippet_start_s else middleStart(track);
        const window_s: f32 = if (self.holds(track.id) and self.window_ms > 0)
            @as(f32, @floatFromInt(self.window_ms)) / 1000.0
        else
            @as(f32, @floatFromInt(snippet_seconds));

        const offset = base + @as(u32, @intFromFloat(window_s * clamped));
        const left_s = @max(1, @as(u32, @intFromFloat(window_s * (1 - clamped))));

        self.stop();
        self.start(track, offset, left_s);
    }

    /// Ends the preview if it belongs to this track; another track's keeps
    /// playing.
    pub fn stopPreview(self: *Player, track_id: u64) void {
        if (self.holds(track_id)) self.stop();
    }

    /// Clears the preview once the snippet is over.
    pub fn poll(self: *Player) void {
        if (self.child == null or self.paused) return;
        if (nowMs(self) < self.deadline_ms) return;
        self.stop();
    }

    fn start(self: *Player, track: Track, offset_s: u32, length_s: u32) void {
        if (track.file_path.len == 0 or track.file_path.len > max_path) return;

        @memcpy(self.path[0..track.file_path.len], track.file_path);
        self.path_len = track.file_path.len;
        self.track_id = track.id;
        self.snippet_start_s = offset_s;
        self.window_ms = @as(i64, length_s) * 1000;
        self.paused = false;
        self.spawnNow(length_s, offset_s);
    }

    fn spawnNow(self: *Player, length_s: u32, offset_s: u32) void {
        const offset = std.fmt.allocPrint(self.allocator, "{d}", .{offset_s}) catch return;
        defer self.allocator.free(offset);
        const length = std.fmt.allocPrint(self.allocator, "{d}", .{length_s}) catch return;
        defer self.allocator.free(length);

        self.child = std.process.spawn(self.io, .{
            .argv = &.{
                "ffplay", "-nodisp", "-autoexit", "-loglevel", "error",
                "-ss",    offset,  "-t",        length,      self.path[0..self.path_len],
            },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch null;

        self.deadline_ms = nowMs(self) + self.window_ms;
    }

    fn pause(self: *Player) void {
        const left_ms = @max(0, self.deadline_ms - nowMs(self));
        const played_ms = self.window_ms - left_ms;
        self.frozen_progress = @min(1, @as(f32, @floatFromInt(played_ms)) / @as(f32, @floatFromInt(@max(self.window_ms, 1))));

        // Where the next start picks up, and how much is left of the snippet.
        self.snippet_start_s += @intCast(@divTrunc(played_ms, 1000));
        self.window_ms = @max(0, left_ms);
        self.paused = true;
        self.killChild();
    }

    fn resumePlayback(self: *Player) void {
        if (self.path_len == 0 or self.window_ms == 0) return;

        const length_s: u32 = @max(1, @as(u32, @intCast(@divTrunc(self.window_ms, 1000))));
        self.window_ms = @as(i64, length_s) * 1000;
        self.paused = false;
        self.spawnNow(length_s, self.snippet_start_s);
    }

    /// SIGKILL rather than the polite kill: ffplay does not act on SIGTERM
    /// until its event loop next runs, so waiting on it held the frame.
    fn killChild(self: *Player) void {
        if (self.child) |*child| {
            if (child.id) |pid| std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            _ = child.wait(self.io) catch {};
        }
        self.child = null;
    }

    fn stop(self: *Player) void {
        self.killChild();
        self.track_id = null;
        self.paused = false;
        self.path_len = 0;
        self.snippet_start_s = 0;
        self.window_ms = 0;
        self.deadline_ms = 0;
    }
};

/// The snippet starts in the middle, where a track is at its most itself.
fn middleStart(track: Track) u32 {
    if (track.length_s <= snippet_seconds) return 0;
    return track.length_s / 2 - snippet_seconds / 2;
}

/// Milliseconds on the awake clock: the snippet length must not jump when the
/// wall clock is adjusted.
fn nowMs(self: *const Player) i64 {
    const nanos = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
    return @intCast(@divTrunc(nanos, std.time.ns_per_ms));
}
