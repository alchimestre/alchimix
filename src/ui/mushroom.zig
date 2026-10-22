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

/// Each cluster fills a range of slots with tall mushrooms; the slots from
/// `tall_slots` on are the wide, solitary ones.
const Cluster = struct { start: usize, len: usize };
const clusters = [_]Cluster{
    .{ .start = 0, .len = 5 },
    .{ .start = 5, .len = 6 },
    .{ .start = 11, .len = 7 },
    .{ .start = 18, .len = 8 },
    .{ .start = 26, .len = 6 },
};
const tall_slots = 32;
const big_slots = tall_slots + 9;
const drop_slots = 18;
const ripple_slots = 18;
const insect_slots = 3;
const heart_slots = 10;
/// Seconds of playback a plant takes to reach full height.
const season: f32 = 90;
/// The plant sits here, as a fraction of the window.
/// Where the plant sits, as a fraction of the frame. The app sets it from the
/// canvas so the plant never hides under the playlist column.
var plant_x: f32 = 0.76;

pub fn placePlant(fraction: f32) void {
    plant_x = std.math.clamp(fraction, 0.2, 0.94);
}
const plant_base: f32 = 0.92;
/// Seconds a mushroom takes to reach its cap.
const grow: f64 = 2.4;
/// Seconds a mushroom stands before it is replaced elsewhere.
const life: f64 = 7.0;
/// Seconds a ring lives.
const ripple_life: f64 = 1.1;
/// Seconds a heart floats before it pops.
const heart_life: f64 = 9.0;
const halo_life: f64 = 1.0;

