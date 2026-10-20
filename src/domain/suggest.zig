//! Ranks the tracks that could sit next to a seed.

const std = @import("std");
const camelot = @import("camelot.zig");
const bpm = @import("bpm.zig");
const track = @import("track.zig");
const crate = @import("crate.zig");

const Track = track.Track;

pub const Candidate = struct {
    track: Track,
    transition: crate.Transition,
    /// The worst pair against the seeds. Lower is a closer match.
    rank: u32,
    /// Sum of the per-seed ranks, used to break ties on `rank`.
    total: u32,
};

pub const Options = struct {
    tolerance_bpm: f64 = crate.Crate.tolerance_bpm,
    /// When set, each seed gets this percentage of its own BPM instead.
    tolerance_percent: ?f64 = null,
    /// Keep only pairs whose keys agree.
    harmonic_only: bool = true,
};

/// Tracks playable after `seed`, best first. Without a seed key every track is
/// judged on tempo alone.
pub fn rank(
    allocator: std.mem.Allocator,
    seed: Track,
    pool: []const Track,
    options: Options,
) ![]Candidate {
    const seeds = [_]Track{seed};
    return rankFor(allocator, &seeds, pool, options);
}

/// Tracks playable after every seed, best first. A candidate must pass each
/// seed's tempo window and, when `harmonic_only`, its key relation.
pub fn rankFor(
    allocator: std.mem.Allocator,
    seeds: []const Track,
    pool: []const Track,
    options: Options,
) ![]Candidate {
    var out: std.ArrayListUnmanaged(Candidate) = .empty;
    errdefer out.deinit(allocator);

    for (pool) |t| {
        var worst: ?Match = null;
        var total: u32 = 0;
        var skip = false;
        for (seeds) |seed| {
            if (t.id == seed.id) {
                skip = true;
                break;
            }
            const pair = pairScore(seed, t, options) orelse {
                skip = true;
                break;
            };
            total += pair.rank;
            if (worst == null or pair.rank > worst.?.rank) worst = pair;
        }
        if (skip) continue;
        const best = worst orelse continue;

        try out.append(allocator, .{
            .track = t,
            .transition = best.transition,
            .rank = best.rank,
            .total = total,
        });
    }

    std.mem.sort(Candidate, out.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            if (a.rank != b.rank) return a.rank < b.rank;
            return a.total < b.total;
        }
    }.lessThan);

    return out.toOwnedSlice(allocator);
}

const Match = struct {
    rank: u32,
    transition: crate.Transition,
};

fn pairScore(seed: Track, candidate: Track, options: Options) ?Match {
    const tolerance = if (options.tolerance_percent) |percent|
        seed.bpm * percent / 100
    else
        options.tolerance_bpm;

    const m = bpm.match(seed.bpm_centi, candidate.bpm_centi);
    if (@abs(m.delta_bpm) > tolerance) return null;

    var tr = crate.Transition{
        .bpm_delta = m.delta_bpm,
        .bpm_direction = bpm.direction(seed.bpm_centi, candidate.bpm_centi, 0.5),
        .stretch = m.stretch,
    };

    var tier: u32 = 0;
    if (seed.key) |sk| {
        if (candidate.key) |tk| {
            const rel = camelot.relation(sk, tk);
            tr.key = rel;
            tr.key_known = true;
            if (!rel.harmonic and options.harmonic_only) return null;
            tier = switch (rel.strength) {
                .none => if (sk.number == tk.number and sk.mode == tk.mode) 0 else 1,
                .slight => 2,
                .strong => 3,
                .big => 4,
            };
        } else if (options.harmonic_only) {
            return null;
        }
    }

    // Tempo first, in whole-BPM bands, then the harmonic step inside the
    // band. Ranking by the step first fills the list with one key and the
    // direction never shows.
    const band: u32 = @intFromFloat(@round(@abs(m.delta_bpm)));
    return .{ .rank = band * 8 + tier, .transition = tr };
}

fn mk(id: u64, bpm_centi: u32, key: []const u8) !Track {
    var t = Track.init(id, "t", "a");
    t.bpm_centi = bpm_centi;
    t.key = try camelot.parse(key);
    t.deriveBpm();
    return t;
}

