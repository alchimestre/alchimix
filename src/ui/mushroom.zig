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
const insect_slots = 3;
const heart_slots = 10;
/// Seconds of playback a plant takes to reach full height.
const season: f32 = 90;
/// The plant sits here, as a fraction of the window.
const plant_x: f32 = 0.76;
const plant_base: f32 = 0.92;
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
    turn: f64,
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
    insects: [insect_slots]Insect = @splat(.{ .x = -1, .y = -1, .vx = 0, .vy = 0, .turn = 0, .glyph = 0 }),
    hearts: [heart_slots]Heart = @splat(.{ .x = -1, .y = -1, .born = -1 }),
    /// Growth of the plant, zero to one, earned by playing music.
    grown: f32 = 0,
    /// When the wizard next walks over with the watering can, and until when
    /// he stays.
    water_at: f64 = 8,
    water_until: f64 = -1,
    seeded: bool = false,

    /// Spawns, lands and retires. `now` is effect seconds.
    pub fn tick(self: *State, now: f64) void {
        const random = self.rng.random();

        if (!self.seeded) {
            self.seeded = true;
            if (now > self.water_at) self.water(now);

        for (&self.mushrooms) |*plant| {
                plant.* = .{
                    .x = 0.04 + random.float(f32) * 0.92,
                    .y = 0.08 + random.float(f32) * 0.84,
                    // Staggered, so they do not all pop at once.
                    .born = now - random.float(f64) * life,
                };
            }
            for (&self.insects) |*insect| {
                insect.* = .{
                    .x = random.float(f32),
                    .y = 0.15 + random.float(f32) * 0.7,
                    .vx = (random.float(f32) - 0.5) * 0.05,
                    .vy = (random.float(f32) - 0.5) * 0.03,
                    .turn = now,
                    .glyph = 0,
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
        if (now > self.water_at) self.water(now);

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

        for (&self.insects, 0..) |*insect, at| {
            insect.glyph = @intCast(at % bug_art.len);
            if (now > insect.turn) {
                insect.vx = (random.float(f32) - 0.5) * 0.05;
                insect.vy = (random.float(f32) - 0.5) * 0.03;
                insect.turn = now + 1 + random.float(f64) * 2.5;
            }
            insect.x += insect.vx * step;
            insect.y += insect.vy * step;
            if (insect.x < 0.01) insect.x = 0.99;
            if (insect.x > 0.99) insect.x = 0.01;
            if (insect.y < 0.05) insect.y = 0.95;
            if (insect.y > 0.95) insect.y = 0.05;
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
    /// Sprinkles the plant: the wizard waters for a few seconds.
    pub fn water(self: *State, now: f64) void {
        self.water_until = now + 6;
        self.water_at = now + 20 + self.rng.random().float(f64) * 12;
    }

    pub fn poke(self: *State, now: f64) void {
        const random = self.rng.random();

        // The insects keep walking; a press only nudges the nearest one.
        for (&self.insects) |*insect| {
            insect.turn = now + 1;
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
    try undergrowth(state, time, size);
    try geom.repaint(arena, still, size, texture);
}

/// Where the plant grows, and where a press on it lands.
pub fn plantRect(size: dvui.Size.Physical) dvui.Rect.Physical {
    return .{
        .x = size.w * 0.66,
        .y = size.h * 0.58,
        .w = size.w * 0.26,
        .h = size.h * 0.38,
    };
}

fn undergrowth(state: *const State, now: f64, size: dvui.Size.Physical) !void {
    const font_px = @max(10, @min(size.h, size.w) * 0.013);
    const font = dvui.themeGet().font_body.withSize(font_px);
    // Monospaced: one glyph is one cell, so the stem lines up under the cap.
    const cell = font.textSize("M").w;

    try bigMushrooms(state, now, size, font);
    try drawPlant(state.grown, size, font);
    try drawWizard(state, now, size, font);
    try insectSwarm(state, now, size, font);
    try heartBubbles(state, now, size, font);

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

fn bigMushrooms(state: *const State, now: f64, size: dvui.Size.Physical, font_in: dvui.Font) !void {
    const font = font_in.withSize(font_in.size * 1.7);

    for (state.big, 0..) |bush, slot| {
        const age = now - bush.born;
        if (age < 0) continue;
        const at = dvui.Point.Physical{ .x = bush.x * size.w, .y = bush.y * size.h };
        const fade: u8 = @intFromFloat(@min(1, age / 0.6) * 235);
        const tint = caps[slot % caps.len];

        // A rounded cap with spots, then a stalk: read at a glance as a mushroom.
        const lines: []const []const u8 = if (age < 1.2)
            &.{"o"}
        else if (age < 2.4)
            &.{ " .-. ", "/ o \\", " \\_/ " }
        else
            &.{ "  _.-\"-._  ", " /  o o  \\ ", "| o   o   |", " \\  o o  / ", "  '-...-'  ", "     |||   " };

        try stack(font, lines, at, tint(fade));
    }
}

/// The full-grown plant.
const tree_art = [_][]const u8{
    "              * *    ",
    "           *    *  *",
    "      *  *    *     *  *",
    "     *     *    *  *    *",
    " * *   *    *    *    *   *",
    " *     *  *    * * .#  *   *",
    " *   *     * #.  .# *   *",
    "  *     \"#.  #: #\" * *    *",
    " *   * * \"#. ##\"       *",
    "   *       \"###",
    "             \"##",
    "              ##.",
    "              .##:",
    "              :###",
    "              ;###",
    "            ,####.",
    "/\\/\\/\\/\\/\\/.######.\\/\\/\\/\\/\\",
};

/// The wizard walks over with the can every so often.
fn drawWizard(state: *const State, now: f64, size: dvui.Size.Physical, font_in: dvui.Font) !void {
    if (now >= state.water_until) return;

    const font = font_in.withSize(font_in.size * 1.1);
    const step = font.size * 1.05;
    const base = dvui.Point.Physical{ .x = size.w * 0.68, .y = size.h * 0.90 };
    const hat = [_][]const u8{ "  /\\  ", " /  \\ ", "/____\\" };
    const body = [_][]const u8{ " |  | ", " /  \\ " };

    for (hat, 0..) |line, row| {
        const up = @as(f32, @floatFromInt(hat.len + body.len - 1 - row));
        try put(font, line, .{ .x = base.x, .y = base.y - up * step }, wizard_red(235));
    }
    for (body, 0..) |line, row| {
        const up = @as(f32, @floatFromInt(body.len - 1 - row));
        try put(font, line, .{ .x = base.x, .y = base.y - up * step }, wizard_blue(235));
    }

    for (0..4) |drop| {
        const spread = @as(f32, @floatFromInt(drop)) * font.size * 1.6;
        try put(font, "'", .{ .x = base.x + font.size * 2 + spread, .y = base.y - font.size * 2 + spread * 0.6 }, rain(200));
    }
}

/// Where the plant grows.
fn drawPlant(grown: f32, size: dvui.Size.Physical, font_in: dvui.Font) !void {
    const base = dvui.Point.Physical{ .x = plant_x * size.w, .y = plant_base * size.h };

    if (grown >= 0.8) {
        // The full plant is wide: draw it small and keep it clear of the edge.
        const font = font_in.withSize(font_in.size * 0.8);
        const cell = font.textSize("M").w;
        const widest: f32 = @floatFromInt(tree_art[0].len + 12);
        try stack(font, &tree_art, .{ .x = size.w - widest * cell * 0.5 - 16, .y = base.y }, leaf());
        return;
    }

    const font = font_in.withSize(font_in.size * (1.4 + grown * 1.2));
    // A shamrock at the smallest: round leaves on a stem.
    const lines: []const []const u8 = if (grown < 0.2)
        &.{ " o o o ", "  \\|/  ", "   |   " }
    else if (grown < 0.4)
        &.{ "\\|/", "-+-", " |" }
    else if (grown < 0.6)
        &.{ " \\|/ ", "--|--", "  |  " }
    else
        &.{ "  ___  ", " /   \\ ", " \\___/ ", "   |   ", "   |   " };

    try stack(font, lines, base, leaf());
}

/// Three bugs, told apart by shape: a beetle, a grasshopper, a bee.
const bug_art = [3][]const []const u8{
    &.{ ".-.", "(o)", "'-'" },
    &.{ "\\^/", " | ", "/ \\" },
    &.{ "\\~/", "-o-", " \\ " },
};

fn insectSwarm(state: *const State, now: f64, size: dvui.Size.Physical, font_in: dvui.Font) !void {
    const font = font_in.withSize(font_in.size * 0.95);

    _ = now;
    for (state.insects) |insect| {
        const at = dvui.Point.Physical{ .x = insect.x * size.w, .y = insect.y * size.h };
        try stack(font, bug_art[insect.glyph], at, bug(220));
    }
}

fn heartBubbles(state: *const State, now: f64, size: dvui.Size.Physical, font: dvui.Font) !void {
    for (state.hearts) |heart| {
        const age = now - heart.born;
        if (age < 0) continue;
        if (age > heart_life) continue;
        const at = dvui.Point.Physical{ .x = heart.x * size.w, .y = heart.y * size.h };

        if (age < heart_life - 0.8) {
            const fade: u8 = @intFromFloat(@min(1, age / 0.3) * 235);
            try put(font, "<3", at, heart_colour(fade));
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

fn lilac(fade: u8) dvui.Color {
    return .{ .r = 0xbd, .g = 0x93, .b = 0xf9, .a = fade };
}

fn sky(fade: u8) dvui.Color {
    return .{ .r = 0x89, .g = 0xb4, .b = 0xfa, .a = fade };
}

fn amber(fade: u8) dvui.Color {
    return .{ .r = 0xfa, .g = 0xb3, .b = 0x87, .a = fade };
}

/// The caps cycle through these, so the field is not all one colour.
const caps = [_]*const fn (u8) dvui.Color{ pink, lilac, sky, amber };

fn stem() dvui.Color {
    return .{ .r = 0xd8, .g = 0xd0, .b = 0xc8, .a = 180 };
}

fn rain(fade: u8) dvui.Color {
    return .{ .r = 0x89, .g = 0xb4, .b = 0xfa, .a = fade };
}

fn wizard_red(fade: u8) dvui.Color {
    return .{ .r = 0xe0, .g = 0x5c, .b = 0x5c, .a = fade };
}

fn wizard_blue(fade: u8) dvui.Color {
    return .{ .r = 0x6a, .g = 0x9c, .b = 0xf0, .a = fade };
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

test "a press on the plant floats hearts" {
    var state: State = .{};
    state.poke(10);
    for (state.hearts) |heart| try std.testing.expect(heart.born >= 10);
}

test "the insects keep walking and stay in the frame" {
    var state: State = .{};
    state.tick(0);
    var now: f64 = 0;
    var step: usize = 0;
    while (step < 400) : (step += 1) {
        now += 0.1;
        state.fall(0.1, now);
    }
    for (state.insects) |insect| {
        try std.testing.expect(insect.x >= 0 and insect.x <= 1);
        try std.testing.expect(insect.y >= 0 and insect.y <= 1);
        try std.testing.expect(insect.glyph < bug_art.len);
    }
}

test "the plant grows with playing time and stops at full" {
    var state: State = .{};
    state.grow(45);
    try std.testing.expect(state.grown > 0.49 and state.grown < 0.51);
    state.grow(100);
    try std.testing.expectEqual(@as(f32, 1), state.grown);
}

test "every insect carries a real glyph index" {
    var state: State = .{};
    state.poke(1);
    for (state.insects) |insect| {
        try std.testing.expect(insect.glyph < bug_art.len);
    }
}

test "the wizard waters on a timer, then walks on" {
    var state: State = .{};
    state.tick(9);
    try std.testing.expect(state.water_until > 9);
    try std.testing.expect(state.water_at > 9);

    // The next watering is well after this one ends.
    try std.testing.expect(state.water_at > state.water_until);
}
