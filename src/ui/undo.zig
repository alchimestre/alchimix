//! The edit history behind U.
//!
//! Each entry remembers what an edit replaced rather than an inverse of it: a
//! crate is a short list of tracks, so keeping the list it had before an edit
//! is cheaper to reason about than deriving the edit to apply backwards.

const std = @import("std");
const Track = @import("alchimix").track.Track;

pub const Change = union(enum) {
    /// The crate as it stood before an edit, with its seed.
    crate: struct { tracks: []Track, seed: usize },
    /// A playlist rename: the id and the name it had.
    renamed: struct { id: []u8, name: []u8 },
    /// A playlist delete: what to write again to bring it back.
    deleted: struct { name: []u8, track_ids: []u64 },

    pub fn deinit(self: Change, allocator: std.mem.Allocator) void {
        switch (self) {
            .crate => |crate| allocator.free(crate.tracks),
            .renamed => |rename| {
                allocator.free(rename.id);
                allocator.free(rename.name);
            },
            .deleted => |playlist| {
                allocator.free(playlist.name);
                allocator.free(playlist.track_ids);
            },
        }
    }
};

pub const Undo = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Change) = .empty,

    /// A session-long history would hold every crate it ever had; this is deep
    /// enough to walk back through a set and bounded enough to forget the rest.
    pub const limit = 64;

    pub fn deinit(self: *Undo) void {
        for (self.entries.items) |change| change.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn empty(self: *const Undo) bool {
        return self.entries.items.len == 0;
    }

    /// Keeps the crate as it is now, before an edit changes it.
    pub fn pushCrate(self: *Undo, tracks: []const Track, seed: usize) void {
        const copy = self.allocator.dupe(Track, tracks) catch return;
        self.push(.{ .crate = .{ .tracks = copy, .seed = seed } });
    }

    pub fn pushRenamed(self: *Undo, id: []const u8, name: []const u8) void {
        const owned_id = self.allocator.dupe(u8, id) catch return;
        const owned_name = self.allocator.dupe(u8, name) catch {
            self.allocator.free(owned_id);
            return;
        };
        self.push(.{ .renamed = .{ .id = owned_id, .name = owned_name } });
    }

    pub fn pushDeleted(self: *Undo, name: []const u8, track_ids: []const u64) void {
        const owned_name = self.allocator.dupe(u8, name) catch return;
        const owned_ids = self.allocator.dupe(u64, track_ids) catch {
            self.allocator.free(owned_name);
            return;
        };
        self.push(.{ .deleted = .{ .name = owned_name, .track_ids = owned_ids } });
    }

    fn push(self: *Undo, change: Change) void {
        while (self.entries.items.len >= limit) {
            const oldest = self.entries.orderedRemove(0);
            oldest.deinit(self.allocator);
        }
        self.entries.append(self.allocator, change) catch change.deinit(self.allocator);
    }

    /// The newest change, handed to the caller to apply and then free.
    pub fn pop(self: *Undo) ?Change {
        if (self.entries.items.len == 0) return null;
        return self.entries.pop();
    }

    /// How many edits can still be walked back.
    pub fn depth(self: *const Undo) usize {
        return self.entries.items.len;
    }
};

const testing = std.testing;

fn sampleTrack(id: u64) Track {
    return .{ .id = id, .title = "track", .artist = "artist" };
}

test "undo hands back the newest edit and walks back one at a time" {
    var history = Undo{ .allocator = testing.allocator };
    defer history.deinit();

    const first = [_]Track{sampleTrack(1)};
    const second = [_]Track{ sampleTrack(1), sampleTrack(2) };
    history.pushCrate(&first, 0);
    history.pushCrate(&second, 1);
    try testing.expectEqual(@as(usize, 2), history.depth());

    const newest = history.pop() orelse return error.Empty;
    defer newest.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), newest.crate.tracks.len);
    try testing.expectEqual(@as(usize, 1), newest.crate.seed);

    const older = history.pop() orelse return error.Empty;
    defer older.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), older.crate.tracks.len);
    try testing.expectEqual(@as(u64, 1), older.crate.tracks[0].id);

    try testing.expectEqual(@as(?Change, null), history.pop());
}

test "the crate a change holds is a copy, not a view of the live one" {
    var history = Undo{ .allocator = testing.allocator };
    defer history.deinit();

    var crate = [_]Track{sampleTrack(7)};
    history.pushCrate(&crate, 0);
    crate[0].id = 99;

    const change = history.pop() orelse return error.Empty;
    defer change.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 7), change.crate.tracks[0].id);
}

test "renames and deletes keep what they need to be undone" {
    var history = Undo{ .allocator = testing.allocator };
    defer history.deinit();

    history.pushRenamed("playlist-1", "Trance");
    history.pushDeleted("Trance", &.{ 4, 5 });

    const deleted = history.pop() orelse return error.Empty;
    defer deleted.deinit(testing.allocator);
    try testing.expectEqualStrings("Trance", deleted.deleted.name);
    try testing.expectEqualSlices(u64, &.{ 4, 5 }, deleted.deleted.track_ids);

    const renamed = history.pop() orelse return error.Empty;
    defer renamed.deinit(testing.allocator);
    try testing.expectEqualStrings("playlist-1", renamed.renamed.id);
    try testing.expectEqualStrings("Trance", renamed.renamed.name);
}

test "the history forgets its oldest edit at the limit" {
    var history = Undo{ .allocator = testing.allocator };
    defer history.deinit();

    var index: u64 = 0;
    while (index <= Undo.limit) : (index += 1) {
        const tracks = [_]Track{sampleTrack(index)};
        history.pushCrate(&tracks, 0);
    }
    try testing.expectEqual(Undo.limit, history.depth());

    // Only the oldest edit was dropped; the newest is still the newest.
    var popped = history.pop() orelse return error.Empty;
    defer popped.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, Undo.limit), popped.crate.tracks[0].id);
}
