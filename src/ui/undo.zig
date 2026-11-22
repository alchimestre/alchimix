//! The edit history behind U.
//!
//! Each entry remembers what an edit replaced rather than an inverse of it: a
//! crate is a short list of tracks, so keeping the list it had before an edit
//! is cheaper to reason about than deriving the edit to apply backwards.

const std = @import("std");
const Track = @import("alchimix").track.Track;
const library = @import("alchimix").library;

pub const Change = union(enum) {
    /// The crate as it stood before an edit, with its seed, the playlist it was
    /// open on and the membership that playlist had when it was loaded.
    crate: struct { tracks: []Track, seed: usize, playlist: ?[]u8, baseline: []u64 },
    /// A playlist rename: the id and the name it had.
    renamed: struct { id: []u8, name: []u8 },
    /// A playlist delete: everything needed to write it back where it was.
    deleted: struct {
        id: []u8,
        name: []u8,
        parent: []u8,
        uuid: []u8,
        seq: i64,
        kind: library.PlaylistKind,
        track_ids: []u64,
    },

    pub fn ofCrate(
        allocator: std.mem.Allocator,
        tracks: []const Track,
        seed: usize,
        playlist: ?[]const u8,
        baseline: []const u64,
    ) !Change {
        const copy = try allocator.dupe(Track, tracks);
        errdefer allocator.free(copy);
        const owned_baseline = try allocator.dupe(u64, baseline);
        errdefer allocator.free(owned_baseline);
        const owned_playlist = if (playlist) |id| try allocator.dupe(u8, id) else null;
        return .{ .crate = .{ .tracks = copy, .seed = seed, .playlist = owned_playlist, .baseline = owned_baseline } };
    }

    pub fn ofRename(allocator: std.mem.Allocator, id: []const u8, name: []const u8) !Change {
        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);
        return .{ .renamed = .{ .id = owned_id, .name = try allocator.dupe(u8, name) } };
    }

    pub fn ofDelete(allocator: std.mem.Allocator, playlist: library.Playlist, track_ids: []const u64) !Change {
        const id = try allocator.dupe(u8, playlist.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, playlist.name);
        errdefer allocator.free(name);
        const parent = try allocator.dupe(u8, playlist.parent);
        errdefer allocator.free(parent);
        const uuid = try allocator.dupe(u8, playlist.uuid);
        errdefer allocator.free(uuid);
        const ids = try allocator.dupe(u64, track_ids);
        return .{ .deleted = .{
            .id = id,
            .name = name,
            .parent = parent,
            .uuid = uuid,
            .seq = playlist.seq,
            .kind = playlist.kind,
            .track_ids = ids,
        } };
    }

    /// The playlist row a delete captured, as the port wants it back.
    pub fn deletedPlaylist(self: Change) library.Playlist {
        const gone = self.deleted;
        return .{ .id = gone.id, .name = gone.name, .parent = gone.parent, .kind = gone.kind, .seq = gone.seq, .uuid = gone.uuid };
    }

    pub fn deinit(self: Change, allocator: std.mem.Allocator) void {
        switch (self) {
            .crate => |crate| {
                allocator.free(crate.tracks);
                allocator.free(crate.baseline);
                if (crate.playlist) |id| allocator.free(id);
            },
            .renamed => |rename| {
                allocator.free(rename.id);
                allocator.free(rename.name);
            },
            .deleted => |gone| {
                allocator.free(gone.id);
                allocator.free(gone.name);
                allocator.free(gone.parent);
                allocator.free(gone.uuid);
                allocator.free(gone.track_ids);
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

    /// Room for one more entry, so a push after a committed write cannot fail.
    pub fn reserve(self: *Undo) !void {
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
    }

    /// Keeps the crate as it is now, before an edit changes it.
    pub fn pushCrate(self: *Undo, tracks: []const Track, seed: usize, playlist: ?[]const u8, baseline: []const u64) !void {
        const change = try Change.ofCrate(self.allocator, tracks, seed, playlist, baseline);
        errdefer change.deinit(self.allocator);
        try self.reserve();
        self.push(change);
    }

    /// Call `reserve` first when the entry must not be lost.
    pub fn push(self: *Undo, change: Change) void {
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
    try history.pushCrate(&first, 0, null, &.{});
    try history.pushCrate(&second, 1, null, &.{});
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
    try history.pushCrate(&crate, 0, null, &.{});
    crate[0].id = 99;

    const change = history.pop() orelse return error.Empty;
    defer change.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 7), change.crate.tracks[0].id);
}

test "a crate change remembers the playlist it was open on and its membership" {
    var history = Undo{ .allocator = testing.allocator };
    defer history.deinit();

    const tracks = [_]Track{sampleTrack(1)};
    try history.pushCrate(&tracks, 0, "playlist-1", &.{ 1, 2 });

    const change = history.pop() orelse return error.Empty;
    defer change.deinit(testing.allocator);
    try testing.expectEqualStrings("playlist-1", change.crate.playlist.?);
    try testing.expectEqualSlices(u64, &.{ 1, 2 }, change.crate.baseline);
}

test "renames and deletes keep what they need to be undone" {
    var history = Undo{ .allocator = testing.allocator };
    defer history.deinit();

    history.push(try Change.ofRename(testing.allocator, "playlist-1", "Trance"));
    const row = library.Playlist{ .id = "p2", .name = "Trance", .parent = "folder", .kind = .list, .seq = 3, .uuid = "u-p2" };
    history.push(try Change.ofDelete(testing.allocator, row, &.{ 4, 5 }));

    const deleted = history.pop() orelse return error.Empty;
    defer deleted.deinit(testing.allocator);
    try testing.expectEqualStrings("Trance", deleted.deleted.name);
    try testing.expectEqualStrings("folder", deleted.deleted.parent);
    try testing.expectEqualStrings("u-p2", deleted.deleted.uuid);
    try testing.expectEqual(@as(i64, 3), deleted.deleted.seq);
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
        try history.pushCrate(&tracks, 0, null, &.{});
    }
    try testing.expectEqual(Undo.limit, history.depth());

    // Only the oldest edit was dropped; the newest is still the newest.
    var popped = history.pop() orelse return error.Empty;
    defer popped.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, Undo.limit), popped.crate.tracks[0].id);
}
