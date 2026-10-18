//! Plays the grid as one mixed stream.
//!
//! A single ffmpeg decodes every lane, applies its tempo, filter and start
//! offset in one filter graph, and mixes them sample-aligned; ffplay only plays
//! the resulting PCM. One process pair means there is no inter-lane skew from
//! separate players starting at different times.

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
    /// Silence inserted before the audio so the lane starts on a master bar.
    delay_ms: u32 = 0,
};

pub const Mixer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    decoder: ?std.process.Child = null,
    player: ?std.process.Child = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Mixer {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Mixer) void {
        self.stop();
        self.* = undefined;
    }

    pub fn play(self: *Mixer, lanes: []const Lane) void {
        self.stop();
        if (lanes.len == 0) return;

        var owned: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (owned.items) |text| self.allocator.free(text);
            owned.deinit(self.allocator);
        }

        var decoder_argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer decoder_argv.deinit(self.allocator);

        decoder_argv.appendSlice(self.allocator, &.{ "ffmpeg", "-hide_banner", "-loglevel", "error" }) catch return;

        for (lanes) |lane| {
            const start = std.fmt.allocPrint(self.allocator, "{d:.3}", .{lane.start_s}) catch return;
            owned.append(self.allocator, start) catch return;
            decoder_argv.appendSlice(self.allocator, &.{ "-ss", start, "-i", lane.track.file_path }) catch return;
        }

        const graph = self.buildGraph(lanes, &owned) catch return;
        decoder_argv.appendSlice(self.allocator, &.{
            "-filter_complex", graph, "-map", "[mix]",
            "-f",              "s16le", "-ac", "2",
            "-ar",             "48000", "-",
        }) catch return;

        const player_argv = [_][]const u8{
            "ffplay",  "-hide_banner", "-loglevel", "error", "-nodisp",
            "-autoexit", "-f",         "s16le",    "-ar",   "48000",
            "-ch_layout", "stereo",    "-",
        };

        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return;
        const write_end = std.Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } };
        const read_end = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };

        self.decoder = std.process.spawn(self.io, .{
            .argv = decoder_argv.items,
            .stdin = .ignore,
            .stdout = .{ .file = write_end },
            .stderr = .ignore,
        }) catch {
            _ = std.c.close(fds[0]);
            _ = std.c.close(fds[1]);
            return;
        };
        _ = std.c.close(fds[1]);

        self.player = std.process.spawn(self.io, .{
            .argv = &player_argv,
            .stdin = .{ .file = read_end },
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch null;
        _ = std.c.close(fds[0]);
    }

    pub fn stop(self: *Mixer) void {
        for ([_]*?std.process.Child{ &self.decoder, &self.player }) |slot| {
            if (slot.*) |*child| {
                // kill reaps the process and clears its id.
                child.kill(self.io);
                slot.* = null;
            }
        }
    }

    pub fn active(self: *const Mixer) bool {
        return self.decoder != null or self.player != null;
    }

    /// Builds the filter graph: per lane tempo, filter and bar delay, mixed.
    fn buildGraph(self: *Mixer, lanes: []const Lane, owned: *std.ArrayListUnmanaged([]const u8)) ![]const u8 {
        var buffer: [16 * 1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        for (lanes, 0..) |lane, index| {
            const ratio = std.math.clamp(lane.tempo, 0.5, 2.0);
            try writer.print("[{d}:a]", .{index});
            if (lane.delay_ms > 0) try writer.print("adelay={d}:all=1,", .{lane.delay_ms});
            if (lane.keylock) {
                try writer.print("atempo={d:.3},", .{ratio});
            } else {
                try writer.print("asetrate={d:.0},aresample=48000,", .{44100 * ratio});
            }
            try writer.print("lowpass=f={d:.0}[l{d}];", .{ lowPassHz(lane.filter), index });
        }
        for (lanes, 0..) |_, index| try writer.print("[l{d}]", .{index});
        try writer.print("amix=inputs={d}:duration=longest:dropout_transition=0:normalize=0,alimiter=limit=0.95", .{lanes.len});
        try writer.writeAll("[mix]");

        const graph = try self.allocator.dupe(u8, writer.buffered());
        try owned.append(self.allocator, graph);
        return graph;
    }
};

fn writeQuoted(writer: anytype, text: []const u8) !void {
    try writer.writeByte('\'');
    for (text) |byte| {
        if (byte == '\'') {
            try writer.writeAll("'\\''");
        } else {
            try writer.writeByte(byte);
        }
    }
    try writer.writeByte('\'');
}

/// 200 Hz closed to 20 kHz open, evenly across the dial in octaves.
fn lowPassHz(filter: f32) f32 {
    const t = std.math.clamp(filter, 0, 1);
    return 200 * std.math.pow(f32, 100, t);
}
