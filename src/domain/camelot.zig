//! Camelot wheel positions and the harmonic relation between two keys.
//!
//! rekordbox stores a key as a note name with an optional `m` suffix: `Dm`,
//! `Abm`, `F#`. That parses to a pitch class plus a mode, then to a wheel
//! number 1..12 on side A (minor) or B (major).

const std = @import("std");

pub const Mode = enum { minor, major };

pub const Key = struct {
    number: u8, // 1..12
    mode: Mode,

    pub fn side(self: Key) u8 {
        return if (self.mode == Mode.minor) 'A' else 'B';
    }

    /// The note name rekordbox prints for this position, in the spelling DJs
    /// use for the wheel: minors on side A, majors on side B.
    pub fn note(self: Key) []const u8 {
        return wheel[self.number - 1][if (self.mode == .minor) 0 else 1];
    }

    pub fn format(self: Key, writer: *std.Io.Writer) !void {
        try writer.print("{d}{c}", .{ self.number, self.side() });
    }

    /// True when both keys share a number, i.e. the relative major/minor pair.
    pub fn isRelative(self: Key, other: Key) bool {
        return self.number == other.number and self.mode != other.mode;
    }
};

/// Row per wheel number: minor name, major name.
const wheel = [12][2][]const u8{
    .{ "Abm", "B" },
    .{ "Ebm", "F#" },
    .{ "Bbm", "Db" },
    .{ "Fm", "Ab" },
    .{ "Cm", "Eb" },
    .{ "Gm", "Bb" },
    .{ "Dm", "F" },
    .{ "Am", "C" },
    .{ "Em", "G" },
    .{ "Bm", "D" },
    .{ "F#m", "A" },
    .{ "C#m", "E" },
};

pub const ParseError = error{Empty, BadNote, BadSuffix, BadLength};

/// Parse a key name as rekordbox writes it. Case-insensitive on the mode
/// suffix; the note letter is normalised to upper case.
pub fn parse(text: []const u8) ParseError!Key {
    const trimmed = std.mem.trim(u8, text, " ");
    if (trimmed.len == 0) return error.Empty;
    if (trimmed.len > 3) return error.BadLength;

    const letter = std.ascii.toUpper(trimmed[0]);
    const base: i8 = switch (letter) {
        'C' => 0,
        'D' => 2,
        'E' => 4,
        'F' => 5,
        'G' => 7,
        'A' => 9,
        'B' => 11,
        else => return error.BadNote,
    };

    var idx: usize = 1;
    var pitch: i8 = base;
    if (idx < trimmed.len) {
        switch (trimmed[idx]) {
            '#' => {
                pitch += 1;
                idx += 1;
            },
            'b' => {
                pitch -= 1;
                idx += 1;
            },
            else => {},
        }
    }

    var mode: Mode = .major;
    if (idx < trimmed.len) {
        switch (std.ascii.toLower(trimmed[idx])) {
            'm' => {
                mode = .minor;
                idx += 1;
            },
            else => return error.BadSuffix,
        }
    }
    if (idx != trimmed.len) return error.BadSuffix;

    const pc: u8 = @intCast(@mod(pitch, 12));
    // The wheel steps by a perfect fifth per number, so the inverse multiplier
    // is 7 (7 * 7 ≡ 1 mod 12) around the mode's origin.
    const origin: u8 = if (mode == .minor) 8 else 11;
    const offset = (@as(u16, pc) + 12 - origin) % 12;
    const number = (offset * 7) % 12 + 1;

    return .{ .number = @intCast(number), .mode = mode };
}

pub const Direction = enum { up, held, down };

pub const Strength = enum { none, slight, strong, big };

pub const Relation = struct {
    direction: Direction = .held,
    strength: Strength = .none,
    /// False for the shifts that clash: 3, 4 and 6 steps away.
    harmonic: bool = false,

    pub fn label(self: Relation) []const u8 {
        if (!self.harmonic) return "clash";
        return switch (self.direction) {
            .held => "holds",
            .up => switch (self.strength) {
                .slight => "lifts",
                .strong => "pumps",
                .big => "jumps",
                .none => "holds",
            },
            .down => switch (self.strength) {
                .slight => "eases",
                .strong => "drops",
                .big => "drops hard",
                .none => "holds",
            },
        };
    }
};

/// Signed distance around the wheel, in (-6, 6]. Positive means the playlist
/// moves forward (towards higher wheel numbers).
pub fn distance(from: Key, to: Key) i8 {
    var d: i8 = @as(i8, @intCast(to.number)) - @as(i8, @intCast(from.number));
    if (d > 6) d -= 12;
    if (d <= -6) d += 12;
    return d;
}

