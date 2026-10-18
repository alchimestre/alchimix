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

    pub fn init(id: u64, title: []const u8, artist: []const u8) Track {
        return .{ .id = id, .title = title, .artist = artist };
    }

    pub fn deriveBpm(self: *Track) void {
        self.bpm = @as(f64, @floatFromInt(self.bpm_centi)) / 100.0;
    }

    /// Case-insensitive match on everything a person would type into the
    /// search bar: title, artist, genre and tags.
    pub fn matches(self: Track, needle: []const u8) bool {
        if (needle.len == 0) return true;
        return containsIgnoreCase(self.title, needle) or
            containsIgnoreCase(self.artist, needle) or
            containsIgnoreCase(self.genre, needle) or
            containsIgnoreCase(self.tags, needle);
    }
};

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

test "bpm derived from centi" {
    var t = Track.init(1, "x", "y");
    t.bpm_centi = 12700;
    t.deriveBpm();
    try std.testing.expectApproxEqAbs(@as(f64, 127.0), t.bpm, 1e-9);
}
