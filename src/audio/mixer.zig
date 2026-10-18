//! Plays every grid lane at once: one ffplay per lane, all started on the same
//! beat and retuned to the master tempo, each through its own low pass.

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

pub const snippet_s: u32 = 15;

pub const Mixer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    children: std.ArrayListUnmanaged(std.process.Child) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Mixer {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Mixer) void {
        self.stop();
        self.children.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn play(self: *Mixer, lanes: []const Lane) void {
        self.stop();
        for (lanes) |lane| self.spawn(lane);
    }

    pub fn stop(self: *Mixer) void {
        for (self.children.items) |*child| {
            if (child.id) |pid| std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            _ = child.wait(self.io) catch {};
        }
        self.children.clearRetainingCapacity();
    }

    pub fn active(self: *const Mixer) bool {
        return self.children.items.len > 0;
    }

    fn spawn(self: *Mixer, lane: Lane) void {
        if (lane.track.file_path.len == 0) return;

        const start = std.fmt.allocPrint(self.allocator, "{d:.3}", .{lane.start_s}) catch return;
        defer self.allocator.free(start);
        const length = std.fmt.allocPrint(self.allocator, "{d}", .{snippet_s}) catch return;
        defer self.allocator.free(length);
        const ratio = std.math.clamp(lane.tempo, 0.5, 2.0);
        const chain = if (lane.keylock)
            std.fmt.allocPrint(self.allocator, "atempo={d:.3},lowpass=f={d:.0}", .{
                ratio, lowPassHz(lane.filter),
            }) catch return
        else
            std.fmt.allocPrint(self.allocator, "asetrate={d:.0},aresample=48000,lowpass=f={d:.0}", .{
                44100 * ratio, lowPassHz(lane.filter),
            }) catch return;
        defer self.allocator.free(chain);

        const child = std.process.spawn(self.io, .{
            .argv = &.{
                "ffplay", "-nodisp", "-autoexit", "-loglevel", "error",
                "-ss",    start,  "-t",        length,
                "-af",    chain,  lane.track.file_path,
            },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return;

        self.children.append(self.allocator, child) catch {
            if (child.id) |pid| std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        };
    }
};

/// 200 Hz closed to 20 kHz open, evenly across the dial in octaves.
fn lowPassHz(filter: f32) f32 {
    const t = std.math.clamp(filter, 0, 1);
    return 200 * std.math.pow(f32, 100, t);
}
