//! Mushroom mode: LSD's drift and shimmer held back, the same colour fringe,
//! no flare, over an ASCII undergrowth. Mushrooms pop and grow across the frame;
//! rain falls from the top and rings where it lands.

const std = @import("std");
const dvui = @import("dvui");
const geom = @import("geom.zig");
const lsd = @import("lsd.zig");

/// Share of LSD's displacement this mode uses.
pub const reach: f32 = 0.45;
/// Wash brightness out of 255. The shimmer should read without moving contrast.
const shimmer: f32 = 18;

const mushroom_slots = 40;
const big_slots = 4;
const drop_slots = 18;
const ripple_slots = 18;
const insect_slots = 14;
const heart_slots = 10;
/// Seconds of playback a plant takes to reach full height.
const season: f32 = 90;
/// The plant sits here, as a fraction of the window.
const plant_x: f32 = 0.075;
const plant_base: f32 = 0.88;
/// Seconds a mushroom takes to reach its cap.
const grow: f64 = 2.4;
/// Seconds a mushroom stands before it is replaced elsewhere.
const life: f64 = 7.0;
/// Seconds a ring lives.
const ripple_life: f64 = 1.1;
/// Seconds a heart floats before it pops.
const heart_life: f64 = 4.2;

const Mushroom = struct {
    x: f32,
    y: f32,
    born: f64,
};

const Drop = struct {
    x: f32,
    y: f32,
    fall: f32,
    land: f32,
};

const Ripple = struct {
    x: f32,
    y: f32,
    born: f64,
};

const Big = struct {
    x: f32,
    y: f32,
    born: f64,
};

const Insect = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    born: f64,
    glyph: u2,
};

const Heart = struct {
    x: f32,
    y: f32,
    born: f64,
};

