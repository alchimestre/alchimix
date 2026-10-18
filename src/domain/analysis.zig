//! The beat grid and preview waveform rekordbox writes beside a track.
//!
//! A track's analysis sits in ANLZ files in the rekordbox share directory:
//! `ANLZ0000.DAT` carries the beat grid (`PQTZ`), `ANLZ0000.EXT` the preview
//! waveform (`PWV3`). Every section is a four-byte tag, a header length and a
//! total length, both big-endian.

const std = @import("std");

pub const Beat = struct {
    time_ms: u32,
    bpm: f32,
};

pub const Analysis = struct {
    beats: []Beat,
    /// One sample per 1/150 s of the track.
    waveform: []u8,

    pub const samples_per_second = 150;

    pub fn durationMs(self: Analysis) u32 {
        if (self.beats.len >= 2) {
            const last = self.beats[self.beats.len - 1];
            const previous = self.beats[self.beats.len - 2];
            return last.time_ms + (last.time_ms - previous.time_ms);
        }
        return @intCast(self.waveform.len * 1000 / samples_per_second);
    }

    pub fn bpm(self: Analysis) f32 {
        if (self.beats.len == 0) return 0;
        return self.beats[0].bpm;
    }

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        allocator.free(self.beats);
        allocator.free(self.waveform);
        self.* = undefined;
    }
};

pub const ParseError = error{NoBeatGrid, Malformed};

pub fn parse(allocator: std.mem.Allocator, dat: []const u8, ext: []const u8) !Analysis {
    const grid = section(dat, "PQTZ") orelse return error.NoBeatGrid;
    const preview = section(ext, "PWV3") orelse return error.Malformed;

    var beats: std.ArrayListUnmanaged(Beat) = .empty;
    errdefer beats.deinit(allocator);

    // Four bytes of padding, then eight-byte entries: beat, tempo x100, time.
    var offset: usize = 4;
    while (offset + 8 <= grid.len) : (offset += 8) {
        const tempo = std.mem.readInt(u16, grid[offset + 2 ..][0..2], .big);
        const time = std.mem.readInt(u32, grid[offset + 4 ..][0..4], .big);
        // The opening entry describes the grid origin and carries no tempo.
        if (tempo == 0) continue;
        try beats.append(allocator, .{
            .time_ms = time,
            .bpm = @as(f32, @floatFromInt(tempo)) / 100,
        });
    }
    if (beats.items.len == 0) return error.NoBeatGrid;

    const waveform = try allocator.dupe(u8, preview);
    errdefer allocator.free(waveform);

    return .{
        .beats = try beats.toOwnedSlice(allocator),
        .waveform = waveform,
    };
}

fn section(file: []const u8, tag: []const u8) ?[]const u8 {
    var offset: usize = 28; // PMAI header
    while (offset + 12 <= file.len) {
        const total = std.mem.readInt(u32, file[offset + 8 ..][0..4], .big);
        if (total < 12 or offset + total > file.len) return null;
        if (std.mem.eql(u8, file[offset..][0..4], tag)) {
            return file[offset + 12 .. offset + total];
        }
        offset += total;
    }
    return null;
}

const testing = std.testing;

fn writeSection(buffer: []u8, offset: usize, tag: []const u8, body: []const u8) usize {
    @memcpy(buffer[offset..][0..4], tag);
    std.mem.writeInt(u32, buffer[offset + 4 ..][0..4], 12, .big);
    std.mem.writeInt(u32, buffer[offset + 8 ..][0..4], @intCast(12 + body.len), .big);
    @memcpy(buffer[offset + 12 ..][0..body.len], body);
    return offset + 12 + body.len;
}

fn header(buffer: []u8) void {
    @memset(buffer[0..28], 0);
    @memcpy(buffer[0..4], "PMAI");
    std.mem.writeInt(u32, buffer[4..8], 28, .big);
}

test "reads the beat grid and the preview waveform" {
    var dat_buffer: [256]u8 = undefined;
    header(&dat_buffer);
    var body: [4 + 3 * 8]u8 = undefined;
    @memset(body[0..4], 0);
    // Origin entry, then two beats at 128 BPM, 468 ms apart.
    std.mem.writeInt(u16, body[4..6], 8, .big);
    std.mem.writeInt(u16, body[6..8], 0, .big);
    std.mem.writeInt(u32, body[8..12], 853, .big);
    std.mem.writeInt(u16, body[12..14], 1, .big);
    std.mem.writeInt(u16, body[14..16], 12800, .big);
    std.mem.writeInt(u32, body[16..20], 1000, .big);
    std.mem.writeInt(u16, body[20..22], 2, .big);
    std.mem.writeInt(u16, body[22..24], 12800, .big);
    std.mem.writeInt(u32, body[24..28], 1468, .big);
    const end = writeSection(&dat_buffer, 28, "PQTZ", &body);

    var ext_buffer: [64]u8 = undefined;
    header(&ext_buffer);
    const ext_end = writeSection(&ext_buffer, 28, "PWV3", &.{ 0, 40, 255 });

    var analysis = try parse(testing.allocator, dat_buffer[0..end], ext_buffer[0..ext_end]);
    defer analysis.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), analysis.beats.len);
    try testing.expectEqual(@as(u32, 1000), analysis.beats[0].time_ms);
    try testing.expectApproxEqAbs(@as(f32, 128), analysis.bpm(), 0.001);
    try testing.expectEqualSlices(u8, &.{ 0, 40, 255 }, analysis.waveform);
    try testing.expectEqual(@as(u32, 1936), analysis.durationMs());
}

test "a file without a beat grid is rejected" {
    var dat_buffer: [64]u8 = undefined;
    header(&dat_buffer);
    _ = writeSection(&dat_buffer, 28, "PPTH", "/music/track.aiff");

    var ext_buffer: [64]u8 = undefined;
    header(&ext_buffer);
    const ext_end = writeSection(&ext_buffer, 28, "PWV3", &.{ 1, 2 });

    try testing.expectError(error.NoBeatGrid, parse(testing.allocator, dat_buffer[0..50], ext_buffer[0..ext_end]));
}
