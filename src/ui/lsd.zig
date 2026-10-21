//! The drift: while the mode runs the frame is drawn into an offscreen copy,
//! and that copy is laid back over the window through a slowly moving
//! displacement field, one colour channel at a time, under a drifting wash and
//! a lens flare.
//!
//! Displacements stay within a few pixels. Every control keeps its hit rect in
//! layout space, and the pointer pass moves the cursor by the same field, so a
//! press lands on the control the eye sees under it. The mode chips are
//! painted back from the copy last, so neither the drift, the fringe, the wash
//! nor the flare light ever reaches them.

const std = @import("std");
const dvui = @import("dvui");
const geom = @import("geom.zig");

/// Peak displacement, as a fraction of the window's shorter side.
const amplitude: f32 = 0.009;
/// Colour fringe at the window corner, as a fraction of the shorter side.
const dispersion: f32 = 0.0045;
/// Grid cell in physical pixels. The waves are hundreds of pixels long, so a
/// coarse grid still reads as smooth; it only has to be finer than `calm`.
const cell: f32 = 16;
/// Pixels between a still rect and the full drift around it.
const calm: f32 = 20;
/// The window border is pinned, so the warp never samples outside the frame.
const border: f32 = 24;
/// Brightest a wash channel gets, out of 255. Text sits far above this, so the
/// wash colours the frame without touching contrast.
const wash_peak: f32 = 36;

pub const Channel = enum { red, green, blue };

/// Displacement of the pixel at `p`, in physical pixels. Zero inside `still`
/// and on the window border.
pub fn offset(
    p: dvui.Point.Physical,
    time: f64,
    size: dvui.Size.Physical,
    still: []const dvui.Rect.Physical,
    strength: f32,
) dvui.Point.Physical {
    const reach = @min(size.w, size.h);
    if (reach <= 0) return .{};

    const x = p.x;
    const y = p.y;
    const t: f32 = @floatCast(time);

    // Long waves carry the window, a short one bends what sits on them. Their
    // weights add to one, so the bound below is the whole story.
    const drift_x = 0.45 * @sin(y * 0.0071 + t * 0.83) +
        0.35 * @sin((x + y) * 0.0043 - t * 0.57) +
        0.20 * @sin((x * 0.9 - y) * 0.0130 + t * 0.94);
    const drift_y = 0.45 * @cos(x * 0.0064 - t * 0.71) +
        0.35 * @sin((x - y) * 0.0049 + t * 0.49) +
        0.20 * @cos((x + y * 0.8) * 0.0118 - t * 1.07);

    const amount = amplitude * reach * strength * clean(x, y, size, still);
    return .{ .x = drift_x * amount, .y = drift_y * amount };
}

/// The texel shown at `p`. The mesh samples this for the vertex drawn at `p`,
/// so the pointer pass runs the same map: a press lands on what the eye sees.
pub fn sample(
    p: dvui.Point.Physical,
    time: f64,
    size: dvui.Size.Physical,
    still: []const dvui.Rect.Physical,
    strength: f32,
) dvui.Point.Physical {
    const moved = offset(p, time, size, still, strength);
    return .{ .x = p.x + moved.x, .y = p.y + moved.y };
}

/// Each vertex sits where the frame was drawn and carries the uv of the texel
/// its channel asks for, so the image bends and splits instead of sliding.
pub fn mesh(
    arena: std.mem.Allocator,
    time: f64,
    size: dvui.Size.Physical,
    still: []const dvui.Rect.Physical,
    channel: Channel,
    strength: f32,
) !geom.Mesh {
    const columns: usize = @intFromFloat(@max(1, @ceil(size.w / cell)));
    const rows: usize = @intFromFloat(@max(1, @ceil(size.h / cell)));
    const across = columns + 1;

    const vertexes = try arena.alloc(dvui.Vertex, across * (rows + 1));
    const indices = try geom.gridIndices(arena, columns, rows);

    var at: usize = 0;
    for (0..rows + 1) |row| {
        const y = @min(size.h, @as(f32, @floatFromInt(row)) * cell);
        for (0..across) |column| {
            const x = @min(size.w, @as(f32, @floatFromInt(column)) * cell);
            const moved = offset(.{ .x = x, .y = y }, time, size, still, strength);
            const spread = disperse(x, y, size, still, channel);
            vertexes[at] = .{
                .pos = .{ .x = x, .y = y },
                .col = tint(channel, @floatCast(time)),
                .uv = .{
                    geom.sampleUV(x + moved.x + spread.x, size.w),
                    geom.sampleUV(y + moved.y + spread.y, size.h),
                },
            };
            at += 1;
        }
    }

    return .{ .vertexes = vertexes, .indices = indices };
}

