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
const rings_per_log: f32 = 2.2;
/// Ring phase advanced per effect second. Positive means the rings travel
/// outward, from the fulcrum to the edges.
const rush: f32 = 0.9;
/// Turning speed of the ring content, in radians per effect second.
const spin: f32 = 0.5;
/// How far each ring is turned against the next.
const twist: f32 = 0.55;
/// Effect speed against the tempo clock: half again as fast as the beat.
const speed: f32 = 1.6;
/// The window border is pinned, so the fold never samples outside the frame.
const border: f32 = 26;
/// Pixels between a still rect and the full fold around it.
const calm: f32 = 18;
/// Vertex every this many physical pixels. Mirror seams are sharp, so the grid
/// has to be fine.
const cell: f32 = 9;
/// One index buffer addresses u16 vertexes, so a window larger than this many
/// cells gets a coarser stride instead of an overflowing index.
const vertex_budget: f32 = 60_000;

/// The texel shown at `p`. Identity on the window border and inside `stills`.
pub fn fold(
    p: dvui.Point.Physical,
    time: f64,
    size: dvui.Size.Physical,
    stills: []const dvui.Rect.Physical,
) dvui.Point.Physical {
    if (size.w <= 0 or size.h <= 0) return p;
    const strength = clean(p.x, p.y, size, stills);
    if (strength <= 0) return p;

    const t: f32 = @floatCast(time * speed);
    const half = @min(size.w, size.h) / 2;
    const centre = dvui.Point.Physical{ .x = size.w / 2, .y = size.h / 2 };
    const q = dvui.Point.Physical{ .x = p.x - centre.x, .y = p.y - centre.y };
    const radius = @sqrt(q.x * q.x + q.y * q.y);

    // Tunnel: the log radius picks the ring, and the phase pushes every ring
    // outward, so the frame is always leaving the fulcrum.
    const depth = @log(radius / half + 0.01) * rings_per_log - t * rush;
    const level = @floor(depth);
    const band = depth - level;

    // Each ring shows the frame again at a full radius, turned against its
    // neighbour. Mirroring both axes folds that copy into V chevrons.
    const angle = std.math.atan2(q.y, q.x) + level * twist + t * spin;
    const turn = t * spin;
    const c = @cos(turn);
    const s_ = @sin(turn);
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
    time: f64,
    size: dvui.Size.Physical,
    stills: []const dvui.Rect.Physical,
) !geom.Mesh {
    const shape = gridShape(size);
    const across = shape.columns + 1;
    const down = @as(f32, @floatFromInt(shape.rows));
    const right = @as(f32, @floatFromInt(shape.columns));

    const vertexes = try arena.alloc(dvui.Vertex, across * (shape.rows + 1));
    var at: usize = 0;
    for (0..shape.rows + 1) |row| {
        const y = size.h * @as(f32, @floatFromInt(row)) / down;
        for (0..across) |column| {
            const x = size.w * @as(f32, @floatFromInt(column)) / right;
            const source = fold(.{ .x = x, .y = y }, time, size, stills);
            vertexes[at] = .{
                .pos = .{ .x = x, .y = y },
                .col = .white,
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
    time: f64,
    size: dvui.Size.Physical,
    stills: []const dvui.Rect.Physical,
) !void {
    if (size.w <= 0 or size.h <= 0) return;
    const bounds = dvui.Rect.Physical{ .x = 0, .y = 0, .w = size.w, .h = size.h };

    const grid = try mesh(arena, time, size, stills);
    try dvui.renderTriangles(.{
        .vertexes = grid.vertexes,
        .indices = grid.indices,
        .bounds = bounds,
    }, texture);

    try geom.repaint(arena, stills, size, texture);
}

/// Effect seconds from wall seconds. A 128 BPM track runs in real time; the app
/// defaults to 128 when no track has set the tempo.
pub fn tempoStep(elapsed: f64, bpm: f32) f64 {
    return elapsed * @as(f64, @floatCast(bpm)) / 128.0;
}

/// Zero at the border and inside a still rect, one in the open frame.
fn clean(x: f32, y: f32, size: dvui.Size.Physical, stills: []const dvui.Rect.Physical) f32 {
    const inset = @min(@min(x, y), @min(size.w - x, size.h - y));
    const anchorage = std.math.clamp(inset / border, 0, 1);
    return anchorage * geom.stillMask(x, y, stills, calm);
}

const framesize = dvui.Size.Physical{ .w = 1180, .h = 720 };
const chips = [_]dvui.Rect.Physical{
    .{ .x = 1040, .y = 14, .w = 46, .h = 26 },
    .{ .x = 1092, .y = 14, .w = 46, .h = 26 },
};

test "the chips do not move" {
    const middle = dvui.Point.Physical{ .x = 1062, .y = 26 };
    for (0..40) |step| {
        const shown = fold(middle, @as(f64, @floatFromInt(step)) * 0.6, framesize, &chips);
        try std.testing.expectEqual(@as(f32, 1062), shown.x);
        try std.testing.expectEqual(@as(f32, 26), shown.y);
    }
}

test "the window border does not move" {
    const edge = dvui.Point.Physical{ .x = 0, .y = 360 };
    for (0..20) |step| {
        const shown = fold(edge, @as(f64, @floatFromInt(step)) * 0.9, framesize, &chips);
        try std.testing.expectEqual(edge.x, shown.x);
        try std.testing.expectEqual(edge.y, shown.y);
    }
}

test "the fold always samples inside the frame" {
    const time: f64 = 3.7;
    for (0..40) |row| {
        for (0..40) |column| {
            const p = dvui.Point.Physical{
                .x = @as(f32, @floatFromInt(column)) * 29.5,
                .y = @as(f32, @floatFromInt(row)) * 18.0,
            };
            const shown = fold(p, time, framesize, &chips);
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
            const shown = fold(p, time, framesize, &chips);
            if (@abs(shown.x - p.x) + @abs(shown.y - p.y) > 20) folded += 1;
        }
    }
    try std.testing.expect(folded > 100);
}

test "the mirror axes turn with the clock" {
    const p = dvui.Point.Physical{ .x = 700, .y = 300 };
    const before = fold(p, 0, framesize, &chips);
    const after = fold(p, 1, framesize, &chips);
    try std.testing.expect(@abs(before.x - after.x) + @abs(before.y - after.y) > 0.5);
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