test "same key and tempo ranks first" {
    const seed = try mk(1, 12800, "Am");
    const pool = [_]Track{
        try mk(2, 13000, "Em"), // lift
        try mk(3, 12800, "Am"), // identical
        try mk(4, 12800, "C"), // relative
    };
    const got = try rank(std.testing.allocator, seed, &pool, .{});
    defer std.testing.allocator.free(got);

    try std.testing.expectEqual(@as(u64, 3), got[0].track.id);
    try std.testing.expectEqual(@as(u64, 4), got[1].track.id);
    try std.testing.expectEqual(@as(u64, 2), got[2].track.id);
}

test "a tighter tempo outranks a closer key" {
    const seed = try mk(1, 12800, "Am");
    const pool = [_]Track{
        try mk(2, 13000, "Am"), // holds, two BPM away
        try mk(3, 12800, "Em"), // one step, same tempo
    };
    const got = try rank(std.testing.allocator, seed, &pool, .{});
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(u64, 3), got[0].track.id);
}

test "clashing keys are dropped" {
    const seed = try mk(1, 12800, "Am"); // 8A
    const pool = [_]Track{try mk(2, 12800, "Cm")}; // 5A, three steps away
    const got = try rank(std.testing.allocator, seed, &pool, .{});
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "tracks outside the tempo window are dropped" {
    const seed = try mk(1, 12800, "Am");
    const pool = [_]Track{try mk(2, 14000, "Am")};
    const got = try rank(std.testing.allocator, seed, &pool, .{});
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "a seed with no key is judged on tempo alone" {
    var seed = Track.init(1, "t", "a");
    seed.bpm_centi = 12800;
    seed.deriveBpm();
    const pool = [_]Track{try mk(2, 12900, "Cm")};
    const got = try rank(std.testing.allocator, seed, &pool, .{});
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expect(!got[0].transition.key_known);
}

test "a candidate must suit every seed" {
    const seeds = [_]Track{
        try mk(1, 12800, "Am"),
        try mk(2, 12800, "Em"),
    };
    const pool = [_]Track{
        try mk(3, 12800, "C"), // relative to Am, a step from Em
        try mk(4, 12800, "Gm"), // three steps from Em
    };
    const got = try rankFor(std.testing.allocator, &seeds, &pool, .{});
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(@as(u64, 3), got[0].track.id);
}

test "the worst pair ranks, the total breaks ties" {
    const seeds = [_]Track{
        try mk(1, 12800, "Am"),
        try mk(2, 12800, "Em"),
    };
    const pool = [_]Track{
        try mk(3, 12800, "C"), // Am 1, Em 2
        try mk(5, 12800, "Am"), // Am 0, Em 2
        try mk(4, 12800, "Dm"), // Am 2, Em 3
    };
    const got = try rankFor(std.testing.allocator, &seeds, &pool, .{});
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(u64, 5), got[0].track.id);
    try std.testing.expectEqual(@as(u32, 2), got[0].rank);
    try std.testing.expectEqual(@as(u32, 2), got[0].total);
    try std.testing.expectEqual(@as(u64, 3), got[1].track.id);
    try std.testing.expectEqual(@as(u32, 2), got[1].rank);
    try std.testing.expectEqual(@as(u32, 3), got[1].total);
    try std.testing.expectEqual(@as(u64, 4), got[2].track.id);
    try std.testing.expectEqual(@as(u32, 3), got[2].rank);
    try std.testing.expectEqual(@as(u32, 5), got[2].total);
}

test "a percentage window follows the seed's tempo" {
    const seed = try mk(1, 18000, "Am");
    const pool = [_]Track{try mk(2, 17200, "Am")}; // 8 BPM away
    const tight = try rank(std.testing.allocator, seed, &pool, .{});
    defer std.testing.allocator.free(tight);
    try std.testing.expectEqual(@as(usize, 0), tight.len);

    const wide = try rank(std.testing.allocator, seed, &pool, .{ .tolerance_percent = 5 });
    defer std.testing.allocator.free(wide);
    try std.testing.expectEqual(@as(usize, 1), wide.len);
}

test "no seeds ranks nothing" {
    const seeds: []const Track = &.{};
    const pool = [_]Track{try mk(2, 12800, "Am")};
    const got = try rankFor(std.testing.allocator, seeds, &pool, .{});
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}
