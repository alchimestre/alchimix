//! The beat grid and preview waveform rekordbox writes beside a track.
//!
//! A track's analysis sits in ANLZ files in the rekordbox share directory:
//! `ANLZ0000.DAT` carries the beat grid (`PQTZ`), `ANLZ0000.EXT` the preview
//! waveform (`PWV3`). Every section is a four-byte tag, a header length and a
//! total length, both big-endian.

const std = @import("std");

/// One column of rekordbox's three-band colour waveform, 0..7 per band.
pub const Band = struct {
    low: u3,
    mid: u3,
    high: u3,
};

pub const Beat = struct {
    time_ms: u32,
    bpm: f32,
    /// Position inside the bar, 1..4, as rekordbox numbers it. This is the
    /// track's bar phase: beat 1 is a downbeat.
    position: u8,
};


/// A phrase boundary rekordbox marked: the beat the section opens on, 1-based,
/// and the kind of section it is. Kinds are rekordbox's own numbering.
pub const Phrase = struct {
    beat: u16,
    kind: u8,
};

pub const Analysis = struct {
    beats: []Beat,
    /// One sample per 1/150 s of the track.
    waveform: []u8,
    /// Three-band levels on the same 1/150 s grid. Empty when the file only
    /// carries the mono preview.
    bands: []Band,
    /// Loudest sample in the waveform, so a track can be coloured against its
    /// own range rather than an absolute one.
    peak: u8,
    /// Phrase boundaries, oldest first. Empty when the file carries no PSSI.
    phrases: []Phrase = &.{},

    pub const samples_per_second = 150;

    pub fn durationMs(self: Analysis) u32 {
        if (self.beats.len >= 2) {
            const last = self.beats[self.beats.len - 1];
            const previous = self.beats[self.beats.len - 2];
            return last.time_ms + (last.time_ms - previous.time_ms);
        }
        return @intCast(self.waveform.len * 1000 / samples_per_second);
    }

    /// Time of a (possibly fractional) beat, from the analysed grid rather than
    /// a nominal BPM. This is what the audio must be seeked to.
    pub fn beatTimeMs(self: Analysis, beat: f32) f64 {
        if (self.beats.len == 0 or beat <= 0) return 0;
        const index: usize = @intFromFloat(@floor(beat));
        if (index >= self.beats.len - 1) {
            return @floatFromInt(self.beats[self.beats.len - 1].time_ms);
        }
        const a = self.beats[index];
        const b = self.beats[index + 1];
        const fraction: f64 = @floatCast(beat - @as(f32, @floatFromInt(index)));
        return @as(f64, @floatFromInt(a.time_ms)) +
            (@as(f64, @floatFromInt(b.time_ms)) - @as(f64, @floatFromInt(a.time_ms))) * fraction;
    }

    /// Beats to subtract from a local beat to land on a downbeat. A grid whose
    /// first beat is the third of a bar starts two beats before one.
    pub fn downbeatOffset(self: Analysis) f32 {
        if (self.beats.len == 0) return 0;
        return @floatFromInt(self.beats[0].position - 1);
    }

    /// Beat index of the first downbeat. A grid whose first beat is the third
    /// of a bar starts two beats before one.
    pub fn firstDownbeat(self: Analysis) u32 {
        if (self.beats.len == 0) return 0;
        const position: u32 = self.beats[0].position;
        return (4 - (position - 1)) % 4;
    }

    /// The tempo most of the grid agrees on. Live recordings wobble and can
    /// carry a short section at another tempo; the first beat alone would put
    /// the whole transport on the wrong bar length.
    pub fn bpm(self: Analysis) f32 {
        if (self.beats.len == 0) return 0;
        var hist: [1800]u16 = @splat(0);
        var counted: usize = 0;
        for (self.beats) |beat| {
            if (beat.bpm < 60 or beat.bpm >= 240) continue;
            const bucket: usize = @intFromFloat(beat.bpm * 10);
            hist[bucket - 600] += 1;
            counted += 1;
        }
        if (counted == 0) return self.beats[0].bpm;
        const half = counted / 2;
        var seen: usize = 0;
        for (hist, 0..) |count, index| {
            seen += count;
            if (seen > half) return @as(f32, @floatFromInt(600 + index)) / 10;
        }
        return self.beats[0].bpm;
    }

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        allocator.free(self.beats);
        allocator.free(self.waveform);
        if (self.bands.len > 0) allocator.free(self.bands);
        if (self.phrases.len > 0) allocator.free(self.phrases);
        self.* = undefined;
    }
};

