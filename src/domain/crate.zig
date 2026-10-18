//! The playlist being built: an ordered run of tracks with a harmonic
//! relation between each neighbour.

const std = @import("std");
const camelot = @import("camelot.zig");
const bpm = @import("bpm.zig");
const track = @import("track.zig");

pub const Track = track.Track;

/// What the link between two neighbouring blocks says.
pub const Transition = struct {
    key: camelot.Relation = .{},
    key_known: bool = false,
    bpm_delta: f64 = 0,
    bpm_direction: bpm.Direction = .held,
    stretch: bpm.Stretch = .none,

    /// The pair is playable together: the keys agree and the tempos are inside
    /// the window.
    pub fn playable(self: Transition, tolerance_bpm: f64) bool {
        if (!self.key_known) return true;
        return self.key.harmonic and @abs(self.bpm_delta) <= tolerance_bpm;
    }
};

pub const Crate = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Track) = .empty,
    /// Index of the track the suggestions are drawn from.
    seed: ?usize = null,

    pub const tolerance_bpm: f64 = 6;

    pub fn init(allocator: std.mem.Allocator) Crate {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Crate) void {
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn len(self: *const Crate) usize {
        return self.items.items.len;
    }

    pub fn at(self: *const Crate, index: usize) ?*const Track {
        if (index >= self.items.items.len) return null;
        return &self.items.items[index];
    }

    pub fn seedTrack(self: *const Crate) ?*const Track {
        const s = self.seed orelse return null;
        return self.at(s);
    }

    pub fn setSeed(self: *Crate, index: usize) void {
        if (index < self.items.items.len) self.seed = index;
    }

    /// Append and return the new index.
    pub fn append(self: *Crate, t: Track) !usize {
        try self.items.append(self.allocator, t);
        const index = self.items.items.len - 1;
        if (self.seed == null) self.seed = index;
        return index;
    }

    /// Insert next to `anchor`. `to_left` puts the new track before it.
    pub fn insert(self: *Crate, anchor: usize, to_left: bool, t: Track) !usize {
        if (anchor >= self.items.items.len) return error.NoSuchAnchor;
        const index = if (to_left) anchor else anchor + 1;
        try self.items.insert(self.allocator, index, t);
        if (self.seed) |s| {
            if (index <= s) self.seed = s + 1;
        }
        return index;
    }

    pub fn move(self: *Crate, from: usize, to: usize) !void {
        const n = self.items.items.len;
        if (from >= n or to >= n) return error.OutOfRange;
        const t = self.items.orderedRemove(from);
        try self.items.insert(self.allocator, to, t);
        if (self.seed) |s| {
            if (s == from) {
                self.seed = to;
            } else if (from < s and to >= s) {
                self.seed = s - 1;
            } else if (from > s and to <= s) {
                self.seed = s + 1;
            }
        }
    }

    /// Insert at a gap index, 0 before the first track and `len` after the last.
    pub fn insertAt(self: *Crate, index: usize, t: Track) !usize {
        if (index > self.items.items.len) return error.OutOfRange;
        try self.items.insert(self.allocator, index, t);

        if (self.seed) |seed| {
            if (index <= seed) self.seed = seed + 1;
        } else {
            self.seed = index;
        }
        return index;
    }

    /// Move a track to a gap index, as a drag would.
    pub fn moveTo(self: *Crate, from: usize, insert_at: usize) !void {
        if (from >= self.items.items.len) return error.OutOfRange;
        if (insert_at > self.items.items.len) return error.OutOfRange;

        const moved = self.items.orderedRemove(from);
        var target = insert_at;
        if (from < insert_at) target -= 1;
        try self.items.insert(self.allocator, target, moved);

        if (self.seed) |seed| {
            if (seed == from) {
                self.seed = target;
            } else if (from < seed and target >= seed) {
                self.seed = seed - 1;
            } else if (from > seed and target <= seed) {
                self.seed = seed + 1;
            }
        }
    }

    pub fn remove(self: *Crate, index: usize) !void {
        if (index >= self.items.items.len) return error.OutOfRange;
        _ = self.items.orderedRemove(index);

        if (self.seed) |seed| {
            if (seed == index) {
                self.seed = if (self.items.items.len == 0) null else @min(index, self.items.items.len - 1);
            } else if (index < seed) {
                self.seed = seed - 1;
            }
        }
    }

    /// The link from item `index` to the one after it. Null at the tail.
    pub fn transition(self: *const Crate, index: usize) ?Transition {
        const a = self.at(index) orelse return null;
        const b = self.at(index + 1) orelse return null;

        const m = bpm.match(a.bpm_centi, b.bpm_centi);
        var out = Transition{
            .bpm_delta = m.delta_bpm,
            .bpm_direction = bpm.direction(a.bpm_centi, b.bpm_centi, 0.5),
            .stretch = m.stretch,
        };
        if (a.key) |ka| {
            if (b.key) |kb| {
                out.key = camelot.relation(ka, kb);
                out.key_known = true;
            }
        }
        return out;
    }
};

