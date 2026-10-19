//! In-memory source, used by tests and by `--demo`.

const std = @import("std");
const track = @import("../domain/track.zig");
const camelot = @import("../domain/camelot.zig");
const library = @import("../ports/library.zig");
const analysis = @import("../domain/analysis.zig");

const Track = track.Track;

pub const Source = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayListUnmanaged(Track) = .empty,
    hits: std.ArrayListUnmanaged(Track) = .empty,

    pub fn init(allocator: std.mem.Allocator) Source {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn add(self: *Source, id: u64, title: []const u8, artist: []const u8, bpm_centi: u32, key: ?[]const u8) !void {
        const a = self.arena.allocator();
        var t = Track.init(id, try a.dupe(u8, title), try a.dupe(u8, artist));
        t.bpm_centi = bpm_centi;
        if (key) |k| {
            // A name the wheel cannot read leaves the key unset rather than
            // failing the load: one bad row must not hide the library.
            t.key = camelot.parse(k) catch null;
        }
        t.deriveBpm();
        try self.items.append(a, t);
    }

    pub fn port(self: *Source) library.Library {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn ctxOf(ctx: *anyopaque) *Source {
        return @ptrCast(@alignCast(ctx));
    }

    fn allFn(ctx: *anyopaque) anyerror![]const Track {
        return ctxOf(ctx).items.items;
    }

    /// The demo library carries no audio, so it has no grid to offer.
    fn analysisFn(_: *anyopaque, _: std.mem.Allocator, _: u64) anyerror!analysis.Analysis {
        return error.NoAnalysis;
    }

    fn searchFn(ctx: *anyopaque, needle: []const u8) anyerror![]const Track {
        const self = ctxOf(ctx);
        self.hits.clearRetainingCapacity();
        for (self.items.items) |t| {
            if (t.matches(needle)) try self.hits.append(self.arena.allocator(), t);
        }
        return self.hits.items;
    }

    fn playlistsFn(_: *anyopaque) anyerror![]const library.Playlist {
        return &.{};
    }

    fn playlistTracksFn(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]const u64 {
        return allocator.alloc(u64, 0);
    }

    fn createPlaylistFn(_: *anyopaque, _: []const u8, _: []const u64) anyerror!void {
        return error.Unsupported;
    }

    fn nameFn(_: *anyopaque) []const u8 {
        return "memory";
    }

    fn deinitFn(ctx: *anyopaque) void {
        const self = ctxOf(ctx);
        self.hits.deinit(self.arena.allocator());
        self.items.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    const vtable = library.Library.VTable{
        .all = allFn,
        .search = searchFn,
        .analysis = analysisFn,
        .playlists = playlistsFn,
        .playlistTracks = playlistTracksFn,
        .createPlaylist = createPlaylistFn,
        .name = nameFn,
        .deinit = deinitFn,
    };
};

test "search filters by title and artist and reuses its buffer" {
    var src = Source.init(std.testing.allocator);
    const lib = src.port();
    defer lib.deinit();

    try src.add(1, "Plastic Beach", "Pepe Mogt", 12000, "Gm");
    try src.add(2, "Smalltown Acid Boy", "Herr Krank", 13800, "Cm");

    const all = try lib.all();
    try std.testing.expectEqual(@as(usize, 2), all.len);

    const acid = try lib.search("acid");
    try std.testing.expectEqual(@as(usize, 1), acid.len);
    try std.testing.expectEqualStrings("Smalltown Acid Boy", acid[0].title);
    try std.testing.expect(acid[0].key.?.number == 5);

    const none = try lib.search("zzz");
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "an unreadable key leaves the track usable" {
    var src = Source.init(std.testing.allocator);
    const lib = src.port();
    defer lib.deinit();
    try src.add(1, "Unknown", "Nobody", 12800, "H#m");
    const all = try lib.all();
    try std.testing.expectEqual(@as(?camelot.Key, null), all[0].key);
    try std.testing.expectApproxEqAbs(@as(f64, 128), all[0].bpm, 1e-9);
}
