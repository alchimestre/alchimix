//! Reads and writes a rekordbox 6 collection through the library port.
//!
//! rekordbox stores the collection in a SQLCipher database, so this links
//! libsqlcipher rather than SQLite. A write that touches more than one row
//! runs in one transaction: a half-written playlist is worse than a refused
//! save.

const std = @import("std");
const track = @import("../domain/track.zig");
const camelot = @import("../domain/camelot.zig");
const library = @import("../ports/library.zig");
const analysis = @import("../domain/analysis.zig");

const c = @import("c");

const Track = track.Track;

pub const Error = error{
    NoDatabase,
    NoKey,
    OpenFailed,
    KeyRejected,
    QueryFailed,
};

pub const Options = struct {
    io: std.Io,
    db_path: []const u8,
    key: []const u8,
};

const select_sql =
    \\select c.ID, c.Title, coalesce(a.Name, ''), c.BPM, k.ScaleName, c.Length,
    \\       coalesce(c.FolderPath, ''),
    \\       coalesce(c.AnalysisDataPath, ''),
    \\       coalesce(g.Name, ''),
    \\       coalesce((select group_concat(t.Name, ' ')
    \\                 from djmdSongMyTag s join djmdMyTag t on t.ID = s.MyTagID
    \\                 where s.ContentID = c.ID and s.rb_local_deleted = 0), '')
    \\from djmdContent c
    \\left join djmdArtist a on a.ID = c.ArtistID
    \\left join djmdKey k on k.ID = c.KeyID
    \\left join djmdGenre g on g.ID = c.GenreID
    \\where c.rb_local_deleted = 0
    \\order by c.ID
;