/// Lay `texture` back over the window: three channel passes, then the flare,
/// then the toggle's own pixels.
pub fn draw(
    texture: dvui.Texture,
    arena: std.mem.Allocator,
    time: f64,
    size: dvui.Size.Physical,
    still: []const dvui.Rect.Physical,
) !void {
    if (size.w <= 0 or size.h <= 0) return;
    const bounds = dvui.Rect.Physical{ .x = 0, .y = 0, .w = size.w, .h = size.h };

    for ([_]Channel{ .red, .green, .blue }) |channel| {
        const grid = try mesh(arena, time, size, still, channel, 1);
        try dvui.renderTriangles(.{
            .vertexes = grid.vertexes,
            .indices = grid.indices,
            .bounds = bounds,
        }, texture);
    }

    const colour = try wash(arena, time, size, wash_peak);
    try dvui.renderTriangles(colour, null);

    const glow = try flares(arena, time, size);
    if (glow.vertexes.len > 0) try dvui.renderTriangles(glow, null);

    try geom.repaint(arena, still, size, texture);
}

/// A slow wash of colour over the whole frame, three palette hues drifting
/// against each other. Additive, so the dark surface takes the colour and the
/// text keeps its brightness.
pub fn wash(arena: std.mem.Allocator, time: f64, size: dvui.Size.Physical, peak: f32) !dvui.Triangles {
    const columns = 6;
    const rows = 4;
    const across = columns + 1;
    const t: f32 = @floatCast(time);

    const vertexes = try arena.alloc(dvui.Vertex, across * (rows + 1));
    for (0..rows + 1) |row| {
        for (0..columns + 1) |column| {
            const at = row * across + column;
            const x = size.w * @as(f32, @floatFromInt(column)) / columns;
            const y = size.h * @as(f32, @floatFromInt(row)) / rows;
            vertexes[at] = .{ .pos = .{ .x = x, .y = y }, .col = washColor(x, y, t, peak) };
        }
    }

    const indices = try arena.alloc(dvui.Vertex.Index, columns * rows * 6);
    var index: usize = 0;
    for (0..rows) |row| {
        for (0..columns) |column| {
            const top_left = row * across + column;
            const top_right = top_left + 1;
            const bottom_left = top_left + across;
            const bottom_right = bottom_left + 1;
            indices[index] = @intCast(bottom_left);
            indices[index + 1] = @intCast(bottom_right);
            indices[index + 2] = @intCast(top_right);
            indices[index + 3] = @intCast(bottom_left);
            indices[index + 4] = @intCast(top_right);
            indices[index + 5] = @intCast(top_left);
            index += 6;
        }
    }

    return .{ .vertexes = vertexes, .indices = indices, .bounds = .{ .x = 0, .y = 0, .w = size.w, .h = size.h } };
}

/// Three hues from the window palette, each on its own slow wave.
fn washColor(x: f32, y: f32, t: f32, peak: f32) dvui.Color.PMA {
    const purple = waveAt(x, y, t, 0);
    const teal = waveAt(x * 1.3, y * 0.8, t, 2.1);
    const orange = waveAt(x * 0.7, y * 1.1, t, 4.2);

    const r = (0.74 * purple + 0.31 * teal + 1.00 * orange) / 3;
    const g = (0.58 * purple + 0.90 * teal + 0.72 * orange) / 3;
    const b = (0.98 * purple + 0.85 * teal + 0.42 * orange) / 3;

    return .{
        .r = @intFromFloat(r * peak),
        .g = @intFromFloat(g * peak),
        .b = @intFromFloat(b * peak),
        .a = 0,
    };
}