pub const ParseError = error{NoBeatGrid, Malformed};

pub fn parse(allocator: std.mem.Allocator, dat: []const u8, ext: []const u8) !Analysis {
    const grid = section(dat, "PQTZ") orelse return error.NoBeatGrid;
    const preview = entries(ext, "PWV3") orelse return error.Malformed;

    var beats: std.ArrayListUnmanaged(Beat) = .empty;
    errdefer beats.deinit(allocator);

    // Four bytes of padding, then eight-byte entries: beat, tempo x100, time.
    var offset: usize = 4;
    while (offset + 8 <= grid.len) : (offset += 8) {
        const number = std.mem.readInt(u16, grid[offset..][0..2], .big);
        const tempo = std.mem.readInt(u16, grid[offset + 2 ..][0..2], .big);
        const time = std.mem.readInt(u32, grid[offset + 4 ..][0..4], .big);
        // The opening entry describes the grid origin and carries no tempo.
        if (tempo == 0) continue;
        try beats.append(allocator, .{
            .time_ms = time,
            .bpm = @as(f32, @floatFromInt(tempo)) / 100,
            .position = @intCast(std.math.clamp(number, 1, 4)),
        });
    }
    if (beats.items.len == 0) return error.NoBeatGrid;

    const waveform = try allocator.dupe(u8, preview);
    errdefer allocator.free(waveform);

    var bands: []Band = &.{};
    if (entries(ext, "PWV5")) |color| {
        bands = try allocator.alloc(Band, waveform.len);
        errdefer allocator.free(bands);
        const sharp = @min(waveform.len, color.len / 2);
        for (bands, 0..) |*band, i| {
            if (i >= sharp) {
                band.* = .{ .low = 0, .mid = 0, .high = 0 };
                continue;
            }
            // Bits 15-13 red (kick), 12-10 green (mid), 9-7 blue (high),
            // 6-2 height. Red, green and blue are the band levels.
            const value = std.mem.readInt(u16, color[i * 2 ..][0..2], .big);
            band.* = .{
                .low = @intCast((value >> 13) & 0x7),
                .mid = @intCast((value >> 10) & 0x7),
                .high = @intCast((value >> 7) & 0x7),
            };
        }
    }

    var peak: u8 = 0;
    for (waveform) |sample| peak = @max(peak, sample);

    return .{
        .beats = try beats.toOwnedSlice(allocator),
        .waveform = waveform,
        .bands = bands,
        .peak = peak,
        .phrases = try readPhrases(allocator, ext),
    };
}

/// The phrase section is laid out differently from the waveform ones: a
/// twenty-byte header holding the entry size and the count, then the entries.
/// A missing section is not an error, most tracks carry none.
fn readPhrases(allocator: std.mem.Allocator, ext: []const u8) ![]Phrase {
    const body = section(ext, "PSSI") orelse return &.{};
    if (body.len < 20) return &.{};

    const stride = std.mem.readInt(u32, body[0..4], .big);
    const count = std.mem.readInt(u16, body[4..6], .big);
    if (stride < 6) return &.{};

    const room = (body.len - 20) / stride;
    const entries_count = @min(@as(usize, count), room);
    if (entries_count == 0) return &.{};

    const phrases = try allocator.alloc(Phrase, entries_count);
    errdefer allocator.free(phrases);
    for (phrases, 0..) |*phrase, i| {
        const entry = body[20 + i * stride ..][0..stride];
        phrase.* = .{
            .beat = std.mem.readInt(u16, entry[2..4], .big),
            .kind = @truncate(std.mem.readInt(u16, entry[4..6], .big)),
        };
    }
    return phrases;
}