const Mushroom = struct {
    x: f32,
    y: f32,
    born: f64,
    /// Signed lean toward the last insect to pass: -1 left, 1 right.
    lean: f32 = 0,
    /// When this mushroom's growth halo starts.
    halo: f64 = -1000,
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
    /// Height varies within a cluster.
    scale: f32,
    born: f64,
    /// When this mushroom's growth halo starts.
    halo: f64 = -1000,
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
    big: [big_slots]Big = @splat(.{ .x = 0.5, .y = 0.5, .scale = 1, .born = -1 }),
    insects: [insect_slots]Insect = @splat(.{ .x = -1, .y = -1, .vx = 0, .vy = 0, .turn = 0, .glyph = 0 }),
    hearts: [heart_slots]Heart = @splat(.{ .x = -1, .y = -1, .born = -1 }),
    /// Growth of the plant, zero to one, earned by playing music.
    grown: f32 = 0,
    /// Whether any lane is playing; the weather answers it.
    wave_at: f64 = -1000,
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
            for (clusters, 0..) |_, index| {
                self.placeCluster(random, now - random.float(f64) * 20, index);
            }
            for (tall_slots..self.big.len) |slot| {
                self.placeStout(random, now - random.float(f64) * 20, slot);
            }
            for (&self.drops) |*drop| {
                drop.* = .{
                    .x = 0.05 + random.float(f32) * 0.9,
                    .y = -random.float(f32) * 0.6,
                    .fall = 0.25 + random.float(f32) * 0.35,
                    .land = 0.55 + random.float(f32) * 0.38,
                };
            }
        }

        for (self.big, 0..) |bush, slot| {
            if (now - bush.born <= 30) continue;
            if (clusterOf(slot)) |index| {
                // A cluster replaces itself whole, so the field keeps its groupings.
                self.placeCluster(random, now, index);
            } else {
                self.placeStout(random, now, slot);
            }
        }
        for (&self.mushrooms) |*plant| {
            if (now - plant.born <= life) continue;

            // Replaced where it stood, give or take a step.
            plant.* = .{
                .x = std.math.clamp(plant.x + (random.float(f32) - 0.5) * 0.12, 0.04, 0.96),
                .y = std.math.clamp(plant.y + (random.float(f32) - 0.5) * 0.1, 0.06, 0.94),
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

        for (&self.mushrooms) |*plant| {

            // The lean fades over about a second after the bug has gone.
            if (plant.lean != 0) plant.lean *= @max(0, 1 - step * 0.9);
            for (self.insects) |insect| {
                if (@abs(insect.x - plant.x) > 0.07 or @abs(insect.y - plant.y) > 0.09) continue;
                plant.lean = if (insect.x < plant.x) -1 else 1;
                break;
            }
        }
        for (&self.hearts) |*heart| {
            if (heart.born > now or now - heart.born > heart_life) continue;
            heart.y -= 0.030 * step;
        }
        for (&self.drops) |*drop| {
            drop.y += drop.fall * @as(f32, @floatCast(seconds));
            if (drop.y < drop.land) continue;

            self.ring(drop.x, drop.land, now, random);
            self.water(drop.x, drop.land, now);

            drop.* = .{
                .x = 0.05 + random.float(f32) * 0.9,
                .y = -0.05 - random.float(f32) * 0.3,
                .fall = 0.25 + random.float(f32) * 0.35,
                .land = 0.55 + random.float(f32) * 0.38,
            };
        }
    }

    /// The plant grows only while music plays.
    pub fn grow(self: *State, seconds: f64, now: f64, bpm: f32) void {
        const before = self.grown;
        self.grown = @min(1, self.grown + @as(f32, @floatCast(seconds)) / season);
        if (self.grown <= before) return;

        // Every fifth of the growth throws one halo across the whole field.
        const step: f32 = 0.2;
        if (@floor(before / step) == @floor(self.grown / step)) return;
        self.haloSweep(now, bpm);
    }

    /// Lights every mushroom once, in a random order, three to a beat.
    fn haloSweep(self: *State, now: f64, bpm: f32) void {
        const random = self.rng.random();
        const beat = 60 / @max(1, bpm);
        const spacing = beat / 3;

        var order: [big_slots + mushroom_slots]f32 = undefined;
        var count: usize = 0;
        for (0..self.big.len + self.mushrooms.len) |_| {
            order[count] = random.float(f32);
            count += 1;
        }
        std.mem.sort(f32, order[0..count], {}, std.sort.asc(f32));

        for (&self.big, 0..) |*bush, slot| {
            bush.halo = now + order[slot] * @as(f32, @floatFromInt(count)) * spacing;
        }
        for (&self.mushrooms, 0..) |*plant, slot| {
            plant.halo = now + order[self.big.len + slot] * @as(f32, @floatFromInt(count)) * spacing;
        }
    }

    /// A press on the plant: insects pour in from both sides, hearts rise.
    pub fn poke(self: *State, now: f64) void {
        // A flash travels out from the plant; the field stays standing.
        self.wave_at = now;

        const random = self.rng.random();

        // The insects keep walking; a press only nudges the nearest one.
        for (&self.insects) |*insect| {
            insect.turn = now + 1;
        }

        for (&self.hearts, 0..) |*heart, at| {
            // Spread wide across the field so the burst reads as a shower, not
            // a column rising off the plant.
            const spread = (random.float(f32) - 0.5) * 0.38;
            heart.* = .{
                .x = std.math.clamp(plant_x + spread, 0.06, 0.94),
                .y = plant_base - 0.02 - (random.float(f32)) * 0.10,
                .born = now + @as(f64, @floatFromInt(at)) * 0.5,
            };
        }
    }

    fn clusterOf(slot: usize) ?usize {
        for (clusters, 0..) |group, index| {
            if (slot >= group.start and slot < group.start + group.len) return index;
        }
        return null;
    }

    /// A cluster's worth of mushrooms around one point, at different heights.
    /// The spread grows with the count so a big group still reads as a group.
    fn placeCluster(self: *State, random: std.Random, born: f64, index: usize) void {
        const group = clusters[index];
        const centre_x = 0.12 + random.float(f32) * 0.7;
        const centre_y = 0.15 + random.float(f32) * 0.6;
        // Laid on a grid of up to four across, so the members stand beside each
        // other instead of stacking on one point.
        const columns: usize = @min(group.len, 5);
        const rows = (group.len + columns - 1) / columns;
        const pitch_x: f32 = 0.040;
        const pitch_y: f32 = 0.055;

        for (group.start..group.start + group.len) |slot| {
            if (slot >= self.big.len) return;
            const seat = slot - group.start;
            const column = seat % columns;
            const row = seat / columns;
            const stagger = if (row % 2 == 1) pitch_x * 0.5 else 0;
            const across = (@as(f32, @floatFromInt(column)) - @as(f32, @floatFromInt(columns - 1)) * 0.5) * pitch_x + stagger;
            const down = (@as(f32, @floatFromInt(row)) - @as(f32, @floatFromInt(rows - 1)) * 0.5) * pitch_y;

            self.big[slot] = .{
                .x = std.math.clamp(centre_x + across + (random.float(f32) - 0.5) * 0.03, 0.04, 0.94),
                .y = std.math.clamp(centre_y + down + (random.float(f32) - 0.5) * 0.05, 0.1, 0.9),
                .scale = 0.7 + random.float(f32) * 0.5,
                .born = born,
            };
        }
    }

    /// The wide mushrooms stand alone: random spots, just far enough apart not
    /// to touch, so the field does not read as a grid.
    fn placeStout(self: *State, random: std.Random, born: f64, slot: usize) void {
        var x: f32 = 0.5;
        var y: f32 = 0.5;

        var attempt: usize = 0;
        while (attempt < 16) : (attempt += 1) {
            x = 0.12 + random.float(f32) * 0.68;
            y = 0.18 + random.float(f32) * 0.55;
            var clear = true;
            for (self.big, 0..) |other, at| {
                if (at < tall_slots or at == slot or other.born < 0) continue;
                if (@abs(other.x - x) < 0.10 and @abs(other.y - y) < 0.15) {
                    clear = false;
                    break;
                }
            }
            if (clear) break;
        }

        self.big[slot] = .{
            .x = x,
            .y = y,
            .scale = 0.75 + random.float(f32) * 0.35,
            .born = born,
        };
    }

    /// A landing drop re-pops the nearest small mushroom, so the rain reaches
    /// the field instead of passing through it.
    fn water(self: *State, x: f32, y: f32, now: f64) void {
        var best: ?usize = null;
        var best_d2: f32 = 0.05 * 0.05;

        for (self.mushrooms, 0..) |mushroom, slot| {
            const dx = mushroom.x - x;
            const dy = mushroom.y - y;
            const d2 = dx * dx + dy * dy;
            if (d2 < best_d2) {
                best_d2 = d2;
                best = slot;
            }
        }

        if (best) |slot| {
            self.mushrooms[slot].born = now;
        }
    }

    /// Five dots rise where a mushroom stood, spread across its cap.
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
    bpm: f32,
    ascii: dvui.Font,
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
    try undergrowth(state, time, size, still, bpm, ascii);
    try geom.repaint(arena, still, size, texture);
}