pub const Source = struct {
    arena: std.heap.ArenaAllocator,
    backing: std.mem.Allocator,
    db: *c.sqlite3,
    path: []const u8,
    io: std.Io,
    items: std.ArrayListUnmanaged(Track) = .empty,
    hits: std.ArrayListUnmanaged(Track) = .empty,
    playlists: std.ArrayListUnmanaged(library.Playlist) = .empty,

    pub fn open(allocator: std.mem.Allocator, options: Options) !Source {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const path = try a.dupe(u8, options.db_path);
        std.Io.Dir.accessAbsolute(options.io, path, .{}) catch return Error.NoDatabase;
        const key = try a.dupe(u8, options.key);

        const path_z = try a.dupeSentinel(u8, path, 0);
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(path_z.ptr, &db, c.SQLITE_OPEN_READWRITE, null) != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return Error.OpenFailed;
        }
        const handle = db.?;
        errdefer _ = c.sqlite3_close(handle);

        // PRAGMA takes no bound parameters, so the key goes in as an escaped
        // literal.
        const escaped = try std.mem.replaceOwned(u8, a, key, "'", "''");
        const pragma = try std.fmt.allocPrintSentinel(a, "PRAGMA key = '{s}';", .{escaped}, 0);
        if (c.sqlite3_exec(handle, pragma.ptr, null, null, null) != c.SQLITE_OK) return Error.KeyRejected;

        // rekordbox and its agent write to the same file. Without a timeout any
        // concurrent write fails instantly, which is how a save ends up empty.
        if (c.sqlite3_exec(handle, "PRAGMA busy_timeout = 5000;", null, null, null) != c.SQLITE_OK) return Error.OpenFailed;

        var self = Source{
            .arena = arena,
            .backing = allocator,
            .db = handle,
            .path = path,
            .io = options.io,
        };
        errdefer self.arena.deinit();
        try self.reload();
        try self.reloadPlaylists();
        return self;
    }

    pub fn port(self: *Source) library.Library {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn reload(self: *Source) !void {
        const a = self.arena.allocator();
        self.items.clearRetainingCapacity();

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, select_sql, -1, &stmt, null) != c.SQLITE_OK) return Error.QueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        const s = stmt.?;

        while (true) {
            const rc = c.sqlite3_step(s);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return Error.QueryFailed;

            const id: u64 = @intCast(c.sqlite3_column_int64(s, 0));
            var t = Track.init(
                id,
                try a.dupe(u8, column(s, 1)),
                try a.dupe(u8, column(s, 2)),
            );
            t.bpm_centi = @intCast(@max(0, c.sqlite3_column_int64(s, 3)));
            const scale = column(s, 4);
            if (scale.len > 0) t.key = camelot.parse(scale) catch null;
            t.length_s = @intCast(@max(0, c.sqlite3_column_int64(s, 5)));
            t.file_path = try a.dupe(u8, column(s, 6));
            t.analysis_path = try a.dupe(u8, column(s, 7));
            t.genre = try a.dupe(u8, column(s, 8));
            t.tags = try a.dupe(u8, column(s, 9));
            t.deriveBpm();
            try self.items.append(a, t);
        }
    }

    fn reloadPlaylists(self: *Source) !void {
        const a = self.arena.allocator();
        self.playlists.clearRetainingCapacity();

        var stmt: ?*c.sqlite3_stmt = null;
        const sql =
            \\select ID, Name, ParentID, Attribute
            \\from djmdPlaylist
            \\where rb_local_deleted = 0
            \\order by Seq
        ;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return Error.QueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        const s = stmt.?;
        while (true) {
            const rc = c.sqlite3_step(s);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return Error.QueryFailed;
            const attribute = c.sqlite3_column_int(s, 3);
            const name = column(s, 1);
            // rekordbox files its own cue-analysis lists beside the user's.
            // They are generated, so they are left out of the column.
            if (std.mem.startsWith(u8, name, "CUE Analysis Playlist")) continue;
            try self.playlists.append(a, .{
                .id = try a.dupe(u8, column(s, 0)),
                .name = try a.dupe(u8, name),
                .parent = try a.dupe(u8, column(s, 2)),
                // 1 is a folder, 4 is an intelligent playlist (SmartList).
                .kind = switch (attribute) {
                    1 => .folder,
                    4 => .smart,
                    else => .list,
                },
            });
        }
    }

    fn playlistsFn(ctx: *anyopaque) anyerror![]const library.Playlist {
        return ctxOf(ctx).playlists.items;
    }

    fn playlistTracksFn(ctx: *anyopaque, allocator: std.mem.Allocator, playlist_id: []const u8) anyerror![]const u64 {
        const self = ctxOf(ctx);
        var out: std.ArrayListUnmanaged(u64) = .empty;
        errdefer out.deinit(allocator);

        const sql = "select ContentID from djmdSongPlaylist where PlaylistID = ?1 and rb_local_deleted = 0 order by TrackNo";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return Error.QueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        const s = stmt.?;
        _ = c.sqlite3_bind_text(s, 1, playlist_id.ptr, @intCast(playlist_id.len), null);
        while (true) {
            const rc = c.sqlite3_step(s);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return Error.QueryFailed;
            try out.append(allocator, @intCast(c.sqlite3_column_int64(s, 0)));
        }
        return out.toOwnedSlice(allocator);
    }

    fn createPlaylistFn(ctx: *anyopaque, playlist_name: []const u8, track_ids: []const u64) anyerror!void {
        const self = ctxOf(ctx);
        try self.beginImmediate();
        errdefer self.rollback();
        const a = self.arena.allocator();
        const next_id = try self.queryInt("select coalesce(max(cast(ID as integer)), 0) + 1 from djmdPlaylist");
        const next_seq = try self.queryInt("select coalesce(max(Seq), 0) + 1 from djmdPlaylist");
        const next_usn = try self.queryInt("select coalesce(max(rb_local_usn), 0) + 1 from djmdPlaylist");
        const uuid = try makeUuid(a, next_id);
        try self.execBound(
            "insert into djmdPlaylist (ID, Seq, Name, ParentID, Attribute, UUID, rb_local_usn, created_at, updated_at) " ++
                "values ({d}, {d}, ?1, 'root', 0, ?2, {d}, {s}, {s})",
            .{ next_id, next_seq, next_usn, nowSql(), nowSql() },
            .{ playlist_name, uuid },
        );
        const playlist_id = try std.fmt.allocPrint(a, "{d}", .{next_id});
        for (track_ids, 1..) |track_id, number| {
            try self.appendEntry(playlist_id, track_id, number);
        }
        try self.commit();
        try self.reloadPlaylists();
    }

    fn replacePlaylistTracksFn(ctx: *anyopaque, playlist_id: []const u8, track_ids: []const u64) anyerror!void {
        const self = ctxOf(ctx);
        try self.beginImmediate();
        errdefer self.rollback();
        try self.execBound("delete from djmdSongPlaylist where PlaylistID = ?1", .{}, .{playlist_id});
        for (track_ids, 1..) |track_id, number| {
            try self.appendEntry(playlist_id, track_id, number);
        }
        const usn = try self.queryInt("select coalesce(max(rb_local_usn), 0) + 1 from djmdPlaylist");
        try self.execBound(
            "update djmdPlaylist set rb_local_usn = {d}, updated_at = {s} where ID = ?1",
            .{ usn, nowSql() },
            .{playlist_id},
        );
        // A replace against a playlist that is gone would leave its entries
        // pointing at nothing.
        if (c.sqlite3_changes(self.db) == 0) return error.PlaylistNotFound;
        try self.commit();
        try self.reloadPlaylists();
    }

    fn renamePlaylistFn(ctx: *anyopaque, playlist_id: []const u8, playlist_name: []const u8) anyerror!void {
        const self = ctxOf(ctx);
        const usn = try self.queryInt("select coalesce(max(rb_local_usn), 0) + 1 from djmdPlaylist");
        try self.execBound(
            "update djmdPlaylist set Name = ?1, rb_local_usn = ?2, updated_at = {s} where ID = ?3",
            .{nowSql()},
            .{ playlist_name, usn, playlist_id },
        );
        try self.reloadPlaylists();
    }

    fn deletePlaylistFn(ctx: *anyopaque, playlist_id: []const u8) anyerror!void {
        const self = ctxOf(ctx);
        try self.beginImmediate();
        errdefer self.rollback();
        try self.deletePlaylistRows(playlist_id);
        // An id that was already gone is an error here too, as it is on the
        // demo source: a save that silently did nothing is worse than a refusal.
        if (c.sqlite3_changes(self.db) == 0) return error.PlaylistNotFound;
        try self.commit();
        try self.reloadPlaylists();
    }

    fn deletePlaylistRows(self: *Source, playlist_id: []const u8) !void {
        try self.execBound("delete from djmdSongPlaylist where PlaylistID = ?1", .{}, .{playlist_id});
        try self.execBound("delete from djmdPlaylist where ID = ?1", .{}, .{playlist_id});
    }

    fn appendEntry(self: *Source, playlist_id: []const u8, track_id: u64, number: u64) !void {
        const a = self.arena.allocator();
        const seed = entrySeed(playlist_id, track_id, number);
        const entry_id = try makeUuid(a, seed);
        const uuid = try makeUuid(a, seed ^ entry_uuid_salt);
        const usn = try self.queryInt("select coalesce(max(rb_local_usn), 0) + 1 from djmdSongPlaylist");
        try self.execBound(
            "insert into djmdSongPlaylist (ID, PlaylistID, ContentID, TrackNo, UUID, rb_local_usn, created_at, updated_at) " ++
                "values ('{s}', ?1, ?2, ?3, ?4, {d}, {s}, {s})",
            .{ entry_id, usn, nowSql(), nowSql() },
            .{ playlist_id, track_id, number, uuid },
        );
    }

    /// Takes the write lock for the one transaction a save runs in, so the
    /// playlist header and its rows land together or not at all.
    fn beginImmediate(self: *Source) !void {
        try self.exec("begin immediate", .{});
    }

    fn rollback(self: *Source) void {
        self.exec("rollback", .{}) catch {};
    }

    /// A commit that fails still has to end the transaction, or every later
    /// write fails with it.
    fn commit(self: *Source) !void {
        self.exec("commit", .{}) catch |err| {
            self.rollback();
            return err;
        };
    }

    /// The port only surfaces `QueryFailed`, so the reason goes to the log: a
    /// refused save is otherwise indistinguishable from one that wrote nothing.
    fn statementFailed(self: *Source, statement: []const u8) Error {
        std.log.err("rekordbox statement failed ({s}): {s}", .{ statement, std.mem.sliceTo(c.sqlite3_errmsg(self.db), 0) });
        return Error.QueryFailed;
    }

    fn queryInt(self: *Source, sql: [:0]const u8) !u64 {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return self.statementFailed(sql);
        defer _ = c.sqlite3_finalize(stmt);
        const s = stmt.?;
        if (c.sqlite3_step(s) != c.SQLITE_ROW) return self.statementFailed(sql);
        return @intCast(c.sqlite3_column_int64(s, 0));
    }

    fn queryIntFmt(self: *Source, comptime fmt: []const u8, args: anytype) !u64 {
        const sql = try std.fmt.allocPrintSentinel(self.arena.allocator(), fmt, args, 0);
        return self.queryInt(sql);
    }

    fn exec(self: *Source, comptime fmt: []const u8, args: anytype) !void {
        const sql = try std.fmt.allocPrintSentinel(self.arena.allocator(), fmt, args, 0);
        if (c.sqlite3_exec(self.db, sql.ptr, null, null, null) != c.SQLITE_OK) return self.statementFailed(sql);
    }

    /// Runs one statement with its data values bound, in order. The format
    /// carries the statement's shape and its SQL expressions; ids and names
    /// come from the library or the user, so they are bound.
    fn execBound(self: *Source, comptime fmt: []const u8, fmt_args: anytype, params: anytype) !void {
        const sql = try std.fmt.allocPrintSentinel(self.arena.allocator(), fmt, fmt_args, 0);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return self.statementFailed(sql);
        defer _ = c.sqlite3_finalize(stmt);
        const s = stmt.?;
        inline for (params, 1..) |value, index| {
            if (bindValue(s, index, value) != c.SQLITE_OK) return self.statementFailed(sql);
        }
        if (c.sqlite3_step(s) != c.SQLITE_DONE) return self.statementFailed(sql);
    }

    fn ctxOf(ctx: *anyopaque) *Source {
        return @ptrCast(@alignCast(ctx));
    }

    fn allFn(ctx: *anyopaque) anyerror![]const Track {
        return ctxOf(ctx).items.items;
    }

    fn analysisFn(ctx: *anyopaque, allocator: std.mem.Allocator, track_id: u64) anyerror!analysis.Analysis {
        const self = ctxOf(ctx);
        for (self.items.items) |t| {
            if (t.id != track_id) continue;
            if (t.analysis_path.len == 0) return error.NoAnalysis;

            const root = std.fs.path.dirname(self.path) orelse return error.NoAnalysis;
            const dat_path = try std.fmt.allocPrint(allocator, "{s}/share{s}", .{ root, t.analysis_path });
            defer allocator.free(dat_path);
            const ext_path = try std.mem.replaceOwned(u8, allocator, dat_path, ".DAT", ".EXT");
            defer allocator.free(ext_path);

            const dat = try std.Io.Dir.cwd().readFileAlloc(self.io, dat_path, allocator, .limited(4 << 20));
            defer allocator.free(dat);
            const ext = try std.Io.Dir.cwd().readFileAlloc(self.io, ext_path, allocator, .limited(16 << 20));
            defer allocator.free(ext);

            return analysis.parse(allocator, dat, ext);
        }
        return error.NoAnalysis;
    }

    fn searchFn(ctx: *anyopaque, needle: []const u8) anyerror![]const Track {
        const self = ctxOf(ctx);
        self.hits.clearRetainingCapacity();
        for (self.items.items) |t| {
            if (t.matches(needle)) try self.hits.append(self.backing, t);
        }
        std.mem.sort(Track, self.hits.items, needle, Track.searchLessThan);
        return self.hits.items;
    }

    fn nameFn(_: *anyopaque) []const u8 {
        return "rekordbox";
    }

    fn deinitFn(ctx: *anyopaque) void {
        const self = ctxOf(ctx);
        _ = c.sqlite3_close(self.db);
        self.hits.deinit(self.backing);
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
        .replacePlaylistTracks = replacePlaylistTracksFn,
        .renamePlaylist = renamePlaylistFn,
        .deletePlaylist = deletePlaylistFn,
        .name = nameFn,
        .deinit = deinitFn,
    };
};