/// The entry bytes of a waveform section, past its twelve-byte header.
fn entries(file: []const u8, tag: []const u8) ?[]const u8 {
    const body = section(file, tag) orelse return null;
    if (body.len < 12) return null;
    const entry_bytes = std.mem.readInt(u32, body[0..4], .big);
    const count = std.mem.readInt(u32, body[4..8], .big);
    if (entry_bytes == 0) return null;
    const needed = std.math.mul(u32, entry_bytes, count) catch return null;
    if (needed > body.len - 12) return null;
    return body[12..][0..needed];
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

fn writeWaveSection(buffer: []u8, offset: usize, tag: []const u8, entry_bytes: u32, count: u32, data: []const u8) usize {
    const total = 24 + data.len;
    @memcpy(buffer[offset..][0..4], tag);
    std.mem.writeInt(u32, buffer[offset + 4 ..][0..4], 24, .big);
    std.mem.writeInt(u32, buffer[offset + 8 ..][0..4], @intCast(total), .big);
    std.mem.writeInt(u32, buffer[offset + 12 ..][0..4], entry_bytes, .big);
    std.mem.writeInt(u32, buffer[offset + 16 ..][0..4], count, .big);
    std.mem.writeInt(u32, buffer[offset + 20 ..][0..4], 0, .big);
    @memcpy(buffer[offset + 24 ..][0..data.len], data);
    return offset + total;
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
    const ext_end = writeWaveSection(&ext_buffer, 28, "PWV3", 1, 3, &.{ 0, 40, 255 });

    var analysis = try parse(testing.allocator, dat_buffer[0..end], ext_buffer[0..ext_end]);
    defer analysis.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), analysis.beats.len);
    try testing.expectEqual(@as(u32, 1000), analysis.beats[0].time_ms);
    try testing.expectApproxEqAbs(@as(f32, 128), analysis.bpm(), 0.001);
    try testing.expectEqualSlices(u8, &.{ 0, 40, 255 }, analysis.waveform);
    try testing.expectEqual(@as(u32, 1936), analysis.durationMs());
}

test "reads the three-band colour waveform" {
    var dat_buffer: [128]u8 = undefined;
    header(&dat_buffer);
    var body: [4 + 8]u8 = undefined;
    @memset(body[0..4], 0);
    std.mem.writeInt(u16, body[4..6], 1, .big);
    std.mem.writeInt(u16, body[6..8], 12800, .big);
    std.mem.writeInt(u32, body[8..12], 1000, .big);
    const dat_end = writeSection(&dat_buffer, 28, "PQTZ", &body);

    var ext_buffer: [160]u8 = undefined;
    header(&ext_buffer);
    const after_wave = writeWaveSection(&ext_buffer, 28, "PWV3", 1, 2, &.{ 100, 50 });
    var color: [4]u8 = undefined;
    std.mem.writeInt(u16, color[0..2], (7 << 13) | (1 << 10) | (0 << 7) | (20 << 2), .big);
    std.mem.writeInt(u16, color[2..4], (0 << 13) | (3 << 10) | (7 << 7) | (10 << 2), .big);
    const ext_end = writeWaveSection(&ext_buffer, after_wave, "PWV5", 2, 2, &color);

    var analysis = try parse(testing.allocator, dat_buffer[0..dat_end], ext_buffer[0..ext_end]);
    defer analysis.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), analysis.bands.len);
    try testing.expectEqual(@as(u3, 7), analysis.bands[0].low);
    try testing.expectEqual(@as(u3, 1), analysis.bands[0].mid);
    try testing.expectEqual(@as(u3, 0), analysis.bands[0].high);
    try testing.expectEqual(@as(u3, 0), analysis.bands[1].low);
    try testing.expectEqual(@as(u3, 3), analysis.bands[1].mid);
    try testing.expectEqual(@as(u3, 7), analysis.bands[1].high);
}

test "the median tempo ignores a minority section" {
    var beats = [_]Beat{
        .{ .time_ms = 0, .bpm = 151.25, .position = 1 },
        .{ .time_ms = 397, .bpm = 151.38, .position = 2 },
        .{ .time_ms = 794, .bpm = 143.30, .position = 3 },
        .{ .time_ms = 1213, .bpm = 151.39, .position = 4 },
    };
    const analysis = Analysis{ .beats = &beats, .waveform = &.{}, .bands = &.{}, .peak = 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 151.3), analysis.bpm(), 0.2);
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

