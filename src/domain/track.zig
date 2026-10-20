//! A track as the playlist builder sees it, independent of where it came from.

const std = @import("std");
const camelot = @import("camelot.zig");

pub const Track = struct {
    /// Stable within a library source only; rekordbox uses its content ID.
    id: u64,
    title: []const u8,
    artist: []const u8,
    /// Centi-BPM, as rekordbox stores it.
    bpm_centi: u32 = 0,
    /// Null for a track rekordbox never analysed.
    key: ?camelot.Key = null,
    length_s: u32 = 0,
    bpm: f64 = 0,
    /// Absolute path to the audio file, as rekordbox records it.
    file_path: []const u8 = "",
    genre: []const u8 = "",
    /// My Tags, space separated, as rekordbox joins them.
    tags: []const u8 = "",
    /// Where the source keeps this track's analysed grid, relative to its own
    /// root. Empty when the track was never analysed.
    analysis_path: []const u8 = "",

    pub fn init(id: u64, title: []const u8, artist: []const u8) Track {
        return .{ .id = id, .title = title, .artist = artist };
    }

    pub fn deriveBpm(self: *Track) void {
        self.bpm = @as(f64, @floatFromInt(self.bpm_centi)) / 100.0;
    }

    /// Case-insensitive match on everything a person would type into the
    /// search bar: title, artist, genre and tags.
    pub fn matches(self: Track, needle: []const u8) bool {
        return self.searchScore(needle) != null;
    }

    /// Where `needle` matched, lower first. An exact title beats a title
    /// prefix, which beats a word inside the title, then artist, genre, tags.
    pub fn searchScore(self: Track, needle: []const u8) ?u32 {
        if (needle.len == 0) return 0;
        if (std.ascii.eqlIgnoreCase(self.title, needle)) return 0;
        if (startsWordIgnoreCase(self.title, needle)) return 1;
        if (containsWordIgnoreCase(self.title, needle)) return 2;
        if (containsIgnoreCase(self.title, needle)) return 3;
        if (std.ascii.eqlIgnoreCase(self.artist, needle)) return 4;
        if (startsWordIgnoreCase(self.artist, needle)) return 5;
        if (containsWordIgnoreCase(self.artist, needle)) return 6;
        if (containsIgnoreCase(self.artist, needle)) return 7;
        if (containsWordIgnoreCase(self.genre, needle)) return 8;
        if (containsIgnoreCase(self.genre, needle)) return 9;
        if (containsWordIgnoreCase(self.tags, needle)) return 10;
        if (containsIgnoreCase(self.tags, needle)) return 11;
        return null;
    }

    pub fn searchLessThan(needle: []const u8, a: Track, b: Track) bool {
        const a_score = a.searchScore(needle) orelse std.math.maxInt(u32);
        const b_score = b.searchScore(needle) orelse std.math.maxInt(u32);
        return a_score < b_score;
    }
};

fn startsWordIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    if (!std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle)) return false;
    return needle.len == haystack.len or !std.ascii.isAlphanumeric(haystack[needle.len]);
}

fn containsWordIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) continue;
        const before_ok = i == 0 or !std.ascii.isAlphanumeric(haystack[i - 1]);
        const after_ok = i + needle.len == haystack.len or !std.ascii.isAlphanumeric(haystack[i + needle.len]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "matches on genre and tags" {
    var t = Track.init(1, "Untitled", "Nobody");
    t.genre = "Techno";
    t.tags = "peak time rolling";
    try std.testing.expect(t.matches("techno"));
    try std.testing.expect(t.matches("rolling"));
    try std.testing.expect(!t.matches("house"));
}

test "matches on title or artist" {
    const t = Track.init(1, "Plastic Beach", "Pepe Mogt");
    try std.testing.expect(t.matches("plastic"));
    try std.testing.expect(t.matches("MOGT"));
    try std.testing.expect(t.matches(""));
    try std.testing.expect(!t.matches("beach plastic"));
}

test "an exact title outranks a genre match" {
    var genre = Track.init(1, "Folk Collection", "Various");
    genre.genre = "Folk & Roots";
    const exact = Track.init(2, "Roots", "Shkoon");

    const genre_score = genre.searchScore("Roots").?;
    const exact_score = exact.searchScore("Roots").?;
    try std.testing.expect(exact_score < genre_score);
}

test "a title word outranks the artist" {
    const title = Track.init(1, "Roots", "Nobody");
    const artist = Track.init(2, "Untitled", "Roots");
    try std.testing.expect(title.searchScore("Roots").? < artist.searchScore("Roots").?);
}

test "bpm derived from centi" {
    var t = Track.init(1, "x", "y");
    t.bpm_centi = 12700;
    t.deriveBpm();
    try std.testing.expectApproxEqAbs(@as(f64, 127.0), t.bpm, 1e-9);
}