const T = struct {
    fn make(id: u64, bpm_centi: u32, key: ?[]const u8) !Track {
        var t = Track.init(id, "t", "a");
        t.bpm_centi = bpm_centi;
        if (key) |k| t.key = try camelot.parse(k);
        t.deriveBpm();
        return t;
    }
};

test "append and seed" {
    var c = Crate.init(std.testing.allocator);
    defer c.deinit();
    _ = try c.append(try T.make(1, 12800, "Am"));
    _ = try c.append(try T.make(2, 12800, "Em"));
    try std.testing.expectEqual(@as(usize, 2), c.len());
    try std.testing.expectEqual(@as(u64, 1), c.seedTrack().?.id);
}

test "insert left and right of the anchor" {
    var c = Crate.init(std.testing.allocator);
    defer c.deinit();
    _ = try c.append(try T.make(1, 12800, "Am"));
    _ = try c.append(try T.make(2, 12800, "Em"));
    _ = try c.insert(0, true, try T.make(3, 12800, "Dm"));
    _ = try c.insert(1, false, try T.make(4, 12800, "Gm"));

    const ids = [_]u64{ 3, 1, 4, 2 };
    for (ids, 0..) |want, i| try std.testing.expectEqual(want, c.at(i).?.id);
    // The seed followed its track when the list shifted right.
    try std.testing.expectEqual(@as(usize, 1), c.seed.?);
}

test "transition reports key and tempo" {
    var c = Crate.init(std.testing.allocator);
    defer c.deinit();
    _ = try c.append(try T.make(1, 12800, "Am"));
    _ = try c.append(try T.make(2, 13000, "Em"));

    const tr = c.transition(0).?;
    try std.testing.expect(tr.key_known);
    try std.testing.expectEqual(camelot.Direction.up, tr.key.direction);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), tr.bpm_delta, 1e-9);
    try std.testing.expect(tr.playable(Crate.tolerance_bpm));
    try std.testing.expectEqual(@as(?Transition, null), c.transition(1));
}

test "unread key does not block the link" {
    var c = Crate.init(std.testing.allocator);
    defer c.deinit();
    _ = try c.append(try T.make(1, 12800, null));
    _ = try c.append(try T.make(2, 12800, "Em"));
    const tr = c.transition(0).?;
    try std.testing.expect(!tr.key_known);
    try std.testing.expect(tr.playable(Crate.tolerance_bpm));
}

test "insertAt keeps the seed on its track" {
    var c = Crate.init(std.testing.allocator);
    defer c.deinit();
    _ = try c.append(try T.make(1, 12800, "Am"));
    _ = try c.append(try T.make(2, 12800, "Em"));
    c.setSeed(0);

    _ = try c.insertAt(0, try T.make(3, 12800, "Dm"));
    try std.testing.expectEqual(@as(usize, 1), c.seed.?);
    try std.testing.expectEqual(@as(u64, 1), c.seedTrack().?.id);
}

test "moveTo puts the track in the gap" {
    var c = Crate.init(std.testing.allocator);
    defer c.deinit();
    for (1..4) |i| _ = try c.append(try T.make(i, 12800, "Am"));

    // Drag the first track past the last one.
    try c.moveTo(0, 3);
    const ids = [_]u64{ 2, 3, 1 };
    for (ids, 0..) |want, i| try std.testing.expectEqual(want, c.at(i).?.id);

    // And back to the front.
    try c.moveTo(2, 0);
    const back = [_]u64{ 1, 2, 3 };
    for (back, 0..) |want, i| try std.testing.expectEqual(want, c.at(i).?.id);
}

test "removing the seed picks a neighbour" {
    var c = Crate.init(std.testing.allocator);
    defer c.deinit();
    for (1..4) |i| _ = try c.append(try T.make(i, 12800, "Am"));
    c.setSeed(1);
    try c.remove(1);
    try std.testing.expectEqual(@as(usize, 2), c.len());
    try std.testing.expectEqual(@as(u64, 3), c.seedTrack().?.id);
}

test "removing before the seed shifts it" {
    var c = Crate.init(std.testing.allocator);
    defer c.deinit();
    for (1..4) |i| _ = try c.append(try T.make(i, 12800, "Am"));
    c.setSeed(2);
    try c.remove(0);
    try std.testing.expectEqual(@as(usize, 1), c.seed.?);
    try std.testing.expectEqual(@as(u64, 3), c.seedTrack().?.id);
}

test "removing the last track clears the seed" {
    var c = Crate.init(std.testing.allocator);
    defer c.deinit();
    _ = try c.append(try T.make(1, 12800, "Am"));
    try c.remove(0);
    try std.testing.expectEqual(@as(?usize, null), c.seed);
}

test "move keeps the seed on its track" {
    var c = Crate.init(std.testing.allocator);
    defer c.deinit();
    for (1..4) |i| _ = try c.append(try T.make(i, 12800, "Am"));
    c.setSeed(0);
    try c.move(0, 2);
    try std.testing.expectEqual(@as(u64, 1), c.seedTrack().?.id);
}