/// The undergrowth. Positions are fractions of the window, so a resize keeps
/// the same arrangement.
pub const State = struct {
    rng: std.Random.DefaultPrng = .init(0x5eed_1eaf),
    mushrooms: [mushroom_slots]Mushroom = @splat(.{ .x = 0.5, .y = 0.5, .born = -1 }),
    drops: [drop_slots]Drop = @splat(.{ .x = 0.5, .y = -0.2, .fall = 0.4, .land = 0.6 }),
    ripples: [ripple_slots]Ripple = @splat(.{ .x = 0.5, .y = 0.5, .born = -1 }),
    big: [big_slots]Big = @splat(.{ .x = 0.5, .y = 0.5, .born = -1 }),
    insects: [insect_slots]Insect = @splat(.{ .x = -1, .y = -1, .vx = 0, .vy = 0, .born = -1, .glyph = 0 }),
    hearts: [heart_slots]Heart = @splat(.{ .x = -1, .y = -1, .born = -1 }),
    /// Growth of the plant, zero to one, earned by playing music.
    grown: f32 = 0,
    seeded: bool = false,

    /// Spawns, lands and retires. `now` is effect seconds.
    pub fn tick(self: *State, now: f64) void {
        const random = self.rng.random();

        if (!self.seeded) {
            self.seeded = true;
            for (&self.mushrooms) |*plant| {
                plant.* = .{
                    .x = 0.04 + random.float(f32) * 0.92,
                    .y = 0.08 + random.float(f32) * 0.84,
                    // Staggered, so they do not all pop at once.
                    .born = now - random.float(f64) * life,
                };
            }
            for (&self.big) |*bush| {
                bush.* = .{
                    .x = 0.1 + random.float(f32) * 0.8,
                    .y = 0.12 + random.float(f32) * 0.72,
                    .born = now - random.float(f64) * 20,
                };
            }
            for (&self.drops) |*drop| {
                drop.* = .{
                    .x = 0.05 + random.float(f32) * 0.9,
                    .y = -random.float(f32) * 0.6,
                    .fall = 0.25 + random.float(f32) * 0.35,
                    .land = 0.2 + random.float(f32) * 0.75,
                };
            }
        }

        for (&self.big) |*bush| {
            if (now - bush.born <= 30) continue;
            bush.* = .{
                .x = 0.1 + random.float(f32) * 0.8,
                .y = 0.12 + random.float(f32) * 0.72,
                .born = now,
            };
        }
        for (&self.mushrooms) |*plant| {
            if (now - plant.born <= life) continue;
            plant.* = .{
                .x = 0.04 + random.float(f32) * 0.92,
                .y = 0.08 + random.float(f32) * 0.84,
                .born = now,
            };
        }
    }

    /// Moves the rain by `seconds` and rings where it lands.
    pub fn fall(self: *State, seconds: f64, now: f64) void {
        const random = self.rng.random();
        const step: f32 = @floatCast(seconds);

        for (&self.insects) |*insect| {
            if (now - insect.born > 2.6) continue;
            insect.x += insect.vx * step;
            insect.y += insect.vy * step;
        }
        for (&self.hearts) |*heart| {
            if (heart.born > now or now - heart.born > heart_life) continue;
            heart.y -= 0.035 * step;
        }
        for (&self.drops) |*drop| {
            drop.y += drop.fall * @as(f32, @floatCast(seconds));
            if (drop.y < drop.land) continue;

            self.ring(drop.x, drop.land, now, random);
            drop.* = .{
                .x = 0.05 + random.float(f32) * 0.9,
                .y = -0.05 - random.float(f32) * 0.3,
                .fall = 0.25 + random.float(f32) * 0.35,
                .land = 0.2 + random.float(f32) * 0.75,
            };
        }
    }

    /// The plant grows only while music plays.
    pub fn grow(self: *State, seconds: f64) void {
        self.grown = @min(1, self.grown + @as(f32, @floatCast(seconds)) / season);
    }

    /// A press on the plant: insects pour in from both sides, hearts rise.
    pub fn poke(self: *State, now: f64) void {
        const random = self.rng.random();

        for (&self.insects, 0..) |*insect, at| {
            const from_left = at % 2 == 0;
            insect.* = .{
                .x = if (from_left) -0.02 else 1.02,
                .y = plant_base + random.float(f32) * 0.14 - 0.07,
                .vx = if (from_left) 0.12 + random.float(f32) * 0.1 else -(0.12 + random.float(f32) * 0.1),
                .vy = (random.float(f32) - 0.5) * 0.05,
                .born = now,
                .glyph = @intCast(at % bug_art.len),
            };
        }

        for (&self.hearts, 0..) |*heart, at| {
            heart.* = .{
                .x = plant_x + (random.float(f32) - 0.5) * 0.16,
                .y = plant_base - 0.02 - @as(f32, @floatFromInt(at)) * 0.02,
                .born = now + @as(f64, @floatFromInt(at)) * 0.35,
            };
        }
    }

    fn ring(self: *State, x: f32, y: f32, now: f64, random: std.Random) void {
        var slot = &self.ripples[0];
        for (&self.ripples) |*candidate| {
            if (now - candidate.born > ripple_life) {
                slot = candidate;
                break;
            }
            if (candidate.born < slot.born) slot = candidate;
        }
        slot.* = .{ .x = x, .y = y, .born = now };
        _ = random;
    }
};

/// The frame through the gentle drift, under the undergrowth.
pub fn draw(
    texture: dvui.Texture,
    arena: std.mem.Allocator,
    state: *const State,
    time: f64,
    size: dvui.Size.Physical,
    still: []const dvui.Rect.Physical,
    emoji: ?dvui.Font,
) !void {
    if (size.w <= 0 or size.h <= 0) return;
    const bounds = dvui.Rect.Physical{ .x = 0, .y = 0, .w = size.w, .h = size.h };

    for ([_]lsd.Channel{ .red, .green, .blue }) |channel| {
        const grid = try lsd.mesh(arena, time, size, still, channel, reach);
        try dvui.renderTriangles(.{
            .vertexes = grid.vertexes,
            .indices = grid.indices,
            .bounds = bounds,
        }, texture);
    }

    try dvui.renderTriangles(try lsd.wash(arena, time, size, shimmer), null);
    try undergrowth(state, time, size, emoji);
    try geom.repaint(arena, still, size, texture);
}

/// Where the plant grows, and where a press on it lands.
pub fn plantRect(size: dvui.Size.Physical) dvui.Rect.Physical {
    return .{
        .x = 0,
        .y = size.h * 0.64,
        .w = size.w * 0.17,
        .h = size.h * 0.32,
    };
}

