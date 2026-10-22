//! The eyeball at the middle of the tunnel. The picture of the eye is a sphere:
//! its iris relief is turned into a normal map, and the folded frame is sampled
//! through those normals, so the tunnel's visuals wrap the ball instead of
//! sitting on top of it.
//!
//! The albedo is a raw RGB bitmap embedded in the binary. Its normals are
//! derived once at startup from the luminance gradient, so the only data that
//! ships is the picture.

const std = @import("std");
const dvui = @import("dvui");
const geom = @import("geom.zig");

/// Side of the embedded albedo, in texels.
pub const side: usize = 192;

const albedo_bytes = @embedFile("../assets/eyeball.bin");

/// How much the iris relief bends the sample under it.
const relief: f32 = 0.06;

pub const Eye = struct {
    /// Tangent-space normals, two signed bytes each: `x` then `y`.
    normals: []const [2]i8,
    /// Albedo as premultiplied colours, one per texel.
    colours: []const dvui.Color,

    pub fn init(allocator: std.mem.Allocator) !Eye {
        const colours = try allocator.alloc(dvui.Color, side * side);
        errdefer allocator.free(colours);
        for (colours, 0..) |*colour, at| {
            const base = at * 3;
            // The albedo multiplies the picture it is laid over, so it is
            // lifted here to keep the iris from going to mud.
            colour.* = .{
                .r = lift(albedo_bytes[base]),
                .g = lift(albedo_bytes[base + 1]),
                .b = lift(albedo_bytes[base + 2]),
                .a = 255,
            };
        }

        const normals = try allocator.alloc([2]i8, side * side);
        errdefer allocator.free(normals);
        for (normals, 0..) |*normal, at| normal.* = reliefAt(colours, at);

        return .{ .normals = normals, .colours = colours };
    }

    pub fn deinit(self: *Eye, allocator: std.mem.Allocator) void {
        allocator.free(self.normals);
        allocator.free(self.colours);
    }

    fn colourAt(self: *const Eye, u: f32, v: f32) dvui.Color {
        const x = std.math.clamp(u, 0, 0.999) * side;
        const y = std.math.clamp(v, 0, 0.999) * side;
        return self.colours[@as(usize, @intFromFloat(y)) * side + @as(usize, @intFromFloat(x))];
    }

    fn normalAt(self: *const Eye, u: f32, v: f32) [2]f32 {
        const x = std.math.clamp(u, 0, 0.999) * side;
        const y = std.math.clamp(v, 0, 0.999) * side;
        const found = self.normals[@as(usize, @intFromFloat(y)) * side + @as(usize, @intFromFloat(x))];
        return .{ @as(f32, @floatFromInt(found[0])) / 127, @as(f32, @floatFromInt(found[1])) / 127 };
    }

    /// One corner of the dome: where it sits, what colour the eye is there,
    /// and where on the frame its surface looks.
    pub const Surface = struct {
        pos: dvui.Point.Physical,
        colour: dvui.Color,
        sample: dvui.Point.Physical,
        inside: bool,
    };

    /// The ball's corners, laid out row by row over a square that is clipped to
    /// a disc. The caller maps `sample` through the tunnel and draws it.
    pub fn dome(
        self: *const Eye,
        arena: std.mem.Allocator,
        centre: dvui.Point.Physical,
        radius: f32,
    ) ![]Surface {
        const across = steps + 1;
        const surface = try arena.alloc(Surface, across * across);
        var at: usize = 0;

        for (0..across) |row| {
            for (0..across) |column| {
                const u = @as(f32, @floatFromInt(column)) / steps * 2 - 1;
                const v = @as(f32, @floatFromInt(row)) / steps * 2 - 1;
                const flat = u * u + v * v;
                const inside = flat <= 1;
                const dome_z = if (inside) @sqrt(1 - flat) else 0;

                // Corners outside the silhouette fold onto the rim, so the ball
                // has a round edge without a clip.
                const reach = if (inside) radius else radius * 0.98 / @sqrt(flat);
                const pos = dvui.Point.Physical{ .x = centre.x + u * reach, .y = centre.y + v * reach };

                const picture = imageUV(u, v);
                const colour = if (inside) self.colourAt(picture[0], picture[1]) else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
                const normal = if (inside) self.normalAt(picture[0], picture[1]) else [2]f32{ 0, 0 };

                // Near the rim the ball turns away, so the relief stretches.
                const bend = relief * radius * (1 - dome_z) * 2;
                surface[at] = .{
                    .pos = pos,
                    .colour = colour,
                    .sample = .{ .x = pos.x + normal[0] * bend, .y = pos.y + normal[1] * bend },
                    .inside = inside,
                };
                at += 1;
            }
        }

        return surface;
    }
};

