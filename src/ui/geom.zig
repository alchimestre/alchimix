//! Triangle buffers shared by the effect layers: a quad grid, an additive light
//! builder, and the little quad that paints a control back over an effect.

const std = @import("std");
const dvui = @import("dvui");

/// Segments around one additive disc.
const disc_segments: usize = 32;

pub const Mesh = struct {
    vertexes: []dvui.Vertex,
    indices: []dvui.Vertex.Index,
};

/// Index list for `columns` x `rows` quads, two triangles each.
pub fn gridIndices(arena: std.mem.Allocator, columns: usize, rows: usize) ![]dvui.Vertex.Index {
    const across = columns + 1;
    const indices = try arena.alloc(dvui.Vertex.Index, columns * rows * 6);

    var at: usize = 0;
    for (0..rows) |row| {
        for (0..columns) |column| {
            const top_left = row * across + column;
            const top_right = top_left + 1;
            const bottom_left = top_left + across;
            const bottom_right = bottom_left + 1;

            indices[at] = @intCast(bottom_left);
            indices[at + 1] = @intCast(bottom_right);
            indices[at + 2] = @intCast(top_right);
            indices[at + 3] = @intCast(bottom_left);
            indices[at + 4] = @intCast(top_right);
            indices[at + 5] = @intCast(top_left);
            at += 6;
        }
    }
    return indices;
}

pub fn sampleUV(source: f32, extent: f32) f32 {
    return std.math.clamp(source / extent, 0, 1);
}

/// Zero inside any of `rects`, one beyond `calm` from all of them, smooth in
/// between.
pub fn stillMask(x: f32, y: f32, rects: []const dvui.Rect.Physical, calm: f32) f32 {
    var mask: f32 = 1;
    for (rects) |rect| {
        const dx = @max(@max(rect.x - x, x - (rect.x + rect.w)), 0);
        const dy = @max(@max(rect.y - y, y - (rect.y + rect.h)), 0);
        const distance = @sqrt(dx * dx + dy * dy);
        const t = std.math.clamp(distance / calm, 0, 1);
        mask = @min(mask, t * t * (3 - 2 * t));
    }
    return mask;
}

/// A quad covering `rect`, each corner sampling its own texel. Painting a
/// control back through this is what keeps it exact under any effect.
pub fn quadMesh(arena: std.mem.Allocator, rect: dvui.Rect.Physical, size: dvui.Size.Physical) !Mesh {
    const corners = [_]dvui.Point.Physical{
        .{ .x = rect.x, .y = rect.y },
        .{ .x = rect.x + rect.w, .y = rect.y },
        .{ .x = rect.x + rect.w, .y = rect.y + rect.h },
        .{ .x = rect.x, .y = rect.y + rect.h },
    };

    const vertexes = try arena.alloc(dvui.Vertex, corners.len);
    for (corners, 0..) |corner, at| {
        vertexes[at] = .{
            .pos = corner,
            .col = .white,
            .uv = .{ sampleUV(corner.x, size.w), sampleUV(corner.y, size.h) },
        };
    }

    const indices = try arena.alloc(dvui.Vertex.Index, 6);
    const fan = [_]dvui.Vertex.Index{ 0, 1, 2, 0, 2, 3 };
    @memcpy(indices, &fan);

    return .{ .vertexes = vertexes, .indices = indices };
}

/// A coloured rect the frame kept, so an effect can paint it again.
pub const Quad = struct {
    rect: dvui.Rect.Physical,
    colour: dvui.Color,
};

/// One mesh for a run of solid quads, drawn without a texture.
pub fn solidQuads(arena: std.mem.Allocator, quads: []const Quad) !Mesh {
    const vertexes = try arena.alloc(dvui.Vertex, quads.len * 4);
    const indices = try arena.alloc(dvui.Vertex.Index, quads.len * 6);
    const fan = [_]dvui.Vertex.Index{ 0, 1, 2, 0, 2, 3 };

    for (quads, 0..) |quad, at| {
        const rect = quad.rect;
        const corners = [_]dvui.Point.Physical{
            .{ .x = rect.x, .y = rect.y },
            .{ .x = rect.x + rect.w, .y = rect.y },
            .{ .x = rect.x + rect.w, .y = rect.y + rect.h },
            .{ .x = rect.x, .y = rect.y + rect.h },
        };
        const first: dvui.Vertex.Index = @intCast(at * 4);
        for (corners, 0..) |corner, corner_at| {
            vertexes[at * 4 + corner_at] = .{
                .pos = corner,
                .col = .fromColor(quad.colour),
                .uv = .{ 0, 0 },
            };
        }
        for (fan, 0..) |offset, i| indices[at * 6 + i] = first + offset;
    }

    return .{ .vertexes = vertexes, .indices = indices };
}