fn waveAt(x: f32, y: f32, t: f32, phase: f32) f32 {
    return 0.5 + 0.5 * @sin(x * 0.0026 + y * 0.0031 + t * 0.37 + phase);
}

/// The light a lens would throw: a bloom and a streak at the source, ghosts
/// along the line through the middle. Additive, so it adds colour and leaves
/// the frame underneath readable.
pub fn flares(arena: std.mem.Allocator, time: f64, size: dvui.Size.Physical) !dvui.Triangles {
    const reach = @min(size.w, size.h);
    const t: f32 = @floatCast(time);
    // A source that wanders across the upper part of the window, never quite
    // where it was.
    const source = dvui.Point.Physical{
        .x = size.w * 0.60 + reach * 0.30 * @sin(t * 0.21),
        .y = size.h * 0.20 + reach * 0.09 * @cos(t * 0.29),
    };
    const middle = dvui.Point.Physical{ .x = size.w / 2, .y = size.h / 2 };

    var glow = geom.Glow{ .arena = arena };
    try glow.disc(source, reach * 0.26, reach * 0.26, .{ .r = 18, .g = 14, .b = 26, .a = 0 });
    try glow.disc(source, reach * 0.09, reach * 0.09, .{ .r = 34, .g = 26, .b = 14, .a = 0 });
    try glow.disc(source, reach * 0.014, reach * 0.014, .{ .r = 54, .g = 48, .b = 36, .a = 0 });
    try glow.disc(source, reach * 0.42, reach * 0.007, .{ .r = 26, .g = 16, .b = 6, .a = 0 });

    const ghosts = [_]struct { behind: f32, size: f32, color: [3]u8 }{
        .{ .behind = 0.6, .size = 0.055, .color = .{ 40, 12, 52 } },
        .{ .behind = 1.2, .size = 0.030, .color = .{ 56, 30, 8 } },
        .{ .behind = 2.0, .size = 0.075, .color = .{ 12, 44, 30 } },
        .{ .behind = 3.0, .size = 0.040, .color = .{ 44, 16, 58 } },
    };
    for (ghosts) |ghost| {
        const at = dvui.Point.Physical{
            .x = middle.x + (middle.x - source.x) * ghost.behind,
            .y = middle.y + (middle.y - source.y) * ghost.behind,
        };
        const radius = reach * ghost.size;
        try glow.disc(at, radius, radius, .{
            .r = ghost.color[0],
            .g = ghost.color[1],
            .b = ghost.color[2],
            .a = 0,
        });
    }

    return glow.triangles(.{ .x = 0, .y = 0, .w = size.w, .h = size.h });
}

/// Outward push at `p` for one channel, in physical pixels: red rides out,
/// blue rides in. The split is what reads as colour fringing at hard edges.
fn disperse(
    x: f32,
    y: f32,
    size: dvui.Size.Physical,
    still: []const dvui.Rect.Physical,
    channel: Channel,
) dvui.Point.Physical {
    const direction: f32 = switch (channel) {
        .red => 1,
        .blue => -1,
        .green => return .{},
    };

    const half_w = size.w / 2;
    const half_h = size.h / 2;
    const dx = x - half_w;
    const dy = y - half_h;
    const distance = @sqrt(dx * dx + dy * dy);
    if (distance < 1) return .{};

    const corner = @sqrt(half_w * half_w + half_h * half_h);
    const amount = @min(size.w, size.h) * dispersion * (distance / corner) *
        clean(x, y, size, still) * direction;
    return .{ .x = dx / distance * amount, .y = dy / distance * amount };
}

/// The spread of the three passes: red replaces the frame, green and blue add
/// their channel on top. The blend is `src + dst * (1 - srcA)`, so a zero
/// alpha vertex colour lands as pure addition.
fn tint(channel: Channel, time: f32) dvui.Color.PMA {
    const phase: f32 = switch (channel) {
        .red => 0,
        .green => 2.1,
        .blue => 4.2,
    };
    const breathe = 0.92 + 0.08 * @sin(time * 0.43 + phase);
    const level: u8 = @intFromFloat(@round(255 * breathe));

    return switch (channel) {
        .red => .{ .r = level, .g = 0, .b = 0, .a = 0xff },
        .green => .{ .r = 0, .g = level, .b = 0, .a = 0 },
        .blue => .{ .r = 0, .g = 0, .b = level, .a = 0 },
    };
}

