//! Envelope shaping for the lane waveform, derived from the analysis amplitude
//! bytes: the peak outline and the low body under it.

const std = @import("std");

/// Mean amplitude around one column's sample span, scaled against the track's
/// peak. The window reaches `radius` samples past the span on both sides, so
/// neighbouring peaks and dips average into the body under the outline.
pub fn lowBand(samples: []const u8, from: usize, to: usize, radius: usize, scale: f32) f32 {
    if (samples.len == 0) return 0;
    const start = from -| radius;
    const end = @min(samples.len, @max(to, from) + radius);
    if (end <= start) return 0;

    var sum: usize = 0;
    for (samples[start..end]) |value| sum += value;
    const mean = @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(end - start));
    return @min(1, mean * scale);
}

test "low band averages the samples around a column" {
    const samples = [_]u8{ 0, 100, 100, 100, 100, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 100.0 / 255.0), lowBand(&samples, 2, 4, 1, @as(f32, 1.0) / 255), 1e-6);
}

test "low band clamps its window to the track" {
    const samples = [_]u8{ 200, 200 };
    try std.testing.expectApproxEqAbs(@as(f32, 200.0 / 255.0), lowBand(&samples, 0, 1, 10, @as(f32, 1.0) / 255), 1e-6);
    try std.testing.expectEqual(@as(f32, 0), lowBand(&samples, 5, 6, 1, 1));
}

test "low band clamps the scaled level to one" {
    const samples = [_]u8{ 128, 128 };
    try std.testing.expectApproxEqAbs(@as(f32, 1), lowBand(&samples, 0, 1, 0, 2), 1e-6);
}