/// Paint every rect in `rects` back from `texture`, untouched.
pub fn repaint(
    arena: std.mem.Allocator,
    rects: []const dvui.Rect.Physical,
    size: dvui.Size.Physical,
    texture: dvui.Texture,
) !void {
    for (rects) |rect| {
        const quad = try quadMesh(arena, rect, size);
        try dvui.renderTriangles(.{
            .vertexes = quad.vertexes,
            .indices = quad.indices,
            .bounds = rect,
        }, texture);
    }
}

/// Additive light: every vertex carries colour with zero alpha, so the blend
/// adds the colour and leaves whatever is underneath alone.
pub const Glow = struct {
    arena: std.mem.Allocator,
    vertexes: std.ArrayList(dvui.Vertex) = .empty,
    indices: std.ArrayList(dvui.Vertex.Index) = .empty,

    pub fn disc(
        self: *Glow,
        centre: dvui.Point.Physical,
        rx: f32,
        ry: f32,
        colour: dvui.Color.PMA,
    ) !void {
        const first: dvui.Vertex.Index = @intCast(self.vertexes.items.len);
        try self.vertexes.append(self.arena, .{ .pos = centre, .col = colour });

        for (0..disc_segments + 1) |step| {
            const angle = @as(f32, @floatFromInt(step)) / disc_segments * std.math.tau;
            try self.vertexes.append(self.arena, .{
                .pos = .{ .x = centre.x + @cos(angle) * rx, .y = centre.y + @sin(angle) * ry },
                .col = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            });
        }

        for (0..disc_segments) |step| {
            const rim: dvui.Vertex.Index = first + 1 + @as(dvui.Vertex.Index, @intCast(step));
            const fan = [_]dvui.Vertex.Index{ first, rim, rim + 1 };
            try self.indices.appendSlice(self.arena, &fan);
        }
    }

    pub fn triangle(
        self: *Glow,
        a: dvui.Point.Physical,
        b: dvui.Point.Physical,
        c: dvui.Point.Physical,
        colour: dvui.Color.PMA,
    ) !void {
        const first: dvui.Vertex.Index = @intCast(self.vertexes.items.len);
        const points = [_]dvui.Vertex{
            .{ .pos = a, .col = colour },
            .{ .pos = b, .col = colour },
            .{ .pos = c, .col = colour },
        };
        try self.vertexes.appendSlice(self.arena, &points);

        const fan = [_]dvui.Vertex.Index{ first, first + 1, first + 2 };
        try self.indices.appendSlice(self.arena, &fan);
    }

    /// A filled convex polygon, fanned from its first point.
    pub fn polygon(self: *Glow, points: []const dvui.Point.Physical, colour: dvui.Color.PMA) !void {
        if (points.len < 3) return;
        const first: dvui.Vertex.Index = @intCast(self.vertexes.items.len);
        for (points) |point| {
            try self.vertexes.append(self.arena, .{ .pos = point, .col = colour });
        }
        for (1..points.len - 1) |step| {
            const fan = [_]dvui.Vertex.Index{
                first,
                first + @as(dvui.Vertex.Index, @intCast(step)),
                first + @as(dvui.Vertex.Index, @intCast(step + 1)),
            };
            try self.indices.appendSlice(self.arena, &fan);
        }
    }

    /// A limb from `from` to `to`, `width` pixels either side of the line.
    pub fn limb(
        self: *Glow,
        from: dvui.Point.Physical,
        to: dvui.Point.Physical,
        width: f32,
        colour: dvui.Color.PMA,
    ) !void {
        const dx = to.x - from.x;
        const dy = to.y - from.y;
        const length = @sqrt(dx * dx + dy * dy);
        if (length < 0.01) return;

        const nx = -dy / length * width;
        const ny = dx / length * width;
        const first: dvui.Vertex.Index = @intCast(self.vertexes.items.len);
        const corners = [_]dvui.Vertex{
            .{ .pos = .{ .x = from.x + nx, .y = from.y + ny }, .col = colour },
            .{ .pos = .{ .x = from.x - nx, .y = from.y - ny }, .col = colour },
            .{ .pos = .{ .x = to.x - nx, .y = to.y - ny }, .col = colour },
            .{ .pos = .{ .x = to.x + nx, .y = to.y + ny }, .col = colour },
        };
        try self.vertexes.appendSlice(self.arena, &corners);

        const fan = [_]dvui.Vertex.Index{ first, first + 1, first + 2, first, first + 2, first + 3 };
        try self.indices.appendSlice(self.arena, &fan);
    }

    pub fn triangles(self: *Glow, bounds: dvui.Rect.Physical) !dvui.Triangles {
        return .{
            .vertexes = try self.vertexes.toOwnedSlice(self.arena),
            .indices = try self.indices.toOwnedSlice(self.arena),
            .bounds = bounds,
        };
    }
};