/// Zero at the window border and inside `still`, one elsewhere.
fn clean(x: f32, y: f32, size: dvui.Size.Physical, still: []const dvui.Rect.Physical) f32 {
    const inset = @min(@min(x, y), @min(size.w - x, size.h - y));
    const anchorage = std.math.clamp(inset / border, 0, 1);
    return anchorage * geom.stillMask(x, y, still, calm);
}

const framesize = dvui.Size.Physical{ .w = 1180, .h = 720 };
const toggle = dvui.Rect.Physical{ .x = 1100, .y = 16, .w = 46, .h = 24 };

test "the still rect does not move" {
    const middle = dvui.Point.Physical{ .x = 1120, .y = 28 };
    for (0..40) |step| {
        const moved = offset(middle, @as(f64, @floatFromInt(step)) * 0.7, framesize, &.{toggle}, 1);
        try std.testing.expectEqual(@as(f32, 0), moved.x);
        try std.testing.expectEqual(@as(f32, 0), moved.y);
    }
}

test "the window border does not move" {
    const corner = dvui.Point.Physical{ .x = 0, .y = 0 };
    const moved = offset(corner, 12.5, framesize, &.{}, 1);
    try std.testing.expectEqual(@as(f32, 0), moved.x);
    try std.testing.expectEqual(@as(f32, 0), moved.y);
}

test "the drift stays within a few pixels" {
    const reach = @min(framesize.w, framesize.h) * amplitude;
    var y: f32 = 0;
    while (y <= framesize.h) : (y += 30) {
        var x: f32 = 0;
        while (x <= framesize.w) : (x += 30) {
            const moved = offset(.{ .x = x, .y = y }, 1.5, framesize, &.{}, 1);
            try std.testing.expect(@abs(moved.x) <= reach);
            try std.testing.expect(@abs(moved.y) <= reach);
        }
    }
}

test "the mesh bends the frame instead of sliding it" {
    const grid = try mesh(std.testing.allocator, 1.5, framesize, &.{toggle}, .red, 1);
    defer std.testing.allocator.free(grid.vertexes);
    defer std.testing.allocator.free(grid.indices);

    const columns = @as(usize, @intFromFloat(@ceil(framesize.w / cell)));
    const rows = @as(usize, @intFromFloat(@ceil(framesize.h / cell)));
    try std.testing.expectEqual((columns + 1) * (rows + 1), grid.vertexes.len);
    try std.testing.expectEqual(columns * rows * 6, grid.indices.len);

    var bent = false;
    for (grid.vertexes) |vertex| {
        const own_x = vertex.uv[0] * framesize.w;
        const own_y = vertex.uv[1] * framesize.h;
        if (@abs(own_x - vertex.pos.x) + @abs(own_y - vertex.pos.y) > 1) bent = true;
    }
    try std.testing.expect(bent);
}

test "the mesh leaves the toggle on its own texels" {
    const grid = try mesh(std.testing.allocator, 6.0, framesize, &.{toggle}, .blue, 1);
    defer std.testing.allocator.free(grid.vertexes);
    defer std.testing.allocator.free(grid.indices);

    var checked: usize = 0;
    for (grid.vertexes) |vertex| {
        const inside = vertex.pos.x >= toggle.x and vertex.pos.x <= toggle.x + toggle.w and
            vertex.pos.y >= toggle.y and vertex.pos.y <= toggle.y + toggle.h;
        if (!inside) continue;
        try std.testing.expectApproxEqAbs(vertex.pos.x / framesize.w, vertex.uv[0], 1e-6);
        try std.testing.expectApproxEqAbs(vertex.pos.y / framesize.h, vertex.uv[1], 1e-6);
        checked += 1;
    }
    try std.testing.expect(checked > 0);
}