pub fn relation(from: Key, to: Key) Relation {
    if (from.number == to.number) {
        if (from.mode == to.mode) return .{ .harmonic = true };
        return .{ .harmonic = true }; // relative pair: mood shift, energy held
    }
    const d = distance(from, to);
    const step: u8 = @intCast(@abs(d));
    const up = d > 0;
    return switch (step) {
        1 => .{ .direction = if (up) .up else .down, .strength = .slight, .harmonic = true },
        2 => .{ .direction = if (up) .up else .down, .strength = .strong, .harmonic = true },
        5 => .{ .direction = if (up) .up else .down, .strength = .big, .harmonic = true },
        else => .{ .harmonic = false },
    };
}

test "parse minor keys" {
    const cases = [_]struct { text: []const u8, number: u8, mode: Mode }{
        .{ .text = "Am", .number = 8, .mode = .minor },
        .{ .text = "Dm", .number = 7, .mode = .minor },
        .{ .text = "Cm", .number = 5, .mode = .minor },
        .{ .text = "Abm", .number = 1, .mode = .minor },
        .{ .text = "Ebm", .number = 2, .mode = .minor },
        .{ .text = "Bbm", .number = 3, .mode = .minor },
        .{ .text = "Gm", .number = 6, .mode = .minor },
        .{ .text = "F#m", .number = 11, .mode = .minor },
        .{ .text = "C#m", .number = 12, .mode = .minor },
        .{ .text = "G#m", .number = 1, .mode = .minor },
        .{ .text = "Dbm", .number = 12, .mode = .minor },
    };
    for (cases) |c| {
        const got = try parse(c.text);
        try std.testing.expectEqual(c.number, got.number);
        try std.testing.expectEqual(c.mode, got.mode);
    }
}

test "parse major keys" {
    const cases = [_]struct { text: []const u8, number: u8 }{
        .{ .text = "B", .number = 1 },
        .{ .text = "F#", .number = 2 },
        .{ .text = "Db", .number = 3 },
        .{ .text = "Ab", .number = 4 },
        .{ .text = "Eb", .number = 5 },
        .{ .text = "Bb", .number = 6 },
        .{ .text = "F", .number = 7 },
        .{ .text = "C", .number = 8 },
        .{ .text = "G", .number = 9 },
        .{ .text = "D", .number = 10 },
        .{ .text = "A", .number = 11 },
        .{ .text = "E", .number = 12 },
    };
    for (cases) |c| {
        const got = try parse(c.text);
        try std.testing.expectEqual(c.number, got.number);
        try std.testing.expectEqual(Mode.major, got.mode);
    }
}

test "relative pair shares a number" {
    const abm = try parse("Abm");
    const b = try parse("B");
    try std.testing.expect(abm.isRelative(b));
}

test "relation table" {
    const am = try parse("Am"); // 8A
    const dm = try parse("Dm"); // 7A
    const em = try parse("Em"); // 9A
    const bm = try parse("Bm"); // 10A
    const gm = try parse("Gm"); // 6A
    const c = try parse("C"); // 8B
    const ebm = try parse("Ebm"); // 2A -> 6 steps from 8A

    try std.testing.expectEqual(Direction.held, relation(am, am).direction);
    try std.testing.expectEqual(Direction.held, relation(am, c).direction);
    try std.testing.expect(relation(am, c).harmonic);

    const lift = relation(am, em);
    try std.testing.expectEqual(Direction.up, lift.direction);
    try std.testing.expectEqual(Strength.slight, lift.strength);

    const pump = relation(am, bm);
    try std.testing.expectEqual(Strength.strong, pump.strength);

    const ease = relation(am, dm);
    try std.testing.expectEqual(Direction.down, ease.direction);
    try std.testing.expectEqual(Strength.slight, ease.strength);

    const drop = relation(am, gm);
    try std.testing.expectEqual(Strength.strong, drop.strength);

    try std.testing.expect(!relation(am, ebm).harmonic);
}

test "distance wraps" {
    const a = try parse("Am"); // 8A
    const b = try parse("Cm"); // 5A
    try std.testing.expectEqual(@as(i8, -3), distance(a, b));
    try std.testing.expectEqual(@as(i8, 3), distance(b, a));
}

test "note names round-trip through the wheel" {
    var number: u8 = 1;
    while (number <= 12) : (number += 1) {
        for ([_]Mode{ .minor, .major }) |mode| {
            const key = Key{ .number = number, .mode = mode };
            const parsed = try parse(key.note());
            try std.testing.expectEqual(key.number, parsed.number);
            try std.testing.expectEqual(key.mode, parsed.mode);
        }
    }
}