test "the grid indices cover every quad once" {
    const indices = try gridIndices(std.testing.allocator, 3, 2);
    defer std.testing.allocator.free(indices);

    try std.testing.expectEqual(@as(usize, 3 * 2 * 6), indices.len);
    var highest: usize = 0;
    for (indices) |index| highest = @max(highest, index);
    try std.testing.expectEqual(@as(usize, 3 + 1) * (2 + 1) - 1, highest);
}

test "the repaint quad samples its own corners" {
    const rect = dvui.Rect.Physical{ .x = 40, .y = 20, .w = 60, .h = 30 };
    const size = dvui.Size.Physical{ .w = 200, .h = 100 };
    const quad = try quadMesh(std.testing.allocator, rect, size);
    defer std.testing.allocator.free(quad.vertexes);
    defer std.testing.allocator.free(quad.indices);

    try std.testing.expectEqual(@as(usize, 4), quad.vertexes.len);
    for (quad.vertexes) |vertex| {
        try std.testing.expectApproxEqAbs(vertex.pos.x / size.w, vertex.uv[0], 1e-6);
        try std.testing.expectApproxEqAbs(vertex.pos.y / size.h, vertex.uv[1], 1e-6);
    }
}

test "the still mask is zero inside and one far away" {
    const rect = dvui.Rect.Physical{ .x = 100, .y = 100, .w = 40, .h = 20 };
    try std.testing.expectEqual(@as(f32, 0), stillMask(120, 110, &.{rect}, 18));
    try std.testing.expectEqual(@as(f32, 1), stillMask(0, 0, &.{rect}, 18));

    // Two rects: the nearer one wins.
    const other = dvui.Rect.Physical{ .x = 400, .y = 400, .w = 10, .h = 10 };
    try std.testing.expectEqual(@as(f32, 0), stillMask(405, 405, &.{ rect, other }, 18));
}

test "solid quads keep their colour and cover their rect" {
    const quads = [_]Quad{
        .{
            .rect = .{ .x = 4, .y = 6, .w = 10, .h = 20 },
            .colour = .{ .r = 0xff, .g = 0x40, .b = 0x00, .a = 0xff },
        },
        .{ .rect = .{ .x = 0, .y = 0, .w = 2, .h = 2 }, .colour = .white },
    };

    const mesh = try solidQuads(std.testing.allocator, &quads);
    defer {
        std.testing.allocator.free(mesh.vertexes);
        std.testing.allocator.free(mesh.indices);
    }

    try std.testing.expectEqual(@as(usize, 8), mesh.vertexes.len);
    try std.testing.expectEqual(@as(usize, 12), mesh.indices.len);
    try std.testing.expectEqual(@as(f32, 14), mesh.vertexes[2].pos.x);
    try std.testing.expectEqual(@as(f32, 26), mesh.vertexes[2].pos.y);
    try std.testing.expectEqual(@as(u8, 0xff), mesh.vertexes[0].col.r);
    try std.testing.expectEqual(@as(u8, 0x40), mesh.vertexes[0].col.g);
    for (mesh.indices) |index| try std.testing.expect(index < mesh.vertexes.len);
}