test "the three passes leave the toggle identical" {
    const red = try mesh(std.testing.allocator, 3.0, framesize, &.{toggle}, .red, 1);
    defer std.testing.allocator.free(red.vertexes);
    defer std.testing.allocator.free(red.indices);
    const blue = try mesh(std.testing.allocator, 3.0, framesize, &.{toggle}, .blue, 1);
    defer std.testing.allocator.free(blue.vertexes);
    defer std.testing.allocator.free(blue.indices);

    var checked: usize = 0;
    for (red.vertexes, blue.vertexes) |one, other| {
        const inside = one.pos.x >= toggle.x and one.pos.x <= toggle.x + toggle.w and
            one.pos.y >= toggle.y and one.pos.y <= toggle.y + toggle.h;
        if (!inside) continue;
        try std.testing.expectEqual(one.uv, other.uv);
        checked += 1;
    }
    try std.testing.expect(checked > 0);
}

test "red rides out and blue rides in" {
    const right = dvui.Point.Physical{ .x = 900, .y = 360 };
    const red = disperse(right.x, right.y, framesize, &.{toggle}, .red);
    const blue = disperse(right.x, right.y, framesize, &.{toggle}, .blue);
    const green = disperse(right.x, right.y, framesize, &.{toggle}, .green);

    try std.testing.expect(red.x > 0.5);
    try std.testing.expect(blue.x < -0.5);
    try std.testing.expectEqual(@as(f32, 0), green.x);
    try std.testing.expectEqual(@as(f32, 0), green.y);
}

test "the wash colours the frame without washing it out" {
    const colour = try wash(std.testing.allocator, 5.0, framesize, wash_peak);
    defer std.testing.allocator.free(colour.vertexes);
    defer std.testing.allocator.free(colour.indices);

    var coloured = false;
    for (colour.vertexes) |vertex| {
        const peak = @max(vertex.col.r, @max(vertex.col.g, vertex.col.b));
        try std.testing.expect(peak <= wash_peak);
        try std.testing.expectEqual(@as(u8, 0), vertex.col.a);
        if (peak > 0) coloured = true;
    }
    try std.testing.expect(coloured);
}

test "the flare is light, not paint" {
    const glow = try flares(std.testing.allocator, 2.0, framesize);
    defer std.testing.allocator.free(glow.vertexes);
    defer std.testing.allocator.free(glow.indices);

    try std.testing.expect(glow.vertexes.len > 0);
    var lit = false;
    for (glow.vertexes) |vertex| {
        // Zero alpha is what makes the glow additive instead of a slab.
        try std.testing.expectEqual(@as(u8, 0), vertex.col.a);
        if (@as(u16, vertex.col.r) + vertex.col.g + vertex.col.b > 0) lit = true;
    }
    try std.testing.expect(lit);
}

test "the mesh never samples outside the window" {
    var time: f64 = 0;
    while (time < 30) : (time += 7.5) {
        const grid = try mesh(std.testing.allocator, time, framesize, &.{toggle}, .red, 1);
        defer std.testing.allocator.free(grid.vertexes);
        defer std.testing.allocator.free(grid.indices);

        for (grid.vertexes) |vertex| {
            try std.testing.expect(vertex.uv[0] >= 0 and vertex.uv[0] <= 1);
            try std.testing.expect(vertex.uv[1] >= 0 and vertex.uv[1] <= 1);
        }
    }
}

test "the pointer runs the same map as the mesh" {
    const near = dvui.Point.Physical{ .x = 1120, .y = 60 };
    const moved = offset(near, 4.25, framesize, &.{toggle}, 1);
    try std.testing.expect(@abs(moved.x) + @abs(moved.y) > 0);

    // What the mesh shows at `near` is what the pointer returns there, so a
    // press lands on the pixel under the cursor.
    const shown = sample(near, 4.25, framesize, &.{toggle}, 1);
    try std.testing.expectApproxEqAbs(near.x + moved.x, shown.x, 1e-6);
    try std.testing.expectApproxEqAbs(near.y + moved.y, shown.y, 1e-6);

    // Inside the chip the map is the identity, so the chip cannot miss.
    const on_chip = dvui.Point.Physical{ .x = 1120, .y = 28 };
    const there = sample(on_chip, 4.25, framesize, &.{toggle}, 1);
    try std.testing.expectEqual(@as(f32, 1120), there.x);
    try std.testing.expectEqual(@as(f32, 28), there.y);
}
