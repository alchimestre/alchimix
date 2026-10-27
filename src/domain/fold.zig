//! Text compared the way a person reads it: case and accents ignored.

const std = @import("std");

/// Whether `haystack` reads as `needle` once both are folded.
pub fn equal(haystack: []const u8, needle: []const u8) bool {
    var haystack_fold = Fold{ .text = haystack };
    var needle_fold = Fold{ .text = needle };
    while (true) {
        const left = haystack_fold.next();
        const right = needle_fold.next();
        if (left != right) return false;
        if (left == null) return true;
    }
}

/// Whether `needle` appears anywhere in `haystack` once both are folded.
pub fn contains(haystack: []const u8, needle: []const u8) bool {
    var index: usize = 0;
    while (index < haystack.len) : (index += codepointAt(haystack, index).length) {
        if (matchAt(haystack, index, needle) != null) return true;
    }
    return false;
}

/// Whether `needle` opens `text` and ends where a word ends.
pub fn startsWord(text: []const u8, needle: []const u8) bool {
    const length = matchAt(text, 0, needle) orelse return false;
    return !isWordAt(text, length);
}

/// Whether `needle` sits between two word boundaries, anywhere in `text`.
pub fn containsWord(text: []const u8, needle: []const u8) bool {
    var index: usize = 0;
    var inside_word = false;
    while (index < text.len) {
        const decoded = codepointAt(text, index);
        if (!inside_word) {
            if (matchAt(text, index, needle)) |length| {
                if (!isWordAt(text, index + length)) return true;
            }
        }
        if (fold(decoded.cp)) |folded| inside_word = isWord(folded);
        index += decoded.length;
    }
    return false;
}

/// Byte length of `haystack[from..]` that folds equal to `needle`, or null
/// when the codepoints differ.
fn matchAt(haystack: []const u8, from: usize, needle: []const u8) ?usize {
    var haystack_fold = Fold{ .text = haystack, .index = from };
    var needle_fold = Fold{ .text = needle };
    while (true) {
        const expected = needle_fold.next();
        if (expected == null) return haystack_fold.index - from;
        const actual = haystack_fold.next();
        if (actual == null or actual.? != expected.?) return null;
    }
}

/// Whether a letter or digit starts at `index`, looking past the combining
/// marks that belong to the letter before them. Letters of scripts the fold
/// table does not cover read as separators, as they did before folding.
fn isWordAt(text: []const u8, index: usize) bool {
    var at = index;
    while (at < text.len) {
        const decoded = codepointAt(text, at);
        if (fold(decoded.cp)) |folded| return isWord(folded);
        at += decoded.length;
    }
    return false;
}

/// The comparable form of a codepoint: lowercase, accent taken off. Null for a
/// combining mark, which adds no letter of its own.
///
/// Latin-1, Latin Extended-A and the Vietnamese vowels are covered. Ligatures
/// (æ, œ, ß) and letters of other scripts keep their own spelling.
fn fold(cp: u21) ?u21 {
    return switch (cp) {
        'A'...'Z' => cp + ('a' - 'A'),

        // Combining diacritical marks: the letter before them already matched.
        0x0300...0x036F,
        0x1AB0...0x1AFF,
        0x1DC0...0x1DFF,
        0x20D0...0x20FF,
        0xFE20...0xFE2F,
        => null,

        // Latin-1 Supplement.
        0x00C0...0x00C5, 0x00E0...0x00E5 => 'a',
        0x00C7, 0x00E7 => 'c',
        0x00C8...0x00CB, 0x00E8...0x00EB => 'e',
        0x00CC...0x00CF, 0x00EC...0x00EF => 'i',
        0x00D0, 0x00F0 => 'd',
        0x00D1, 0x00F1 => 'n',
        0x00D2...0x00D6, 0x00D8, 0x00F2...0x00F6, 0x00F8 => 'o',
        0x00D9...0x00DC, 0x00F9...0x00FC => 'u',
        0x00DD, 0x00FD, 0x00FF => 'y',

        // Latin Extended-A.
        0x0100...0x0105 => 'a',
        0x0106...0x010D => 'c',
        0x010E...0x0111 => 'd',
        0x0112...0x011B => 'e',
        0x011C...0x0123 => 'g',
        0x0124...0x0127 => 'h',
        0x0128...0x0131 => 'i',
        0x0134, 0x0135 => 'j',
        0x0136...0x0138 => 'k',
        0x0139...0x0142 => 'l',
        0x0143...0x014B => 'n',
        0x014C...0x0151 => 'o',
        0x0154...0x0159 => 'r',
        0x015A...0x0161 => 's',
        0x0162...0x0167 => 't',
        0x0168...0x0173 => 'u',
        0x0174, 0x0175 => 'w',
        0x0176...0x0178 => 'y',
        0x0179...0x017E => 'z',
        0x017F => 's',

        // Latin Extended-B: Vietnamese hooks, Romanian commas.
        0x01A0, 0x01A1 => 'o',
        0x01AF, 0x01B0 => 'u',
        0x0218, 0x0219 => 's',
        0x021A, 0x021B => 't',

        // Latin Extended Additional: Vietnamese vowels.
        0x1EA0...0x1EB7 => 'a',
        0x1EB8...0x1EC7 => 'e',
        0x1EC8...0x1ECB => 'i',
        0x1ECC...0x1EE3 => 'o',
        0x1EE4...0x1EF1 => 'u',
        0x1EF2...0x1EF9 => 'y',

        else => cp,
    };
}

