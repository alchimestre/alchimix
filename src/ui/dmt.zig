//! The DMT mode: the frame is mirrored up and down, left and right, then
//! folded into a turning funnel.
//!
//! `fold` is the whole visual model: it maps a screen point to the texel shown
//! there. That is also the pointer map, so whatever sits under the cursor is
//! what a press lands on. The mode chips are masked to identity and painted
//! back last.
//!
//! Every pass mirrors both axes, shifts a little and samples further out, so
//! the UI repeats as nested, mirrored copies. The funnel pull grows toward the
//! middle, which bends those copies into a funnel. Colour is the frame's own;
//! the effect only moves pixels.

const std = @import("std");
const dvui = @import("dvui");
const geom = @import("geom.zig");

/// Rings between the centre and the rim.
/// Rings per e-fold of radius: the default granularity of the tunnel.
pub const rings_default: f32 = 2.2;

/// Range the lane slider covers. Low values give few wide lanes, high values
/// many thin ones.
pub const min_rings: f32 = 0.9;
pub const max_rings: f32 = 7;
/// Ring phase advanced per effect second. Positive means the rings travel
/// outward, from the fulcrum to the edges.
const rush: f32 = 0.9;
/// How far each ring is turned against the next.
const twist: f32 = 0.55;
/// Effect speed against the tempo clock. The shared slider scales this.
const speed: f32 = 1.6;
/// The pinned look: the window border never samples outside the frame.
pub const border_px: f32 = 26;
/// Pixels between a still rect and the full fold around it.
const calm: f32 = 18;
/// Vertex every this many physical pixels. Mirror seams are sharp, so the grid
/// has to be fine.
const cell: f32 = 9;
/// One index buffer addresses u16 vertexes, so a window larger than this many
/// cells gets a coarser stride instead of an overflowing index.
const vertex_budget: f32 = 60_000;

/// Motion for the effect: seeded speed wander and a turn that flips
/// direction on a schedule, so the loop never settles.
pub const Mood = struct {
    /// Speed against the slider's setting.
    rate: f32 = 1,
    /// Radians per effect second; the sign is the turn direction.
    spin: f32 = 0.5,
};

/// The effect's own clock. Mood scales the step, never the elapsed time: a
/// multiplier on elapsed time shifts the phase every time the mood moves, and
/// once the effect has run for a minute that shift dwarfs the speed slider.
pub const Clock = struct {
    rush: f64 = 0,
    turn: f64 = 0,

    pub fn advance(self: *Clock, seconds: f64, mood_at: Mood) void {
        self.rush += seconds * @as(f64, mood_at.rate);
        self.turn += seconds * @as(f64, mood_at.spin);
    }
};

/// Seed is time alone: the effect changes without needing a track.
pub fn mood(time: f64) Mood {
    const t: f32 = @floatCast(time);
    const phase = 0.7;

    // 0.8 to 1.3, so the wander never cancels the slider's setting.
    const rate = 1.05 + 0.2 * @sin(t * 0.37 + phase) + 0.05 * @sin(t * 0.11 + phase * 1.9);
    const epoch: i64 = @intFromFloat(@floor(time / 6.5));
    const flip: f32 = if (seeded(epoch) & 1 == 0) 1 else -1;

    return .{
        .rate = rate,
        .spin = flip * (0.35 + 0.2 * @sin(t * 0.23 + phase)),
    };
}

