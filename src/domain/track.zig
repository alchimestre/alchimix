//! A track as the playlist builder sees it, independent of where it came from.

const std = @import("std");
const camelot = @import("camelot.zig");
const fold = @import("fold.zig");

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

    /// Case- and accent-insensitive match on everything a person would type
    /// into the search bar: title, artist, genre and tags.
    pub fn matches(self: Track, needle: []const u8) bool {
        return self.searchScore(needle) != null;
    }

    /// Where `needle` matched, lower first. An exact title beats a title
    /// prefix, which beats a word inside the title, then artist, genre, tags.
    pub fn searchScore(self: Track, needle: []const u8) ?u32 {
        if (needle.len == 0) return 0;
        if (fold.equal(self.title, needle)) return 0;
        if (fold.startsWord(self.title, needle)) return 1;
        if (fold.containsWord(self.title, needle)) return 2;
        if (fold.contains(self.title, needle)) return 3;
        if (fold.equal(self.artist, needle)) return 4;
        if (fold.startsWord(self.artist, needle)) return 5;
        if (fold.containsWord(self.artist, needle)) return 6;
        if (fold.contains(self.artist, needle)) return 7;
        if (fold.containsWord(self.genre, needle)) return 8;
        if (fold.contains(self.genre, needle)) return 9;
        if (fold.containsWord(self.tags, needle)) return 10;
        if (fold.contains(self.tags, needle)) return 11;
        return null;
    }

    pub fn searchLessThan(needle: []const u8, a: Track, b: Track) bool {
        const a_score = a.searchScore(needle) orelse std.math.maxInt(u32);
        const b_score = b.searchScore(needle) orelse std.math.maxInt(u32);
        return a_score < b_score;
    }
};

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

test "an accent reads as its base letter" {
    const t = Track.init(1, "Café", "Nobody");
    try std.testing.expectEqual(@as(?u32, 0), t.searchScore("cafe"));
    try std.testing.expectEqual(@as(?u32, 0), t.searchScore("CAFÉ"));
}

test "an accented needle finds a plain title" {
    const t = Track.init(1, "Cafe", "Nobody");
    try std.testing.expectEqual(@as(?u32, 0), t.searchScore("café"));
}

test "a combining accent matches its precomposed form" {
    const t = Track.init(1, "Cafe\u{301} Noir", "Nobody");
    try std.testing.expectEqual(@as(?u32, 0), t.searchScore("café noir"));
    try std.testing.expectEqual(@as(?u32, 1), t.searchScore("cafe"));
}

test "an accented word matches mid-title" {
    const t = Track.init(1, "Nuit Café Noir", "Nobody");
    try std.testing.expectEqual(@as(?u32, 2), t.searchScore("cafe"));
    try std.testing.expectEqual(@as(?u32, 2), t.searchScore("noir"));
}

test "an umlaut or a stroke reads as its base letter" {
    try std.testing.expect(Track.init(1, "Björk", "Nobody").matches("bjork"));
    try std.testing.expect(Track.init(1, "Bj\u{f8}rn", "Nobody").matches("bjorn"));
}

test "punctuation around a title still bounds a word" {
    const t = Track.init(1, "«Café»", "Nobody");
    try std.testing.expectEqual(@as(?u32, 2), t.searchScore("cafe"));
}

test "a folded title still outranks an accented artist" {
    const title = Track.init(1, "Café", "Nobody");
    const artist = Track.init(2, "Untitled", "Café");
    try std.testing.expect(title.searchScore("cafe").? < artist.searchScore("cafe").?);
}

test "an accented genre is found from the plain spelling" {
    var t = Track.init(1, "Untitled", "Nobody");
    t.genre = "Électronique";
    try std.testing.expectEqual(@as(?u32, 8), t.searchScore("electronique"));
}

test "bpm derived from centi" {
    var t = Track.init(1, "x", "y");
    t.bpm_centi = 12700;
    t.deriveBpm();
    try std.testing.expectApproxEqAbs(@as(f64, 127.0), t.bpm, 1e-9);
}