test "reads the phrase boundaries and kinds" {
    var dat_buffer: [128]u8 = undefined;
    header(&dat_buffer);
    var body: [4 + 8]u8 = undefined;
    @memset(body[0..4], 0);
    std.mem.writeInt(u16, body[4..6], 1, .big);
    std.mem.writeInt(u16, body[6..8], 12800, .big);
    std.mem.writeInt(u32, body[8..12], 1000, .big);
    const dat_end = writeSection(&dat_buffer, 28, "PQTZ", &body);

    var ext_buffer: [256]u8 = undefined;
    header(&ext_buffer);
    const after_wave = writeWaveSection(&ext_buffer, 28, "PWV3", 1, 2, &.{ 100, 50 });

    // Twenty-byte header: entry size 24, two entries, the track's beat count.
    var phrases: [20 + 2 * 24]u8 = undefined;
    @memset(&phrases, 0);
    std.mem.writeInt(u32, phrases[0..4], 24, .big);
    std.mem.writeInt(u16, phrases[4..6], 2, .big);
    std.mem.writeInt(u32, phrases[12..16], 96, .big);
    // First entry: index 1, beat 1, kind 1.
    std.mem.writeInt(u16, phrases[20..22], 1, .big);
    std.mem.writeInt(u16, phrases[22..24], 1, .big);
    std.mem.writeInt(u16, phrases[24..26], 1, .big);
    // Second: index 2, beat 33, kind 5.
    std.mem.writeInt(u16, phrases[44..46], 2, .big);
    std.mem.writeInt(u16, phrases[46..48], 33, .big);
    std.mem.writeInt(u16, phrases[48..50], 5, .big);
    const ext_end = writeSection(&ext_buffer, after_wave, "PSSI", &phrases);

    var analysis = try parse(testing.allocator, dat_buffer[0..dat_end], ext_buffer[0..ext_end]);
    defer analysis.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), analysis.phrases.len);
    try testing.expectEqual(@as(u16, 1), analysis.phrases[0].beat);
    try testing.expectEqual(@as(u8, 1), analysis.phrases[0].kind);
    try testing.expectEqual(@as(u16, 33), analysis.phrases[1].beat);
    try testing.expectEqual(@as(u8, 5), analysis.phrases[1].kind);
}

test "a track without a phrase section carries none" {
    var dat_buffer: [128]u8 = undefined;
    header(&dat_buffer);
    var body: [4 + 8]u8 = undefined;
    @memset(body[0..4], 0);
    std.mem.writeInt(u16, body[4..6], 1, .big);
    std.mem.writeInt(u16, body[6..8], 12800, .big);
    std.mem.writeInt(u32, body[8..12], 1000, .big);
    const dat_end = writeSection(&dat_buffer, 28, "PQTZ", &body);

    var ext_buffer: [128]u8 = undefined;
    header(&ext_buffer);
    const ext_end = writeWaveSection(&ext_buffer, 28, "PWV3", 1, 2, &.{ 100, 50 });

    var analysis = try parse(testing.allocator, dat_buffer[0..dat_end], ext_buffer[0..ext_end]);
    defer analysis.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), analysis.phrases.len);
}

test "the first downbeat follows the grid's bar phase" {
    var beats = [_]Beat{
        .{ .time_ms = 0, .bpm = 120, .position = 1 },
        .{ .time_ms = 500, .bpm = 120, .position = 2 },
        .{ .time_ms = 1000, .bpm = 120, .position = 3 },
        .{ .time_ms = 1500, .bpm = 120, .position = 4 },
    };
    var analysis = Analysis{ .beats = &beats, .waveform = &.{}, .bands = &.{}, .peak = 0 };

    analysis.beats[0].position = 1;
    try std.testing.expectEqual(@as(u32, 0), analysis.firstDownbeat());
    analysis.beats[0].position = 2;
    try std.testing.expectEqual(@as(u32, 3), analysis.firstDownbeat());
    analysis.beats[0].position = 3;
    try std.testing.expectEqual(@as(u32, 2), analysis.firstDownbeat());
    analysis.beats[0].position = 4;
    try std.testing.expectEqual(@as(u32, 1), analysis.firstDownbeat());
}
