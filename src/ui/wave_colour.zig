//! The waveform's colour scheme and intensity curve live here: tune the two
//! constants and every lane picks the change up.

const std = @import("std");
const pl = @import("playlister");

pub const Color = struct { r: u8, g: u8, b: u8, a: u8 = 0xff };

pub const Scheme = enum { band_rgb, band_rgb_level, pastel, heat };
pub const Curve = enum { linear, sqrt, square, fixed };

/// What the lane waveform uses.
pub const chosen_scheme: Scheme = .band_rgb;
pub const chosen_curve: Curve = .linear;

pub fn applyCurve(curve: Curve, level: f32) f32 {
    const t = std.math.clamp(level, 0, 1);
    return switch (curve) {
        .linear => t,
        .sqrt => @sqrt(t),
        .square => t * t,
        .fixed => 1,
    };
}

pub fn tint(scheme: Scheme, curve: Curve, level: f32, low: f32, mid: f32, high: f32) Color {
    const strength = applyCurve(curve, level);
    return switch (scheme) {
        .band_rgb => normalized(1, low, mid, high),
        .band_rgb_level => normalized(0.25 + 0.75 * strength, low, mid, high),
        .pastel => mixWhite(normalized(0.4 + 0.6 * strength, low, mid, high), 0.45),
        .heat => heat(strength),
    };
}

pub fn tintBands(scheme: Scheme, curve: Curve, level: f32, bands: []const pl.analysis.Band) Color {
    var low: f32 = 0;
    var mid: f32 = 0;
    var high: f32 = 0;
    for (bands) |band| {
        low += @floatFromInt(band.low);
        mid += @floatFromInt(band.mid);
        high += @floatFromInt(band.high);
    }
    const count = @as(f32, @floatFromInt(@max(1, bands.len))) * 7;
    return tint(scheme, curve, level, low / count, mid / count, high / count);
}

fn normalized(scale: f32, low: f32, mid: f32, high: f32) Color {
    const strongest = @max(@max(low, mid), high);
    if (strongest < 0.001) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const gain = 255 * scale / strongest;
    return .{
        .r = @intFromFloat(low * gain),
        .g = @intFromFloat(mid * gain),
        .b = @intFromFloat(high * gain),
        .a = 0xff,
    };
}

fn mixWhite(color: Color, amount: f32) Color {
    const blend = std.math.clamp(amount, 0, 1);
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(color.r)) + (255 - @as(f32, @floatFromInt(color.r))) * blend),
        .g = @intFromFloat(@as(f32, @floatFromInt(color.g)) + (255 - @as(f32, @floatFromInt(color.g))) * blend),
        .b = @intFromFloat(@as(f32, @floatFromInt(color.b)) + (255 - @as(f32, @floatFromInt(color.b))) * blend),
        .a = 0xff,
    };
}

pub fn heat(level: f32) Color {
    const t = std.math.clamp(level, 0, 1);
    if (t < 0.25) return mix(heat0, heat1, t / 0.25);
    if (t < 0.5) return mix(heat1, heat2, (t - 0.25) / 0.25);
    if (t < 0.75) return mix(heat2, heat3, (t - 0.5) / 0.25);
    return mix(heat3, heat4, (t - 0.75) / 0.25);
}

const heat0 = Color{ .r = 0x1a, .g = 0x1f, .b = 0x4b, .a = 0xff };
const heat1 = Color{ .r = 0x6a, .g = 0x2c, .b = 0x8f, .a = 0xff };
const heat2 = Color{ .r = 0xc0, .g = 0x3a, .b = 0x2b, .a = 0xff };
const heat3 = Color{ .r = 0xf2, .g = 0x8f, .b = 0x24, .a = 0xff };
const heat4 = Color{ .r = 0xff, .g = 0xd7, .b = 0x5e, .a = 0xff };

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
    const kick = tint(.band_rgb, .linear, 1, 1, 0, 0);
    try testing.expect(kick.r == 255 and kick.g == 0 and kick.b == 0);

    const mid = tint(.band_rgb, .linear, 1, 0, 1, 0);
    try testing.expect(mid.g == 255 and mid.r == 0 and mid.b == 0);

    const all = tint(.band_rgb, .linear, 1, 1, 1, 1);
    try testing.expect(all.r == 255 and all.g == 255 and all.b == 255);
}

test "curves are monotonic and fixed ignores the level" {
    const testing = std.testing;
    try testing.expect(applyCurve(.linear, 0.25) == 0.25);
    try testing.expectApproxEqAbs(@as(f32, 0.5), applyCurve(.sqrt, 0.25), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0625), applyCurve(.square, 0.25), 0.001);
    try testing.expect(applyCurve(.fixed, 0) == 1);

    const dim = tint(.band_rgb_level, .linear, 0.1, 1, 0, 0).r;
    const bright = tint(.band_rgb_level, .linear, 0.9, 1, 0, 0).r;
    try testing.expect(dim < bright);
}
