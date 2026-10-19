//! How the lane waveform is coloured: rekordbox's three bands as RGB, with
//! brightness following the square root of the level so quiet bars stay
//! readable.

const std = @import("std");
const pl = @import("playlister");

pub const Color = struct { r: u8, g: u8, b: u8, a: u8 = 0xff };

/// One colour per band for the stacked three-band waveform.
pub const low_color = Color{ .r = 0xff, .g = 0x55, .b = 0x55 };
pub const mid_color = Color{ .r = 0x50, .g = 0xfa, .b = 0x7b };
pub const high_color = Color{ .r = 0x8b, .g = 0xe9, .b = 0xfd };

/// Mean band levels over a span, at the waveform's brightness.
pub fn tintBands(level: f32, bands: []const pl.analysis.Band) Color {
    var low: f32 = 0;
    var mid: f32 = 0;
    var high: f32 = 0;
    for (bands) |band| {
        low += @floatFromInt(band.low);
        mid += @floatFromInt(band.mid);
        high += @floatFromInt(band.high);
    }
    const count = @as(f32, @floatFromInt(@max(1, bands.len))) * 7;
    low /= count;
    mid /= count;
    high /= count;

    const strongest = @max(@max(low, mid), high);
    if (strongest < 0.001) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const strength = 0.25 + 0.75 * @sqrt(std.math.clamp(level, 0, 1));
    const gain = 255 * strength / strongest;
    return .{
        .r = @intFromFloat(low * gain),
        .g = @intFromFloat(mid * gain),
        .b = @intFromFloat(high * gain),
        .a = 0xff,
    };
}

/// The green-to-yellow ramp used when a file only has the mono preview.
pub fn heat(level: f32) Color {
    const t = std.math.clamp(level, 0, 1);
    if (t < 0.25) return mix(heat0, heat1, t / 0.25);
    if (t < 0.5) return mix(heat1, heat2, (t - 0.25) / 0.25);
    if (t < 0.75) return mix(heat2, heat3, (t - 0.5) / 0.25);
    return mix(heat3, heat4, (t - 0.75) / 0.25);
}

const heat0 = Color{ .r = 0x1a, .g = 0x1f, .b = 0x4b };
const heat1 = Color{ .r = 0x6a, .g = 0x2c, .b = 0x8f };
const heat2 = Color{ .r = 0xc0, .g = 0x3a, .b = 0x2b };
const heat3 = Color{ .r = 0xf2, .g = 0x8f, .b = 0x24 };
const heat4 = Color{ .r = 0xff, .g = 0xd7, .b = 0x5e };

fn mix(from: Color, to: Color, amount: f32) Color {
    const t = std.math.clamp(amount, 0, 1);
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(from.r)) + (@as(f32, @floatFromInt(to.r)) - @as(f32, @floatFromInt(from.r))) * t),
        .g = @intFromFloat(@as(f32, @floatFromInt(from.g)) + (@as(f32, @floatFromInt(to.g)) - @as(f32, @floatFromInt(from.g))) * t),
        .b = @intFromFloat(@as(f32, @floatFromInt(from.b)) + (@as(f32, @floatFromInt(to.b)) - @as(f32, @floatFromInt(from.b))) * t),
        .a = 0xff,
    };
}

test "the strongest band owns its channel" {
    const testing = std.testing;
    const kick = [_]pl.analysis.Band{.{ .low = 7, .mid = 0, .high = 0 }};
    const red = tintBands(1, &kick);
    try testing.expect(red.r == 255 and red.g == 0 and red.b == 0);

    const mids = [_]pl.analysis.Band{.{ .low = 0, .mid = 7, .high = 0 }};
    const green = tintBands(1, &mids);
    try testing.expect(green.g == 255 and green.r == 0 and green.b == 0);

    const highs = [_]pl.analysis.Band{.{ .low = 0, .mid = 0, .high = 7 }};
    const blue = tintBands(1, &highs);
    try testing.expect(blue.b == 255 and blue.r == 0 and blue.g == 0);
}

test "quiet columns stay visible but dimmer" {
    const testing = std.testing;
    const kick = [_]pl.analysis.Band{.{ .low = 7, .mid = 0, .high = 0 }};
    const soft = tintBands(0.1, &kick).r;
    const loud = tintBands(1, &kick).r;
    try testing.expect(soft < loud);
    try testing.expect(soft > 0);
}