/// Binds one data value. Only the types the write paths carry are supported,
/// so a new kind of value is a compile error rather than a silent NULL.
fn bindValue(stmt: *c.sqlite3_stmt, index: usize, value: anytype) c_int {
    const slot: c_int = @intCast(index);
    if (@TypeOf(value) == comptime_int) return c.sqlite3_bind_int64(stmt, slot, value);
    return switch (@typeInfo(@TypeOf(value))) {
        .pointer => c.sqlite3_bind_text(stmt, slot, value.ptr, @intCast(value.len), null),
        .int => c.sqlite3_bind_int64(stmt, slot, @intCast(value)),
        else => @compileError("unsupported bound value: " ++ @typeName(@TypeOf(value))),
    };
}

fn escapeQuotes(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, allocator, text, "'", "''");
}

/// The playlist is part of the seed: the same track at the same slot in a
/// second playlist must not reuse the first one's row ids, which the
/// djmdSongPlaylist primary key rejects.
fn entrySeed(playlist_id: []const u8, track_id: u64, number: u64) u64 {
    const playlist_hash = std.hash.Wyhash.hash(0, playlist_id);
    const slot = playlist_hash ^ (track_id *% 1_000_003) ^ number;
    return std.hash.Wyhash.hash(slot, std.mem.asBytes(&track_id));
}

