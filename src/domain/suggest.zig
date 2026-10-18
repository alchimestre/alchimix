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
    /// Lower is a closer match. Sorted on this.
    rank: u32,
};

pub const Options = struct {
    tolerance_bpm: f64 = crate.Crate.tolerance_bpm,
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
    var out: std.ArrayListUnmanaged(Candidate) = .empty;
    errdefer out.deinit(allocator);

    for (pool) |t| {
        if (t.id == seed.id) continue;

        const m = bpm.match(seed.bpm_centi, t.bpm_centi);
        if (@abs(m.delta_bpm) > options.tolerance_bpm) continue;

        var tr = crate.Transition{
            .bpm_delta = m.delta_bpm,
            .bpm_direction = bpm.direction(seed.bpm_centi, t.bpm_centi, 0.5),
            .stretch = m.stretch,
        };

        var tier: u32 = 0;
        if (seed.key) |sk| {
            if (t.key) |tk| {
                const rel = camelot.relation(sk, tk);
                tr.key = rel;
                tr.key_known = true;
                if (!rel.harmonic and options.harmonic_only) continue;
                tier = switch (rel.strength) {
                    .none => if (sk.number == tk.number and sk.mode == tk.mode) 0 else 1,
                    .slight => 2,
                    .strong => 3,
                    .big => 4,
                };
            } else if (options.harmonic_only) {
                continue;
            }
        }

        // Tempo first, in whole-BPM bands, then the harmonic step inside the
        // band. Ranking by the step first fills the list with one key and the
        // direction never shows.
        const band: u32 = @intFromFloat(@round(@abs(m.delta_bpm)));
        try out.append(allocator, .{
            .track = t,
            .transition = tr,
            .rank = band * 8 + tier,
        });
    }

    std.mem.sort(Candidate, out.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            return a.rank < b.rank;
        }
    }.lessThan);

    return out.toOwnedSlice(allocator);
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
