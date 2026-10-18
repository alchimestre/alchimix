//! Tempo comparison. rekordbox stores BPM as centi-BPM (12700 is 127.00).

const std = @import("std");

/// Which octave relation explains the jump between two tempos.
pub const Stretch = enum { none, half, double };

pub const Match = struct {
    /// Signed difference in BPM after the octave relation is applied.
    delta_bpm: f64,
    ratio: f64,
    stretch: Stretch = .none,
};

pub fn toBpm(centi: u32) f64 {
    return @as(f64, @floatFromInt(centi)) / 100.0;
}

/// Compare `b` against `a`, choosing the octave relation that brings them
/// closest. A 64 BPM track is a 128 BPM track played at double time, and the
/// block should say so rather than call the pair incompatible.
pub fn match(a_centi: u32, b_centi: u32) Match {
    const a = toBpm(a_centi);
    const b = toBpm(b_centi);
    if (a <= 0 or b <= 0) return .{ .delta_bpm = 0, .ratio = 1 };

    var best = Match{ .delta_bpm = b - a, .ratio = b / a, .stretch = .none };
    var best_err = @abs(b / a - 1);

    const halves = [_]struct { f: f64, s: Stretch }{
        .{ .f = 0.5, .s = .half },
        .{ .f = 2.0, .s = .double },
    };
    for (halves) |h| {
        const scaled = b * h.f;
        const err = @abs(scaled / a - 1);
        if (err < best_err) {
            best_err = err;
            best = .{ .delta_bpm = scaled - a, .ratio = scaled / a, .stretch = h.s };
        }
    }
    return best;
}

pub const Direction = enum { up, held, down };

/// A window of `tolerance_bpm` is the caller's call: house mixes tolerate
/// about 6, a techno set less.
pub fn within(a_centi: u32, b_centi: u32, tolerance_bpm: f64) bool {
    return @abs(match(a_centi, b_centi).delta_bpm) <= tolerance_bpm;
}

/// `held_bpm` is the dead band below which the step is not worth drawing an
/// arrow for.
pub fn direction(a_centi: u32, b_centi: u32, held_bpm: f64) Direction {
    const d = match(a_centi, b_centi).delta_bpm;
    if (d > held_bpm) return .up;
    if (d < -held_bpm) return .down;
    return .held;
}

test "centi to bpm" {
    try std.testing.expectApproxEqAbs(@as(f64, 127.0), toBpm(12700), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 138.0), toBpm(13800), 1e-9);
}

test "same tempo" {
    const m = match(12800, 12800);
    try std.testing.expectApproxEqAbs(@as(f64, 0), m.delta_bpm, 1e-9);
    try std.testing.expectEqual(Stretch.none, m.stretch);
}

test "octave relation is recognised" {
    const m = match(12800, 6400);
    try std.testing.expectEqual(Stretch.double, m.stretch);
    try std.testing.expectApproxEqAbs(@as(f64, 0), m.delta_bpm, 1e-9);
}

test "small drift stays in the window" {
    try std.testing.expect(within(12800, 13000, 6));
    try std.testing.expect(!within(12800, 13600, 6));
}

test "direction" {
    try std.testing.expectEqual(Direction.up, direction(12400, 12800, 0.5));
    try std.testing.expectEqual(Direction.down, direction(12800, 12400, 0.5));
    try std.testing.expectEqual(Direction.held, direction(12800, 12820, 0.5));
}