/// Keeps an entry's id and its uuid from being the same value.
const entry_uuid_salt: u64 = 0x9e3779b97f4a7c15;

fn makeUuid(allocator: std.mem.Allocator, seed: u64) ![]const u8 {
    var bytes: [16]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
    });
}

fn nowSql() []const u8 {
    return "strftime('%Y-%m-%d %H:%M:%f +00:00', 'now')";
}

fn column(stmt: *c.sqlite3_stmt, index: c_int) []const u8 {
    const p = c.sqlite3_column_text(stmt, index);
    if (p == null) return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, index));
    return p[0..len];
}

pub fn defaultDbPath(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/Library/Pioneer/rekordbox/master.db",
        .{home},
    );
}

pub fn cachedKeyPath(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/Library/Application Support/pyrekordbox/rb.cache",
        .{home},
    );
}

/// Reads the key pyrekordbox cached, so a machine that already uses that tool
/// needs no configuration.
pub fn readCachedKey(allocator: std.mem.Allocator, io: std.Io, cache_path: []const u8) ![]const u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(io, cache_path, allocator, .limited(4096)) catch return Error.NoKey;
    defer allocator.free(text);

    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "dp:")) continue;
        const key = std.mem.trim(u8, line[3..], " \t\r");
        if (key.len == 0) return Error.NoKey;
        return allocator.dupe(u8, key);
    }
    return Error.NoKey;
}