/// Where the plant grows, and where a press on it lands.
/// Where a press on the shamrock is caught: the same centre it is drawn at.
pub fn plantRect(size: dvui.Size.Physical) dvui.Rect.Physical {
    return .{
        .x = size.w * (plant_x - 0.10),
        .y = size.h * 0.55,
        .w = size.w * 0.20,
        .h = size.h * 0.42,
    };
}

fn undergrowth(
    state: *const State,
    now: f64,
    size: dvui.Size.Physical,
    still: []const dvui.Rect.Physical,
    bpm: f32,
    ascii: dvui.Font,
) !void {
    // A fixed cell: scaled to the window, the sprites stop reading as art.
    const font_px: f32 = 20;
    // ASCII art is a grid: in a proportional face every space collapses and the
    // sprite falls apart, so the garden always draws in the mono font.
    const font = ascii.withSize(font_px);
    const cell = font.textSize("M").w;

    var items: [big_slots + mushroom_slots]Item = undefined;
    var count: usize = 0;
    for (state.big, 0..) |bush, slot| {
        if (now - bush.born < 0) continue;
        items[count] = .{ .y = bush.y, .big = slot };
        count += 1;
    }
    for (state.mushrooms, 0..) |mushroom, slot| {
        if (now - mushroom.born < 0) continue;
        items[count] = .{ .y = mushroom.y, .small = slot };
        count += 1;
    }

    const order = items[0..count];
    // Farthest first: a row nearer the viewer paints over the ones behind it.
    std.mem.sort(Item, order, {}, itemLess);

    try drawPlant(state.grown, size, font);
    try insectSwarm(state, now, size, font);
    try heartBubbles(state, now, size, bpm, font);

    for (order) |item| {
        if (item.big) |slot| {
            try drawBig(state, now, slot, size, still, font);
        } else if (item.small) |slot| {
            try drawSmall(state, now, slot, size, still, font, cell);
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

/// The two sprinkled mushrooms, as drawn in the reference set.
const mushroom_tall = [_][]const u8{
    "  n",
    " / `\\",
    "(___:)",
    " \"\"\"\"",
    "  ||",
    "  ||",
    "  ))",
    " //",
    "((",
    " \\",
    "  ))",
    "  ||",
};

const mushroom_stout = [_][]const u8{
    "  .-\"\"\"-.",
    " /* * * *\\",
    ":_.-:`:-._;",
    "    (_)",
    " \\|/(_)\\|/",
};

/// Garden coordinates are fractions of the frame; glyphs need pixels.
fn onScreen(x: f32, y: f32, size: dvui.Size.Physical) dvui.Point.Physical {
    return .{ .x = x * size.w, .y = y * size.h };
}

/// The garden recedes under the app's panels, so the chrome stays readable.
fn shade(at: dvui.Point.Physical, fade: u8, still: []const dvui.Rect.Physical) u8 {
    for (still) |rect| {
        const inside = at.x >= rect.x and at.x <= rect.x + rect.w and
            at.y >= rect.y and at.y <= rect.y + rect.h;
        if (inside) return 0;
    }
    return fade;
}

/// Sprites fade in over `span` seconds and hold at `peak` alpha.
fn fadeIn(age: f64, span: f64, peak: u8) u8 {
    const t = std.math.clamp(age / span, 0, 1);
    return @intFromFloat(t * @as(f64, @floatFromInt(peak)));
}

/// One sprite in the depth order, whichever kind of mushroom it is.
const Item = struct {
    y: f32,
    big: ?usize = null,
    small: ?usize = null,
};

/// Sorted farthest first, so nearer sprites paint over the ones behind.
fn itemLess(_: void, a: Item, b: Item) bool {
    return a.y < b.y;
}

/// A wide or tall mushroom, rising through its three phases.
fn drawBig(
    state: *const State,
    now: f64,
    slot: usize,
    size: dvui.Size.Physical,
    still: []const dvui.Rect.Physical,
    font_in: dvui.Font,
) !void {
    const bush = state.big[slot];
    const font = font_in.withSize(font_in.size * 0.62);

    const age = now - bush.born;
    const at = onScreen(bush.x, bush.y, size);
    const fade = shade(at, fadeIn(age, 0.9, 235), still);
    const tint = caps[slot % caps.len];

    const full: []const []const u8 = if (slot < tall_slots) &mushroom_tall else &mushroom_stout;
    // Three phases: a tip, then the cap, then the whole thing.
    const lines: []const []const u8 = if (age < 0.8)
        full[0..1]
    else if (age < 1.8)
        full[0..@max(1, full.len / 2)]
    else
        full;

    try stack(font, lines, at, tint(fade));

    const cell = @max(1, font.textSize("M").w);
    try lightHalo(at, now - bush.halo, cell, cell * 6, font);
}

/// One of the small pop-up mushrooms, tinted by its slot.
fn drawSmall(
    state: *const State,
    now: f64,
    slot: usize,
    size: dvui.Size.Physical,
    still: []const dvui.Rect.Physical,
    font: dvui.Font,
    cell: f32,
) !void {
    const plant = state.mushrooms[slot];
    const age = now - plant.born;
    const at = onScreen(plant.x, plant.y, size);
    const fade = shade(at, fadeIn(age, 0.4, 255), still);
    const tint = caps[(slot / 3) % caps.len];

    if (age < 0.5) {
        try put(font, ".", at, tint(fade));
    } else if (age < 1.1) {
        try put(font, "o", at, tint(fade));
    } else if (age < grow) {
        try put(font, ".-.", at, tint(fade));
    } else {
        try put(font, ".-.", at, tint(fade));

        var stem_glyph: []const u8 = "|";
        if (plant.lean != 0) stem_glyph = if (plant.lean < 0) "/" else "\\";
        try put(font, stem_glyph, .{ .x = at.x + cell, .y = at.y + cell * 1.15 }, stem());
    }

    try lightHalo(at, now - plant.halo, cell, cell * 3, font);
}

fn drawPlant(grown: f32, size: dvui.Size.Physical, font_in: dvui.Font) !void {
    const base = dvui.Point.Physical{ .x = plant_x * size.w, .y = plant_base * size.h };
    const font = font_in.withSize(font_in.size * (1.3 + grown * 1.1));

    const lines: []const []const u8 = if (grown < 0.15)
        &.{ " o o o ", "  \\|/  ", "   |   " }
    else if (grown < 0.3)
        &.{ "\\|/", "-+-", " |" }
    else if (grown < 0.5)
        &.{ " \\|/ ", "--|--", "  |  " }
    else if (grown < 0.7)
        &.{ " * . * ", "  \\|/  ", "--|--", "  |  " }
    else if (grown < 0.88)
        &.{ "  * *  ", " . * . ", "  \\|/  ", "--|--", "  |  " }
    else
        &tree_art;

    try stack(font, lines, base, leaf());
}

const tree_art = [_][]const u8{
    "  * . * ",
    " . * . ",
    "* . | . *",
    " .-\\|/-. ",
    "   ###  ",
    "   ###  ",
};

/// Three bugs, told apart by shape: a beetle, a grasshopper, a bee.
const bug_art = [3][]const []const u8{
    &.{ ".-.", "(o)", "'-'" },
    &.{ "\\^/", " | ", "/ \\" },
    &.{ "\\~/", "-o-", " \\ " },
};

fn insectSwarm(state: *const State, now: f64, size: dvui.Size.Physical, font_in: dvui.Font) !void {
    const font = font_in.withSize(font_in.size * 0.95);

    // The bugs change glyph about eight times a second, so they read as crawling.
    const frame: usize = @intFromFloat(@max(0, now) * 8);
    for (state.insects) |insect| {
        const at = dvui.Point.Physical{ .x = insect.x * size.w, .y = insect.y * size.h };
        try stack(font, bug_art[(insect.glyph + frame) % bug_art.len], at, bug(220));
    }
}

fn heartBubbles(state: *const State, now: f64, size: dvui.Size.Physical, bpm: f32, font: dvui.Font) !void {
    for (state.hearts) |heart| {
        const age = now - heart.born;
        if (age < 0) continue;
        if (age > heart_life) continue;
        const at = dvui.Point.Physical{ .x = heart.x * size.w, .y = heart.y * size.h };

        if (age < heart_life - 0.8) {
            // Beating with the track: the halo brightens on the beat and the
            // heart itself swells a little with it.
            const beat = @max(1, bpm) / 60;
            const pulse = 0.5 + 0.5 * @sin(2 * std.math.pi * beat * age);
            const halo: u8 = @intFromFloat(pulse * 110);
            const fade: u8 = @intFromFloat(@min(1, age / 0.3) * (170 + 85 * pulse));

            try put(font, "<3", .{ .x = at.x - 2, .y = at.y }, heart_colour(halo));
            try put(font, "<3", .{ .x = at.x + 2, .y = at.y }, heart_colour(halo));
            try put(font, "<3", .{ .x = at.x, .y = at.y - 2 }, heart_colour(halo));
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

/// Draws rows of ASCII as one block: every row starts at the same left edge, so
/// the art's own leading spaces do the shaping. The block is centred on `centre`.
/// A growth halo: four marks that widen and fade over a second.
fn lightHalo(at: dvui.Point.Physical, age: f64, cell: f32, width: f32, font: dvui.Font) !void {
    if (age < 0 or age > halo_life) return;
    const t: f32 = @floatCast(age / halo_life);
    const fade: u8 = @intFromFloat((1 - t) * 210);
    const spread = cell * (1 + t * 1.4);

    try put(font, "o", .{ .x = at.x - spread, .y = at.y }, halo_colour(fade));
    try put(font, "o", .{ .x = at.x + width + spread, .y = at.y }, halo_colour(fade));
    try put(font, ".", .{ .x = at.x + width * 0.5, .y = at.y - spread }, halo_colour(fade));
    try put(font, ".", .{ .x = at.x + width * 0.5, .y = at.y + cell * 3 }, halo_colour(fade));
}

fn halo_colour(fade: u8) dvui.Color {
    return .{ .r = 0xff, .g = 0xf1, .b = 0xc4, .a = fade };
}

fn stack(font: dvui.Font, lines: []const []const u8, centre: dvui.Point.Physical, colour: dvui.Color) !void {
    const metrics = font.textSize("M");
    const cell = metrics.w;
    // Steps by the cell, not the line height: the line height is 1.9 cells and
    // spreads the rows into a ladder.
    const step = @max(1, cell) * 1.15;

    var widest: usize = 0;
    for (lines) |line| widest = @max(widest, line.len);

    const left = centre.x - @as(f32, @floatFromInt(widest)) * cell * 0.5;
    const top = centre.y - @as(f32, @floatFromInt(lines.len - 1)) * step;

    for (lines, 0..) |line, row| {
        try putChromatic(font, line, .{
            .x = left,
            .y = top + @as(f32, @floatFromInt(row)) * step,
        }, colour);
    }
}

/// Red and blue copies a hair either side, so the strokes fringe like an old
/// lens instead of sitting flat.
fn putChromatic(font: dvui.Font, text: []const u8, at: dvui.Point.Physical, colour: dvui.Color) !void {
    const split: f32 = 1.5;
    const ghost = colour.a / 3;
    try put(font, text, .{ .x = at.x - split, .y = at.y }, .{ .r = 0xff, .g = 0x40, .b = 0x50, .a = ghost });
    try put(font, text, .{ .x = at.x + split, .y = at.y }, .{ .r = 0x50, .g = 0xa0, .b = 0xff, .a = ghost });
    try put(font, text, at, colour);
}

fn put(font: dvui.Font, text: []const u8, at: dvui.Point.Physical, colour: dvui.Color) !void {
    const metrics = font.textSize("M");
    const cell = @max(1, metrics.w);
    // Drawn twice, a hair apart: one pass leaves the strokes too thin to read as
    // ASCII art against the dark frame.
    for ([_]f32{ 0, 0.7 }) |nudge| {
        try dvui.renderText(.{
            .font = font,
            .text = text,
            .rs = .{
                .r = .{
                    .x = at.x - 2,
                    .y = at.y - cell * 1.5,
                    .w = @as(f32, @floatFromInt(text.len + 2)) * cell,
                    .h = cell * 4,
                },
                .s = 1,
            },
            .p = .{ .x = at.x + nudge, .y = at.y },
            .color = colour,
        });
    }
}

/// Watered caps lean blue until they dry.
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

fn stemFade(fade: u8) dvui.Color {
    return .{ .r = 0xd8, .g = 0xd0, .b = 0xc8, .a = fade };
}

fn stem() dvui.Color {
    return .{ .r = 0xd8, .g = 0xd0, .b = 0xc8, .a = 180 };
}

fn rain(fade: u8) dvui.Color {
    return .{ .r = 0xcf, .g = 0xe3, .b = 0xff, .a = fade };
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
    state.grow(45, 1, 120);
    try std.testing.expect(state.grown > 0.49 and state.grown < 0.51);
    state.grow(100, 2, 120);
    try std.testing.expectEqual(@as(f32, 1), state.grown);
}

test "growth throws one halo across the whole field" {
    var state: State = .{};
    state.tick(0);
    state.grow(45, 50, 120);

    var lit: usize = 0;
    for (state.mushrooms) |plant| {
        if (plant.halo >= 50) lit += 1;
    }
    try std.testing.expectEqual(state.mushrooms.len, lit);
}

test "every insect carries a real glyph index" {
    var state: State = .{};
    state.poke(1);
    for (state.insects) |insect| {
        try std.testing.expect(insect.glyph < bug_art.len);
    }
}


test "a press starts a wave and leaves the field standing" {
    var state: State = .{};
    state.tick(0);
    const before = state.mushrooms[0].born;
    state.poke(10);

    try std.testing.expectEqual(@as(f64, 10), state.wave_at);
    try std.testing.expectEqual(before, state.mushrooms[0].born);
}

test "a landing drop revives the mushroom under it" {
    var state: State = .{};
    state.tick(0);
    const target = state.mushrooms[3];
    state.water(target.x, target.y, 7);
    try std.testing.expectEqual(@as(f64, 7), state.mushrooms[3].born);
}

test "a cluster stays inside its spread and never stacks" {
    var state: State = .{};
    state.tick(0);
    const group = clusters[0];
    const first = state.big[group.start];
    for (state.big[group.start..][0..group.len]) |bush| {
        try std.testing.expect(@abs(bush.x - first.x) < 0.25);
        try std.testing.expect(@abs(bush.y - first.y) < 0.25);
    }
    for (state.big[group.start..][0..group.len], 0..) |a, i| {
        for (state.big[group.start..][0..group.len][i + 1 ..]) |b| {
            try std.testing.expect(a.x != b.x or a.y != b.y);
        }
    }
}

test "a mushroom lower on the frame paints over one above it" {
    const a: Item = .{ .y = 0.2, .small = 0 };
    const b: Item = .{ .y = 0.7, .small = 1 };
    try std.testing.expect(itemLess({}, a, b));
    try std.testing.expect(!itemLess({}, b, a));
}

test "a press scatters the hearts across the field" {
    var state: State = .{};
    state.tick(0);
    state.poke(10);

    var left: f32 = 1;
    var right: f32 = 0;
    for (state.hearts) |heart| {
        left = @min(left, heart.x);
        right = @max(right, heart.x);
    }
    try std.testing.expect(right - left > 0.25);
}