/// How finely the dome is cut. The relief bends the sample, so the grid has to
/// be finer than the iris features to read as a surface.
pub const steps: usize = 72;

/// Where a point on the ball reads from, in the eye's own picture. The ball's
/// front hemisphere maps straight onto the disc.
fn imageUV(u: f32, v: f32) [2]f32 {
    return .{ (u + 1) / 2, (v + 1) / 2 };
}

/// Luminance gradient at a texel, as a tangent-space normal's `xy`. Flat
/// irises come out flat, the striations and the rim come out as relief.
fn reliefAt(colours: []const dvui.Color, at: usize) [2]i8 {
    const x = at % side;
    const y = at / side;
    const left = luma(colours[y * side + (if (x == 0) 0 else x - 1)]);
    const right = luma(colours[y * side + (if (x + 1 >= side) side - 1 else x + 1)]);
    const up = luma(colours[(if (y == 0) 0 else y - 1) * side + x]);
    const down = luma(colours[(if (y + 1 >= side) side - 1 else y + 1) * side + x]);

    return .{ signed(up - down), signed(left - right) };
}

/// Pushes an albedo channel up towards the top of its range: a multiplied
/// picture darkens whatever it covers, and the eye is meant to glow.
fn lift(value: u8) u8 {
    const wide = @as(f32, @floatFromInt(value)) * 1.6 + 24;
    return @intFromFloat(std.math.clamp(wide, 0, 255));
}

fn luma(colour: dvui.Color) f32 {
    return (0.29 * @as(f32, @floatFromInt(colour.r)) +
        0.59 * @as(f32, @floatFromInt(colour.g)) +
        0.11 * @as(f32, @floatFromInt(colour.b))) / 255;
}

fn signed(value: f32) i8 {
    return @intFromFloat(std.math.clamp(value * 2.4, -1, 1) * 127);
}

pub fn quadIndices(arena: std.mem.Allocator) ![]dvui.Vertex.Index {
    const rows = steps;
    const indices = try arena.alloc(dvui.Vertex.Index, rows * rows * 6);
    var at: usize = 0;
    for (0..rows) |row| {
        for (0..rows) |column| {
            const top_left: dvui.Vertex.Index = @intCast(row * (steps + 1) + column);
            const step: dvui.Vertex.Index = @intCast(steps + 1);
            const quad = [_]dvui.Vertex.Index{
                top_left,
                top_left + 1,
                top_left + step,
                top_left + 1,
                top_left + step + 1,
                top_left + step,
            };
            @memcpy(indices[at .. at + quad.len], &quad);
            at += quad.len;
        }
    }
    return indices;
}

test "the eye ships an albedo and a normal for every texel" {
    var eye = try Eye.init(std.testing.allocator);
    defer eye.deinit(std.testing.allocator);

    try std.testing.expectEqual(side * side, eye.colours.len);
    try std.testing.expectEqual(side * side, eye.normals.len);

    // The picture has a dark pupil and a lit iris, so some texel is near black
    // and some is not.
    var darkest: u8 = 255;
    var brightest: u8 = 0;
    for (eye.colours) |colour| {
        darkest = @min(darkest, colour.b);
        brightest = @max(brightest, colour.b);
    }
    try std.testing.expect(brightest > 150);
    try std.testing.expect(darkest * 3 < brightest);
}

test "the dome covers the ball and stays inside it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var eye = try Eye.init(std.testing.allocator);
    defer eye.deinit(std.testing.allocator);

    const frame = dvui.Size.Physical{ .w = 1000, .h = 800 };
    const centre = dvui.Point.Physical{ .x = 500, .y = 400 };
    const radius: f32 = 100;
    const dome = try eye.dome(arena.allocator(), centre, radius);

    try std.testing.expectEqual((steps + 1) * (steps + 1), dome.len);
    var inside_count: usize = 0;
    for (dome) |corner| {
        const dx = corner.pos.x - centre.x;
        const dy = corner.pos.y - centre.y;
        try std.testing.expect(@sqrt(dx * dx + dy * dy) <= radius + 0.01);
        if (corner.inside) inside_count += 1;
    }
    try std.testing.expect(inside_count > dome.len / 2);
    _ = frame;
}