test "the same track at the same slot gets a different id in another playlist" {
    const salome = entrySeed("3566860990", 136106402, 1);
    const heartbreaker = entrySeed("3566860992", 136106402, 1);

    try std.testing.expect(salome != heartbreaker);
    try std.testing.expectEqual(salome, entrySeed("3566860990", 136106402, 1));
    try std.testing.expect(salome != entrySeed("3566860990", 136106402, 2));
}

/// A plain in-memory database, enough to run the write helpers without a
/// collection: SQLCipher opens an unkeyed database as ordinary SQLite.
fn testSource(arena: *std.heap.ArenaAllocator) !Source {
    arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) return error.OpenFailed;
    return .{
        .arena = arena.*,
        .backing = std.testing.allocator,
        .db = db orelse return error.OpenFailed,
        .path = "",
        .io = std.Io.failing,
    };
}

test "values are bound in the order they are given" {
    var arena: std.heap.ArenaAllocator = undefined;
    var source = try testSource(&arena);
    defer source.arena.deinit();
    defer _ = c.sqlite3_close(source.db);

    try source.exec("create table t (id text, name text, n integer)", .{});
    try source.execBound("insert into t values (?1, ?2, ?3)", .{}, .{ "id-1", "it's a name", 42 });

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(source.db, "select id, name, n from t", -1, &stmt, null) != c.SQLITE_OK) return error.QueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    const s = stmt.?;
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(s));
    try std.testing.expectEqualStrings("id-1", column(s, 0));
    // A name with an apostrophe survives because it is bound, not pasted in.
    try std.testing.expectEqualStrings("it's a name", column(s, 1));
    try std.testing.expectEqual(@as(i64, 42), c.sqlite3_column_int64(s, 2));
}

test "a transaction that is rolled back leaves nothing behind" {
    var arena: std.heap.ArenaAllocator = undefined;
    var source = try testSource(&arena);
    defer source.arena.deinit();
    defer _ = c.sqlite3_close(source.db);

    try source.exec("create table t (id integer primary key, name text)", .{});
    try source.beginImmediate();
    try source.execBound("insert into t values (?1, ?2)", .{}, .{ 1, "first" });
    source.rollback();
    try std.testing.expectEqual(@as(u64, 0), try source.queryInt("select count(*) from t"));

    try source.beginImmediate();
    try source.execBound("insert into t values (?1, ?2)", .{}, .{ 2, "second" });
    try source.commit();
    try std.testing.expectEqual(@as(u64, 1), try source.queryInt("select count(*) from t"));
}

test "deleting a playlist that is gone reports it, as the demo source does" {
    var arena: std.heap.ArenaAllocator = undefined;
    var source = try testSource(&arena);
    defer source.arena.deinit();
    defer _ = c.sqlite3_close(source.db);

    try source.exec("create table djmdPlaylist (ID text primary key)", .{});
    try source.exec("create table djmdSongPlaylist (PlaylistID text)", .{});
    const lib = source.port();
    try std.testing.expectError(error.PlaylistNotFound, lib.deletePlaylist("7"));
}

test "replacing tracks in a playlist that is gone reports it" {
    var arena: std.heap.ArenaAllocator = undefined;
    var source = try testSource(&arena);
    defer source.arena.deinit();
    defer _ = c.sqlite3_close(source.db);

    try source.exec("create table djmdPlaylist (ID text primary key, rb_local_usn integer, updated_at text)", .{});
    try source.exec("create table djmdSongPlaylist (PlaylistID text)", .{});
    const lib = source.port();
    try std.testing.expectError(error.PlaylistNotFound, lib.replacePlaylistTracks("7", &.{}));
}