fn undergrowth(state: *const State, now: f64, size: dvui.Size.Physical, emoji: ?dvui.Font) !void {
    const font_px = @max(10, @min(size.h, size.w) * 0.013);
    const font = dvui.themeGet().font_body.withSize(font_px);
    // Monospaced: one glyph is one cell, so the stem lines up under the cap.
    const cell = font.textSize("M").w;

    try bigMushrooms(state, now, size, font, emoji);
    try drawPlant(state.grown, size, font, emoji);
    try insectSwarm(state, now, size, font, emoji);
    try heartBubbles(state, now, size, font, emoji);

    for (state.mushrooms) |plant| {
        const age = now - plant.born;
        if (age < 0) continue;
        const at = dvui.Point.Physical{ .x = plant.x * size.w, .y = plant.y * size.h };
        const fade: u8 = @intFromFloat(@min(1, age / 0.4) * 255);

        if (age < 0.5) {
            try put(font, ".", at, pink(fade));
        } else if (age < 1.1) {
            try put(font, "o", at, pink(fade));
        } else if (age < grow) {
            try put(font, ".-.", at, pink(fade));
        } else {
            try put(font, ".-.", at, pink(fade));
            try put(font, "|", .{ .x = at.x + cell, .y = at.y + font_px * 1.05 }, stem());
        }
    }

    for (state.drops) |drop| {
        const at = dvui.Point.Physical{ .x = drop.x * size.w, .y = drop.y * size.h };
        // A two glyph streak, so the fall reads at a glance.
        try put(font, "'", .{ .x = at.x, .y = at.y - font_px }, rain(90));
        try put(font, "|", at, rain(200));
    }

    for (state.ripples) |ring| {
        const age = now - ring.born;
        if (age < 0) continue;
        if (age > ripple_life) continue;
        const radius = 6 + @as(f32, @floatCast(age)) * 38;
        const fade: u8 = @intFromFloat((1 - age / ripple_life) * 210);
        try ripple(ring, radius, size, font, fade);
    }
}

fn bigMushrooms(state: *const State, now: f64, size: dvui.Size.Physical, font_in: dvui.Font, emoji: ?dvui.Font) !void {
    const font = font_in.withSize(font_in.size * 1.7);
    const art = if (emoji != null) emoji.?.withSize(font_in.size * 3.2) else font;

    for (state.big) |bush| {
        const age = now - bush.born;
        if (age < 0) continue;
        const at = dvui.Point.Physical{ .x = bush.x * size.w, .y = bush.y * size.h };
        const fade: u8 = @intFromFloat(@min(1, age / 0.6) * 235);

        if (emoji != null) {
            // The emoji is the mushroom people know: round cap, white spots.
            const size_px = art.size * (0.6 + @min(1, @as(f32, @floatCast(age / 2.4))) * 0.4);
            try put(art.withSize(size_px), "🍄", at, pink(fade));
            continue;
        }

        // A rounded cap with spots, then a stalk: read at a glance as a mushroom.
        const lines: []const []const u8 = if (age < 1.2)
            &.{"o"}
        else if (age < 2.4)
            &.{ ".-.", "(o)" }
        else
            &.{ " .---. ", "/ o o \\", "(o o o)", " \\___/ ", "   ||  " };

        try stack(font, lines, at, pink(fade));
    }
}

/// The plant: a sprout from the first moment, ending as a tree.
/// The glyph and size a plant shows at this growth.
pub const PlantArt = struct {
    glyph: []const u8,
    px: f32,
};

pub fn plantArt(grown: f32, base_px: f32) PlantArt {
    const glyph: []const u8 = if (grown < 0.4) "🌱" else if (grown < 0.8) "🌿" else "🌳";
    return .{ .glyph = glyph, .px = base_px * (0.9 + grown * 2.6) };
}

fn drawPlant(grown: f32, size: dvui.Size.Physical, font_in: dvui.Font, emoji: ?dvui.Font) !void {
    if (emoji) |font| {
        const base = dvui.Point.Physical{ .x = plant_x * size.w, .y = plant_base * size.h };
        const art = plantArt(grown, font.size);
        try put(font.withSize(art.px), art.glyph, .{ .x = base.x - art.px * 0.5, .y = base.y - art.px * 0.9 }, leaf());
        return;
    }

    const base = dvui.Point.Physical{ .x = plant_x * size.w, .y = plant_base * size.h };
    const font = font_in.withSize(font_in.size * (1 + grown * 0.8));

    const lines: []const []const u8 = if (grown < 0.05)
        &.{"Y"}
    else if (grown < 0.15)
        &.{ "\\|/", " |" }
    else if (grown < 0.3)
        &.{ "\\|/", "-+-", " |" }
    else if (grown < 0.5)
        &.{ " \\|/ ", "--|--", "  |  " }
    else if (grown < 0.75)
        &.{ "  _  ", " / \\ ", "|   |", " \\_/ ", "  |  ", "  |  " }
    else
        &.{ "   ___   ", "  /   \\  ", " / o o \\ ", "| o   o |", " \\  o  / ", "  \\___/  ", "    ||   ", "    ||   " };

    try stack(font, lines, base, leaf());
}