/// Splitmix64 over the flip epoch.
fn seeded(epoch: i64) u64 {
    var z = @as(u64, @bitCast(epoch)) +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// The texel shown at `p`. Identity only inside `stills`: everything else is
/// part of the transformation.
pub fn fold(
    p: dvui.Point.Physical,
    clock: Clock,
    size: dvui.Size.Physical,
    stills: []const dvui.Rect.Physical,
    border: f32,
    rings: f32,
) dvui.Point.Physical {
    if (size.w <= 0 or size.h <= 0) return p;
    const strength = clean(p.x, p.y, size, stills, border);
    if (strength <= 0) return p;

    const rush_phase: f32 = @floatCast(clock.rush * speed);
    const turn_phase: f32 = @floatCast(clock.turn * speed);
    const half = @min(size.w, size.h) / 2;
    const centre = dvui.Point.Physical{ .x = size.w / 2, .y = size.h / 2 };
    const q = dvui.Point.Physical{ .x = p.x - centre.x, .y = p.y - centre.y };
    const radius = @sqrt(q.x * q.x + q.y * q.y);

    // Tunnel: the log radius picks the ring, and the phase pushes every ring
    // outward, so the frame is always leaving the fulcrum.
    const depth = @log(radius / half + 0.01) * rings - rush_phase;
    const level = @floor(depth);
    const band = depth - level;

    // Each ring shows the frame again at a full radius, turned against its
    // neighbour. Mirroring both axes folds that copy into V chevrons.
    const angle = std.math.atan2(q.y, q.x) + level * twist + turn_phase;
    const c = @cos(turn_phase);
    const s_ = @sin(turn_phase);
    var local = dvui.Point.Physical{
        .x = @cos(angle) * half * band,
        .y = @sin(angle) * half * band,
    };
    local = .{
        .x = @abs(local.x * c - local.y * s_),
        .y = @abs(local.x * s_ + local.y * c),
    };

    const source = dvui.Point.Physical{ .x = centre.x + local.x, .y = centre.y + local.y };
    return .{
        .x = mix(p.x, wrap(source.x, size.w), strength),
        .y = mix(p.y, wrap(source.y, size.h), strength),
    };
}

fn mix(from: f32, to: f32, amount: f32) f32 {
    return from + (to - from) * amount;
}

/// Reflect `v` into `[0, extent]`. The reflection is the fold, so the frame
/// repeats at the border instead of smearing.
fn wrap(v: f32, extent: f32) f32 {
    if (extent <= 0) return v;
    const period = 2 * extent;
    var bounced = @mod(v, period);
    if (bounced < 0) bounced += period;
    if (bounced > extent) bounced = period - bounced;
    return bounced;
}

/// A grid of quads over the window, every vertex showing a folded texel.
pub fn mesh(
    arena: std.mem.Allocator,
    clock: Clock,
    size: dvui.Size.Physical,
    stills: []const dvui.Rect.Physical,
    shade: f32,
    border: f32,
    rings: f32,
) !geom.Mesh {
    const shape = gridShape(size);
    const across = shape.columns + 1;
    const down = @as(f32, @floatFromInt(shape.rows));
    const right = @as(f32, @floatFromInt(shape.columns));

    const vertexes = try arena.alloc(dvui.Vertex, across * (shape.rows + 1));
    const tint = shadeColour(shade);
    var at: usize = 0;
    for (0..shape.rows + 1) |row| {
        const y = size.h * @as(f32, @floatFromInt(row)) / down;
        for (0..across) |column| {
            const x = size.w * @as(f32, @floatFromInt(column)) / right;
            const source = fold(.{ .x = x, .y = y }, clock, size, stills, border, rings);
            vertexes[at] = .{
                .pos = .{ .x = x, .y = y },
                .col = tint,
                .uv = .{ geom.sampleUV(source.x, size.w), geom.sampleUV(source.y, size.h) },
            };
            at += 1;
        }
    }

    return .{
        .vertexes = vertexes,
        .indices = try geom.gridIndices(arena, shape.columns, shape.rows),
    };
}

const Shape = struct { columns: usize, rows: usize };

/// Grid that covers `size`: one vertex per `cell` pixels, coarsened only when
/// a finer grid would need more vertexes than the index buffer can address.
fn gridShape(size: dvui.Size.Physical) Shape {
    const stride = @max(cell, @sqrt(size.w * size.h / vertex_budget));
    return .{
        .columns = @intFromFloat(@max(1, @ceil(size.w / stride))),
        .rows = @intFromFloat(@max(1, @ceil(size.h / stride))),
    };
}

/// Lay the frame back through the fold, then put the chips back.
pub fn draw(
    texture: dvui.Texture,
    arena: std.mem.Allocator,
    clock: Clock,
    size: dvui.Size.Physical,
    stills: []const dvui.Rect.Physical,
    shade: f32,
    border: f32,
    rings: f32,
) !void {
    if (size.w <= 0 or size.h <= 0) return;
    const bounds = dvui.Rect.Physical{ .x = 0, .y = 0, .w = size.w, .h = size.h };

    const grid = try mesh(arena, clock, size, stills, shade, border, rings);

    try dvui.renderTriangles(.{
        .vertexes = grid.vertexes,
        .indices = grid.indices,
        .bounds = bounds,
    }, texture);

    try geom.repaint(arena, stills, size, texture);
}

/// Slider position for a ring count, clamped to the track.
pub fn ringsFraction(value: f32) f32 {
    return std.math.clamp((value - min_rings) / (max_rings - min_rings), 0, 1);
}

/// Ring count for a slider position, clamped to the range.
pub fn ringsAt(fraction: f32) f32 {
    return min_rings + std.math.clamp(fraction, 0, 1) * (max_rings - min_rings);
}

/// Shared effect-speed range, driven by the slider under the mode chips.
pub const min_speed: f32 = 0.2;
pub const max_speed: f32 = 2;

/// Slider position for a speed, clamped to the track.
pub fn speedFraction(value: f32) f32 {
    return std.math.clamp((value - min_speed) / (max_speed - min_speed), 0, 1);
}

/// Speed for a slider position, clamped to the range.
pub fn speedAt(fraction: f32) f32 {
    return min_speed + std.math.clamp(fraction, 0, 1) * (max_speed - min_speed);
}

/// Effect seconds from wall seconds. A 128 BPM track runs in real time; the app
/// defaults to 128 when no track has set the tempo.
pub fn tempoStep(elapsed: f64, bpm: f32) f64 {
    return elapsed * @as(f64, @floatCast(bpm)) / 128.0;
}

/// Vertex colour for a fold drawn at `shade` brightness.
fn shadeColour(shade: f32) dvui.Color.PMA {
    const level: u8 = @intFromFloat(@round(std.math.clamp(shade, 0, 1) * 255));
    return .{ .r = level, .g = level, .b = level };
}

/// Zero inside a still rect, one everywhere else. A positive `border` fades the
/// fold out at the window edge, so nothing samples past the frame.
fn clean(x: f32, y: f32, size: dvui.Size.Physical, stills: []const dvui.Rect.Physical, border: f32) f32 {
    const mask = geom.stillMask(x, y, stills, calm);
    if (border <= 0) return mask;
    const inset = @min(@min(x, y), @min(size.w - x, size.h - y));
    return std.math.clamp(inset / border, 0, 1) * mask;
}

const framesize = dvui.Size.Physical{ .w = 1180, .h = 720 };
const chips = [_]dvui.Rect.Physical{
    .{ .x = 1040, .y = 14, .w = 46, .h = 26 },
    .{ .x = 1092, .y = 14, .w = 46, .h = 26 },
};

test "the chips do not move" {
    const middle = dvui.Point.Physical{ .x = 1062, .y = 26 };
    for (0..40) |step| {
        const shown = fold(middle, .{ .rush = @as(f64, @floatFromInt(step)) * 0.6 }, framesize, &chips, 0, rings_default);
        try std.testing.expectEqual(@as(f32, 1062), shown.x);
        try std.testing.expectEqual(@as(f32, 26), shown.y);
    }
}

test "everything outside the stills is transformed" {
    var moved: usize = 0;
    var step: usize = 0;
    while (step < 20) : (step += 1) {
        const p = dvui.Point.Physical{
            .x = @as(f32, @floatFromInt(step)) * 59,
            .y = 4,
        };
        const shown = fold(p, .{ .rush = 2.5 }, framesize, &chips, 0, rings_default);
        if (@abs(shown.x - p.x) + @abs(shown.y - p.y) > 5) moved += 1;
    }
    try std.testing.expect(moved > 10);
}

test "the fold always samples inside the frame" {
    const time: f64 = 3.7;
    for (0..40) |row| {
        for (0..40) |column| {
            const p = dvui.Point.Physical{
                .x = @as(f32, @floatFromInt(column)) * 29.5,
                .y = @as(f32, @floatFromInt(row)) * 18.0,
            };
            const shown = fold(p, .{ .rush = time }, framesize, &chips, 0, rings_default);
            try std.testing.expect(shown.x >= 0 and shown.x <= framesize.w);
            try std.testing.expect(shown.y >= 0 and shown.y <= framesize.h);
        }
    }
}

test "the frame is folded, not copied" {
    const time: f64 = 5.0;
    var folded: usize = 0;
    var row: usize = 0;
    while (row < 20) : (row += 1) {
        var column: usize = 0;
        while (column < 20) : (column += 1) {
            const p = dvui.Point.Physical{
                .x = 60 + @as(f32, @floatFromInt(column)) * 55,
                .y = 60 + @as(f32, @floatFromInt(row)) * 32,
            };
            const shown = fold(p, .{ .rush = time }, framesize, &chips, 0, rings_default);
            if (@abs(shown.x - p.x) + @abs(shown.y - p.y) > 20) folded += 1;
        }
    }
    try std.testing.expect(folded > 100);
}

test "the mirror axes turn with the clock" {
    const p = dvui.Point.Physical{ .x = 700, .y = 300 };
    const before = fold(p, .{ .rush = 0 }, framesize, &chips, 0, rings_default);
    const after = fold(p, .{ .rush = 1 }, framesize, &chips, 0, rings_default);
    try std.testing.expect(@abs(before.x - after.x) + @abs(before.y - after.y) > 0.5);
}

test "the phase advances by the step, not by the elapsed time" {
    var clock: Clock = .{};
    var seconds: f64 = 0;
    while (seconds < 120) : (seconds += 0.5) {
        clock.advance(0.5, mood(seconds));
    }

    const before = clock.rush;
    const step = 0.01;
    clock.advance(step, mood(seconds));
    const moved = clock.rush - before;

    // A quarter faster or slower than the step, never a jump of the whole
    // effect clock.
    try std.testing.expect(moved > step * 0.8 and moved < step * 1.3);
}

test "speed and turn are seeded, not stepped" {
    const start = mood(0);
    try std.testing.expect(start.rate > 0.8 and start.rate < 1.3);

    var flips: usize = 0;
    var epoch: i64 = 0;
    while (epoch < 9) : (epoch += 1) {
        const before = mood(@as(f64, @floatFromInt(epoch)) * 6.5 + 0.1).spin;
        const after = mood(@as(f64, @floatFromInt(epoch + 1)) * 6.5 + 0.1).spin;
        if ((before > 0) != (after > 0)) flips += 1;
    }
    try std.testing.expect(flips > 0);

    const one = mood(12.31);
    const again = mood(12.31);
    try std.testing.expectEqual(one.rate, again.rate);
    try std.testing.expectEqual(one.spin, again.spin);
}

test "the speed slider round-trips and clamps" {
    for ([_]f32{ min_speed, 0.5, 1, 1.7, max_speed }) |value| {
        try std.testing.expectApproxEqAbs(value, speedAt(speedFraction(value)), 1e-6);
    }
    try std.testing.expectEqual(@as(f32, min_speed), speedAt(-1));
    try std.testing.expectEqual(@as(f32, max_speed), speedAt(2));
    try std.testing.expectEqual(@as(f32, 0), speedFraction(0));
    try std.testing.expectEqual(@as(f32, 1), speedFraction(99));
}

test "the effect clock follows the tempo" {
    try std.testing.expectEqual(@as(f64, 1.0), tempoStep(1.0, 128));
    try std.testing.expectEqual(@as(f64, 2.0), tempoStep(1.0, 256));
    try std.testing.expect(tempoStep(1.0, 90) < 0.8);
}

test "the grid fits one index buffer at any window size" {
    for ([_]dvui.Size.Physical{
        framesize,
        .{ .w = 3840, .h = 2160 },
        .{ .w = 7680, .h = 4320 },
    }) |size| {
        const shape = gridShape(size);
        try std.testing.expect((shape.columns + 1) * (shape.rows + 1) <= 65535);
    }
}

test "the lane slider round-trips and stays in range" {
    var value = min_rings;
    while (value <= max_rings) : (value += 0.3) {
        try std.testing.expectApproxEqAbs(value, ringsAt(ringsFraction(value)), 0.001);
    }
    try std.testing.expectEqual(min_rings, ringsAt(0));
    try std.testing.expectEqual(max_rings, ringsAt(1));
    try std.testing.expectEqual(@as(f32, 0), ringsFraction(min_rings - 5));
    try std.testing.expectEqual(@as(f32, 1), ringsFraction(max_rings + 5));
}

test "the fold is drawn at the shade it is given" {
    try std.testing.expectEqual(@as(u8, 255), shadeColour(1).r);
    try std.testing.expectEqual(@as(u8, 140), shadeColour(0.55).r);
    try std.testing.expectEqual(@as(u8, 0), shadeColour(0).r);
    try std.testing.expectEqual(@as(u8, 140), shadeColour(0.55).g);
    try std.testing.expectEqual(@as(u8, 255), shadeColour(0.55).a);
}

test "the pinned look holds the window border still" {
    const clock = Clock{ .rush = 40, .turn = 7 };

    const edge = dvui.Point.Physical{ .x = 0, .y = 360 };
    const shown = fold(edge, clock, framesize, &chips, border_px, rings_default);
    try std.testing.expectEqual(edge.x, shown.x);
    try std.testing.expectEqual(edge.y, shown.y);

    // Past the border the fold runs again.
    const inside = dvui.Point.Physical{ .x = 200, .y = 360 };
    const moved = fold(inside, clock, framesize, &chips, border_px, rings_default);
    try std.testing.expect(@abs(moved.x - inside.x) + @abs(moved.y - inside.y) > 1);
}