fn isWord(folded: u21) bool {
    return folded < 0x80 and std.ascii.isAlphanumeric(@intCast(folded));
}

/// Walks text one comparable codepoint at a time: lowercase, accent free,
/// combining marks dropped.
const Fold = struct {
    text: []const u8,
    index: usize = 0,

    fn next(self: *Fold) ?u21 {
        while (self.index < self.text.len) {
            const decoded = codepointAt(self.text, self.index);
            self.index += decoded.length;
            if (fold(decoded.cp)) |folded| return folded;
        }
        return null;
    }
};

const Decoded = struct {
    cp: u21,
    length: usize,
};

/// One codepoint of `text` at `index`. A malformed sequence reads as its first
/// byte, so it compares as the raw byte it is rather than as a letter.
fn codepointAt(text: []const u8, index: usize) Decoded {
    const first = text[index];
    const length = std.unicode.utf8ByteSequenceLength(first) catch return .{ .cp = first, .length = 1 };
    if (index + length > text.len) return .{ .cp = first, .length = 1 };
    const cp = std.unicode.utf8Decode(text[index .. index + length]) catch return .{ .cp = first, .length = 1 };
    return .{ .cp = cp, .length = length };
}

test "an accent folds to its base letter" {
    try std.testing.expectEqual(@as(?u21, 'e'), fold('é'));
    try std.testing.expectEqual(@as(?u21, 'i'), fold('ì'));
    try std.testing.expectEqual(@as(?u21, 'a'), fold('Ấ'));
    try std.testing.expectEqual(@as(?u21, 'o'), fold('Ø'));
    try std.testing.expectEqual(@as(?u21, 'c'), fold('Ç'));
    try std.testing.expectEqual(@as(?u21, 'a'), fold('A'));
}

test "a combining mark folds away" {
    try std.testing.expectEqual(@as(?u21, null), fold(0x0301));
    try std.testing.expect(equal("Cafe\u{301}", "café"));
    try std.testing.expect(equal("café", "Cafe\u{301}"));
}

test "letters outside the table keep their own spelling" {
    try std.testing.expectEqual(@as(?u21, 'Ж'), fold('Ж'));
    try std.testing.expect(!equal("Ж", "ж"));
    try std.testing.expectEqual(@as(?u21, ','), fold(','));
}

test "strings compare whole and folded" {
    try std.testing.expect(equal("Café", "cafe"));
    try std.testing.expect(!equal("Café Noir", "cafe"));
    try std.testing.expect(contains("Nuit Café Noir", "cafe"));
    try std.testing.expect(!contains("Cafe", "café noir"));
}

test "a word is bounded by non-letters" {
    try std.testing.expect(startsWord("Café Noir", "cafe"));
    try std.testing.expect(!startsWord("Caféine", "cafe"));
    try std.testing.expect(containsWord("Nuit Café Noir", "cafe"));
    try std.testing.expect(!containsWord("Caféine", "caf"));
    try std.testing.expect(!containsWord("Nuit Café Noir", "uit"));
}

test "a word starts at a letter, not a mark or punctuation" {
    try std.testing.expect(isWordAt("café", 0));
    try std.testing.expect(isWordAt("café", 3));
    try std.testing.expect(!isWordAt("«café»", 0));
    try std.testing.expect(isWordAt("cafe\u{301}x", 4));
    try std.testing.expect(!isWordAt("cafe", 4));
}