/// Three bugs, told apart by shape: a beetle, a grasshopper, a bee.
const bug_art = [3][]const []const u8{
    &.{ ".-.", "(o)", "'-'" },
    &.{ "\\^/", " | ", "/ \\" },
    &.{ "\\~/", "-o-", " \\ " },
};

fn insectSwarm(state: *const State, now: f64, size: dvui.Size.Physical, font_in: dvui.Font, emoji: ?dvui.Font) !void {
    const font = font_in.withSize(font_in.size * 0.95);
    const marks = [_][]const u8{ "🐞", "🦗", "🐝" };

    for (state.insects) |insect| {
        const age = now - insect.born;
        if (age < 0) continue;
        if (age > 2.6) continue;
        const fade: u8 = @intFromFloat((1 - age / 2.6) * 235);
        const at = dvui.Point.Physical{ .x = insect.x * size.w, .y = insect.y * size.h };

        if (emoji) |glyph_font| {
            try put(glyph_font.withSize(font_in.size * 1.5), marks[insect.glyph], at, bug(fade));
        } else {
            try stack(font, bug_art[insect.glyph], at, bug(fade));
        }
    }
}

fn heartBubbles(state: *const State, now: f64, size: dvui.Size.Physical, font: dvui.Font, emoji: ?dvui.Font) !void {
    for (state.hearts) |heart| {
        const age = now - heart.born;
        if (age < 0) continue;
        if (age > heart_life) continue;
        const at = dvui.Point.Physical{ .x = heart.x * size.w, .y = heart.y * size.h };

        if (age < heart_life - 0.8) {
            const fade: u8 = @intFromFloat(@min(1, age / 0.3) * 235);
            if (emoji) |glyph_font| {
                try put(glyph_font.withSize(font.size * 1.2), "❤", at, heart_colour(fade));
            } else {
                try put(font, "<3", at, heart_colour(fade));
            }
        } else {
            // The bubble pops: a ring of rings that fades as it widens.
            const burst: f32 = @floatCast((age - (heart_life - 0.8)) / 0.8);
            const fade: u8 = @intFromFloat((1 - burst) * 200);
            try put(font, "o", .{ .x = at.x - font.size * burst * 1.5, .y = at.y }, heart_colour(fade));
            try put(font, "o", .{ .x = at.x + font.size * burst * 1.5, .y = at.y }, heart_colour(fade));
            try put(font, "O", .{ .x = at.x, .y = at.y - font.size * burst * 1.2 }, heart_colour(fade));
        }
    }
}

/// A ring of ASCII: dashes at the sides, bars top and bottom, slashes between.
fn ripple(ring: Ripple, radius: f32, size: dvui.Size.Physical, font: dvui.Font, fade: u8) !void {
    const centre = dvui.Point.Physical{ .x = ring.x * size.w, .y = ring.y * size.h };
    // Sides bracket, top and bottom dot, diagonals trail: the ring of a drop.
    const marks = [_][]const u8{ "(", "'", ".", "`", ")", ",", "'", "`" };
    for (0..8) |step| {
        const angle = @as(f32, @floatFromInt(step)) * std.math.pi / 4;
        const at = dvui.Point.Physical{
            .x = centre.x + @cos(angle) * radius,
            .y = centre.y + @sin(angle) * radius * 0.6,
        };
        try put(font, marks[step % marks.len], at, water(fade));
    }
}

/// Draws rows of ASCII centred on `centre`, stacked upward from the last row.
fn stack(font: dvui.Font, lines: []const []const u8, centre: dvui.Point.Physical, colour: dvui.Color) !void {
    const cell = font.textSize("M").w;
    const step = font.size * 1.05;
    const top = centre.y - @as(f32, @floatFromInt(lines.len - 1)) * step;

    for (lines, 0..) |line, row| {
        const width = @as(f32, @floatFromInt(line.len)) * cell;
        try put(font, line, .{
            .x = centre.x - width / 2,
            .y = top + @as(f32, @floatFromInt(row)) * step,
        }, colour);
    }
}

