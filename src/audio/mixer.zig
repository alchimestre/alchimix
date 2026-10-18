//! Plays grid lanes: one ffplay per lane, so any subset can run together.
//! Each process starts on its lane's playhead beat, at the master tempo, through
//! that lane's low pass, and runs to the end of the track.

const std = @import("std");
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
};

pub const max_lanes = 64;

pub const Mixer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    children: [max_lanes]?std.process.Child = @splat(null),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Mixer {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Mixer) void {
        self.stopAll();
        self.* = undefined;
    }

    pub fn play(self: *Mixer, slot: usize, lane: Lane) void {
        self.stop(slot);
        const index = slot;
        if (index >= max_lanes) return;
        self.children[index] = self.spawn(lane);
    }

    pub fn stop(self: *Mixer, slot: usize) void {
        if (slot >= max_lanes) return;
        if (self.children[slot]) |*child| {
            if (child.id) |pid| std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            _ = child.wait(self.io) catch {};
            self.children[slot] = null;
        }
    }

    pub fn stopAll(self: *Mixer) void {
        for (0..max_lanes) |index| self.stop(index);
    }

    pub fn running(self: *const Mixer, slot: usize) bool {
        if (slot >= max_lanes) return false;
        return self.children[slot] != null;
    }

    fn spawn(self: *Mixer, lane: Lane) ?std.process.Child {
        if (lane.track.file_path.len == 0) return null;

        const start = std.fmt.allocPrint(self.allocator, "{d:.3}", .{lane.start_s}) catch return null;
        defer self.allocator.free(start);

        const ratio = std.math.clamp(lane.tempo, 0.5, 2.0);
        const chain = if (lane.keylock)
            std.fmt.allocPrint(self.allocator, "atempo={d:.3},lowpass=f={d:.0}", .{
                ratio, lowPassHz(lane.filter),
            }) catch return null
        else
            std.fmt.allocPrint(self.allocator, "asetrate={d:.0},aresample=48000,lowpass=f={d:.0}", .{
                44100 * ratio, lowPassHz(lane.filter),
            }) catch return null;
        defer self.allocator.free(chain);

        return std.process.spawn(self.io, .{
            .argv = &.{
                "ffplay", "-nodisp", "-autoexit", "-loglevel", "error",
                "-ss",    start,  "-af",      chain,
                lane.track.file_path,
            },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch null;
    }
};

/// 200 Hz closed to 20 kHz open, evenly across the dial in octaves.
fn lowPassHz(filter: f32) f32 {
    const t = std.math.clamp(filter, 0, 1);
    return 200 * std.math.pow(f32, 100, t);
}