fn put(font: dvui.Font, text: []const u8, at: dvui.Point.Physical, colour: dvui.Color) !void {
    try dvui.renderText(.{
        .font = font,
        .text = text,
        .rs = .{
            .r = .{ .x = at.x - 2, .y = at.y - 2, .w = font.size * 4, .h = font.size * 3 },
            .s = 1,
        },
        .p = at,
        .color = colour,
    });
}

fn pink(fade: u8) dvui.Color {
    return .{ .r = 0xf3, .g = 0x8b, .b = 0xa8, .a = fade };
}

fn stem() dvui.Color {
    return .{ .r = 0xd8, .g = 0xd0, .b = 0xc8, .a = 180 };
}

fn rain(fade: u8) dvui.Color {
    return .{ .r = 0x89, .g = 0xb4, .b = 0xfa, .a = fade };
}

fn leaf() dvui.Color {
    return .{ .r = 0x8b, .g = 0xe9, .b = 0xa0, .a = 235 };
}

fn bug(fade: u8) dvui.Color {
    return .{ .r = 0xf9, .g = 0xe2, .b = 0xaf, .a = fade };
}

fn heart_colour(fade: u8) dvui.Color {
    return .{ .r = 0xff, .g = 0x5c, .b = 0x6c, .a = fade };
}

fn water(fade: u8) dvui.Color {
    return .{ .r = 0x89, .g = 0xd8, .b = 0xe8, .a = fade };
}

test "mushrooms pop, grow, and are replaced" {
    var state: State = .{};
    state.tick(0);
    try std.testing.expect(state.seeded);

    // Seeded mushrooms start staggered, so at least one is already grown.
    var grown: usize = 0;
    for (state.mushrooms) |plant| {
        if (0 - plant.born >= grow) grown += 1;
    }
    try std.testing.expect(grown > 0);

    // Long after every lifetime, all sixteen have respawned near the new time.
    state.tick(life * 2);

    for (state.mushrooms) |plant| {
        try std.testing.expect(plant.born > 0);
    }
}

test "rain lands and rings where it lands" {
    var state: State = .{};
    state.tick(0);
    for (&state.drops) |*drop| {
        drop.* = .{ .x = 0.5, .y = 0.1, .fall = 1, .land = 0.2 };
    }

    state.fall(0.05, 1.0);
    try std.testing.expectEqual(@as(u8, 0), 0);

    state.fall(0.2, 1.2);
    var rings: usize = 0;
    for (state.ripples) |ring| {
        if (ring.born > 0) rings += 1;
    }
    try std.testing.expect(rings == state.drops.len);

    // Every drop restarted above the frame.
    for (state.drops) |drop| {
        try std.testing.expect(drop.y < 0);
    }
}

test "a press on the plant wakes insects and hearts" {
    var state: State = .{};
    state.poke(10);

    var left: usize = 0;
    var right: usize = 0;
    for (state.insects) |insect| {
        if (insect.x < 0) left += 1;
        if (insect.x > 1) right += 1;
    }
    try std.testing.expect(left > 0);
    try std.testing.expect(right > 0);

    for (state.hearts) |heart| try std.testing.expect(heart.born >= 10);
}

test "the plant grows with playing time and stops at full" {
    var state: State = .{};
    state.grow(45);
    try std.testing.expect(state.grown > 0.49 and state.grown < 0.51);
    state.grow(100);
    try std.testing.expectEqual(@as(f32, 1), state.grown);
}

test "the plant picks a glyph and grows with its age" {
    try std.testing.expectEqualStrings("🌱", plantArt(0, 24).glyph);
    try std.testing.expectEqualStrings("🌿", plantArt(0.5, 24).glyph);
    try std.testing.expectEqualStrings("🌳", plantArt(0.9, 24).glyph);
    try std.testing.expect(plantArt(0.9, 24).px > plantArt(0, 24).px * 2);
}

test "every insect carries a real glyph index" {
    var state: State = .{};
    state.poke(1);
    for (state.insects) |insect| {
        try std.testing.expect(insect.glyph < bug_art.len);
    }
}
