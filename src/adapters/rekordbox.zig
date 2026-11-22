//! Reads and writes a rekordbox 6 collection through the library port.
//!
//! rekordbox stores the collection in a SQLCipher database, so this links
//! libsqlcipher rather than SQLite. A write that touches more than one row
//! runs in one transaction: a half-written playlist is worse than a refused
//! save. A write is also refused while rekordbox runs, and every row it
//! writes takes the next local update number, as pyrekordbox does.

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
    /// rekordbox holds the collection open and would overwrite a write.
    RekordboxRunning,
    /// The playlist changed since the caller loaded it.
    StalePlaylist,
    PlaylistNotFound,
    ParentNotFound,
    NoLocalUsn,
    NoFreeId,
    ValueOutOfRange,
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

const RunningCheck = *const fn (std.mem.Allocator, std.Io) anyerror!bool;

pub const Source = struct {
    arena: std.heap.ArenaAllocator,
    backing: std.mem.Allocator,
    db: *c.sqlite3,
    path: []const u8,
    io: std.Io,
    items: std.ArrayListUnmanaged(Track) = .empty,
    hits: std.ArrayListUnmanaged(Track) = .empty,
    playlists: std.ArrayListUnmanaged(library.Playlist) = .empty,
    /// Set when a refresh after a commit failed: the rows lag the database
    /// until the next successful reload.
    playlists_stale: bool = false,
    running_check: RunningCheck = rekordboxRunning,

    pub fn open(allocator: std.mem.Allocator, options: Options) !Source {
        var self = Source{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .backing = allocator,
            .db = undefined,
            .path = "",
            .io = options.io,
        };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();

        self.path = try a.dupe(u8, options.db_path);
        std.Io.Dir.accessAbsolute(options.io, self.path, .{}) catch return Error.NoDatabase;

        const path_z = try a.dupeSentinel(u8, self.path, 0);
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(path_z.ptr, &db, c.SQLITE_OPEN_READWRITE, null) != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return Error.OpenFailed;
        }
        const handle = db.?;
        errdefer _ = c.sqlite3_close(handle);

        // PRAGMA takes no bound parameters, so the key goes in as an escaped
        // literal.
        const escaped = try std.mem.replaceOwned(u8, a, options.key, "'", "''");
        const pragma = try std.fmt.allocPrintSentinel(a, "PRAGMA key = '{s}';", .{escaped}, 0);
        if (c.sqlite3_exec(handle, pragma.ptr, null, null, null) != c.SQLITE_OK) return Error.KeyRejected;

        // rekordbox and its agent write to the same file. Without a timeout any
        // concurrent write fails instantly, which is how a save ends up empty.
        if (c.sqlite3_exec(handle, "PRAGMA busy_timeout = 5000;", null, null, null) != c.SQLITE_OK) return Error.OpenFailed;

        self.db = handle;
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

            const id = std.math.cast(u64, c.sqlite3_column_int64(s, 0)) orelse return Error.ValueOutOfRange;
            var t = Track.init(
                id,
                try a.dupe(u8, column(s, 1)),
                try a.dupe(u8, column(s, 2)),
            );
            t.bpm_centi = std.math.cast(u32, @max(0, c.sqlite3_column_int64(s, 3))) orelse return Error.ValueOutOfRange;
            const scale = column(s, 4);
            if (scale.len > 0) t.key = camelot.parse(scale) catch null;
            t.length_s = std.math.cast(u32, @max(0, c.sqlite3_column_int64(s, 5))) orelse return Error.ValueOutOfRange;
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
            \\select ID, Name, ParentID, Attribute, Seq, coalesce(UUID, '')
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
                .kind = kindOf(attribute),
                .seq = c.sqlite3_column_int64(s, 4),
                .uuid = try a.dupe(u8, column(s, 5)),
            });
        }
        self.playlists_stale = false;
    }

    /// The write is already committed; a refresh that fails here must not make
    /// it look like the write failed, so the next read retries it.
    fn afterCommit(self: *Source) void {
        self.reloadPlaylists() catch |err| {
            std.log.warn("rekordbox playlists not refreshed after commit: {s}", .{@errorName(err)});
            self.playlists_stale = true;
        };
    }

    fn playlistsFn(ctx: *anyopaque) anyerror![]const library.Playlist {
        const self = ctxOf(ctx);
        if (self.playlists_stale) try self.reloadPlaylists();
        return self.playlists.items;
    }

    fn playlistTracksFn(ctx: *anyopaque, allocator: std.mem.Allocator, playlist_id: []const u8) anyerror![]const u64 {
        return ctxOf(ctx).membership(allocator, playlist_id);
    }

    fn membership(self: *Source, allocator: std.mem.Allocator, playlist_id: []const u8) ![]u64 {
        var out: std.ArrayListUnmanaged(u64) = .empty;
        errdefer out.deinit(allocator);

        const sql = "select ContentID from djmdSongPlaylist where PlaylistID = ?1 and rb_local_deleted = 0 order by TrackNo";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return self.statementFailed(sql);
        defer _ = c.sqlite3_finalize(stmt);
        const s = stmt.?;
        if (bindValue(s, 1, playlist_id) != c.SQLITE_OK) return self.statementFailed(sql);
        while (true) {
            const rc = c.sqlite3_step(s);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return self.statementFailed(sql);
            const id = std.math.cast(u64, c.sqlite3_column_int64(s, 0)) orelse return Error.ValueOutOfRange;
            try out.append(allocator, id);
        }
        return out.toOwnedSlice(allocator);
    }

    fn createPlaylistFn(ctx: *anyopaque, playlist_name: []const u8, track_ids: []const u64) anyerror!void {
        const fresh = library.Playlist{ .id = "", .name = playlist_name, .parent = "root", .kind = .list };
        return ctxOf(ctx).insertPlaylist(fresh, track_ids);
    }

    fn restorePlaylistFn(ctx: *anyopaque, playlist: library.Playlist, track_ids: []const u64) anyerror!void {
        return ctxOf(ctx).insertPlaylist(playlist, track_ids);
    }

    /// Takes the id and uuid the playlist carries while they are free, and a
    /// new random pair otherwise: a freed id is never handed to another playlist
    /// by chance of a counter.
    fn insertPlaylist(self: *Source, playlist: library.Playlist, track_ids: []const u64) !void {
        try self.refuseWhileRunning();
        try self.beginImmediate();
        errdefer self.rollback();
        try self.requireParent(playlist.parent);

        const needs_new_id = playlist.id.len == 0 or
            (try self.queryInt("select count(*) from djmdPlaylist where ID = ?1", .{playlist.id})) != 0;
        const id = if (needs_new_id) try self.unusedId() else playlist.id;
        const keeps_uuid = !needs_new_id and playlist.uuid.len > 0;
        const uuid = if (keeps_uuid) playlist.uuid else try makeUuid(self.arena.allocator(), self.io);
        const seq = try self.openSlot(playlist.parent, playlist.seq);
        const usn = try self.nextUsn();
        try self.execBound(
            "insert into djmdPlaylist (ID, Seq, Name, ParentID, Attribute, UUID, rb_local_usn, created_at, updated_at) " ++
                "values (?1, {d}, ?2, ?3, {d}, ?4, {d}, {s}, {s})",
            .{ seq, attributeOf(playlist.kind), usn, nowSql(), nowSql() },
            .{ id, playlist.name, playlist.parent, uuid },
        );
        for (track_ids, 1..) |track_id, number| try self.appendEntry(id, track_id, number);
        try self.commit();
        self.afterCommit();
    }

    fn requireParent(self: *Source, parent_id: []const u8) !void {
        if (std.mem.eql(u8, parent_id, root_id)) return;
        const folders = try self.queryInt(
            "select count(*) from djmdPlaylist where ID = ?1 and Attribute = 1 and rb_local_deleted = 0",
            .{parent_id},
        );
        if (folders == 0) return Error.ParentNotFound;
    }

    /// The sequence a new playlist takes under its parent: the one asked for,
    /// with the siblings from there shifted up, or the end.
    fn openSlot(self: *Source, parent_id: []const u8, wanted: i64) !i64 {
        const last = try self.queryInt("select coalesce(max(Seq), 0) from djmdPlaylist where ParentID = ?1", .{parent_id});
        if (wanted < 1 or wanted > last) return last + 1;
        const usn = try self.nextUsn();
        try self.execBound(
            "update djmdPlaylist set Seq = Seq + 1, rb_local_usn = {d}, updated_at = {s} where ParentID = ?1 and Seq >= ?2",
            .{ usn, nowSql() },
            .{ parent_id, wanted },
        );
        return wanted;
    }

    fn unusedId(self: *Source) ![]const u8 {
        for (0..id_attempts) |_| {
            var bytes: [4]u8 = undefined;
            self.io.random(&bytes);
            const candidate = std.mem.readInt(u32, &bytes, .big) >> id_shift;
            if (candidate < min_playlist_id) continue;
            const text = try std.fmt.allocPrint(self.arena.allocator(), "{d}", .{candidate});
            if ((try self.queryInt("select count(*) from djmdPlaylist where ID = ?1", .{text})) == 0) return text;
        }
        return Error.NoFreeId;
    }

    fn replacePlaylistTracksFn(ctx: *anyopaque, playlist_id: []const u8, expected: []const u64, track_ids: []const u64) anyerror!void {
        const self = ctxOf(ctx);
        try self.refuseWhileRunning();
        try self.beginImmediate();
        errdefer self.rollback();
        const lists = try self.queryInt(
            "select count(*) from djmdPlaylist where ID = ?1 and Attribute = 0 and rb_local_deleted = 0",
            .{playlist_id},
        );
        if (lists == 0) return Error.PlaylistNotFound;

        const current = try self.membership(self.backing, playlist_id);
        defer self.backing.free(current);
        if (!std.mem.eql(u64, current, expected)) return Error.StalePlaylist;

        try self.execBound("delete from djmdSongPlaylist where PlaylistID = ?1", .{}, .{playlist_id});
        for (track_ids, 1..) |track_id, number| try self.appendEntry(playlist_id, track_id, number);
        const usn = try self.nextUsn();
        try self.execBound(
            "update djmdPlaylist set rb_local_usn = {d}, updated_at = {s} where ID = ?1",
            .{ usn, nowSql() },
            .{playlist_id},
        );
        try self.commit();
        self.afterCommit();
    }

    fn renamePlaylistFn(ctx: *anyopaque, playlist_id: []const u8, playlist_name: []const u8) anyerror!void {
        const self = ctxOf(ctx);
        try self.refuseWhileRunning();
        try self.beginImmediate();
        errdefer self.rollback();
        const usn = try self.nextUsn();
        try self.execBound(
            "update djmdPlaylist set Name = ?1, rb_local_usn = {d}, updated_at = {s} where ID = ?2 and rb_local_deleted = 0",
            .{ usn, nowSql() },
            .{ playlist_name, playlist_id },
        );
        if (c.sqlite3_changes(self.db) != 1) return Error.PlaylistNotFound;
        try self.commit();
        self.afterCommit();
    }

    fn deletePlaylistFn(ctx: *anyopaque, playlist_id: []const u8) anyerror!void {
        const self = ctxOf(ctx);
        try self.refuseWhileRunning();
        try self.beginImmediate();
        errdefer self.rollback();
        // An id that was already gone is an error here too, as it is on the
        // demo source: a save that silently did nothing is worse than a refusal.
        const present = try self.queryInt(
            "select count(*) from djmdPlaylist where ID = ?1 and rb_local_deleted = 0",
            .{playlist_id},
        );
        if (present == 0) return Error.PlaylistNotFound;

        const usn = try self.nextUsn();
        try self.execBound(
            "update djmdPlaylist set Seq = Seq - 1, rb_local_usn = {d}, updated_at = {s} " ++
                "where rb_local_deleted = 0 and ParentID = (select ParentID from djmdPlaylist where ID = ?1) " ++
                "and Seq > (select Seq from djmdPlaylist where ID = ?1)",
            .{ usn, nowSql() },
            .{playlist_id},
        );
        try self.execBound("delete from djmdSongPlaylist where PlaylistID = ?1", .{}, .{playlist_id});
        try self.execBound("delete from djmdPlaylist where ID = ?1", .{}, .{playlist_id});
        try self.commit();
        self.afterCommit();
    }

    fn appendEntry(self: *Source, playlist_id: []const u8, track_id: u64, number: usize) !void {
        const a = self.arena.allocator();
        const entry_id = try makeUuid(a, self.io);
        const uuid = try makeUuid(a, self.io);
        const usn = try self.nextUsn();
        try self.execBound(
            "insert into djmdSongPlaylist (ID, PlaylistID, ContentID, TrackNo, UUID, rb_local_usn, created_at, updated_at) " ++
                "values (?1, ?2, ?3, ?4, ?5, {d}, {s}, {s})",
            .{ usn, nowSql(), nowSql() },
            .{ entry_id, playlist_id, track_id, number, uuid },
        );
    }

    /// rekordbox keeps its own copy of the collection in memory and writes it
    /// back; an edit made underneath it is lost or corrupts the file.
    fn refuseWhileRunning(self: *Source) !void {
        if (try self.running_check(self.backing, self.io)) return Error.RekordboxRunning;
    }

    /// The next value of rekordbox's global local update counter, which every
    /// row written takes as its `rb_local_usn`, as pyrekordbox does.
    fn nextUsn(self: *Source) !i64 {
        try self.exec("update agentRegistry set int_1 = coalesce(int_1, 0) + 1 where registry_id = 'localUpdateCount'");
        if (c.sqlite3_changes(self.db) != 1) return Error.NoLocalUsn;
        return self.queryInt("select int_1 from agentRegistry where registry_id = 'localUpdateCount'", .{});
    }

    /// Takes the write lock for the one transaction a save runs in, so the
    /// playlist header and its rows land together or not at all.
    fn beginImmediate(self: *Source) !void {
        try self.exec("begin immediate");
    }

    /// Static SQL: a rollback that formats a string can fail to allocate and
    /// leave the transaction open.
    fn rollback(self: *Source) void {
        self.exec("rollback") catch {};
    }

    /// A commit that fails still has to end the transaction, or every later
    /// write fails with it.
    fn commit(self: *Source) !void {
        self.exec("commit") catch |err| {
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

    /// Runs one statement and returns its first column, with its data values
    /// bound in order.
    fn queryInt(self: *Source, sql: [:0]const u8, params: anytype) !i64 {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return self.statementFailed(sql);
        defer _ = c.sqlite3_finalize(stmt);
        const s = stmt.?;
        inline for (params, 1..) |value, index| {
            if (bindValue(s, index, value) != c.SQLITE_OK) return self.statementFailed(sql);
        }
        if (c.sqlite3_step(s) != c.SQLITE_ROW) return self.statementFailed(sql);
        return c.sqlite3_column_int64(s, 0);
    }

    fn exec(self: *Source, sql: [:0]const u8) !void {
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
        .restorePlaylist = restorePlaylistFn,
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
    const slot = std.math.cast(c_int, index) orelse return c.SQLITE_RANGE;
    if (@TypeOf(value) == comptime_int) return c.sqlite3_bind_int64(stmt, slot, value);
    return switch (@typeInfo(@TypeOf(value))) {
        .pointer => bindText(stmt, slot, value),
        .int => bindInt(stmt, slot, value),
        else => @compileError("unsupported bound value: " ++ @typeName(@TypeOf(value))),
    };
}

fn bindText(stmt: *c.sqlite3_stmt, slot: c_int, text: []const u8) c_int {
    const len = std.math.cast(c_int, text.len) orelse return c.SQLITE_TOOBIG;
    return c.sqlite3_bind_text(stmt, slot, text.ptr, len, null);
}

fn bindInt(stmt: *c.sqlite3_stmt, slot: c_int, number: anytype) c_int {
    const value = std.math.cast(i64, number) orelse return c.SQLITE_RANGE;
    return c.sqlite3_bind_int64(stmt, slot, value);
}

const root_id = "root";
const min_playlist_id = 100;
const id_attempts = 1000;
/// rekordbox ids are 28 bits wide, as pyrekordbox generates them.
const id_shift = 4;

/// rekordbox's attribute column: 1 is a folder, 4 an intelligent playlist.
fn kindOf(attribute: c_int) library.PlaylistKind {
    return switch (attribute) {
        1 => .folder,
        4 => .smart,
        else => .list,
    };
}

fn attributeOf(kind: library.PlaylistKind) u8 {
    return switch (kind) {
        .folder => 1,
        .smart => 4,
        .list => 0,
    };
}

/// pgrep exits 0 on a match and 1 on none; anything else means the process
/// list could not be read, which refuses the write like a match does.
fn rekordboxRunning(allocator: std.mem.Allocator, io: std.Io) anyerror!bool {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "pgrep", "-x", "rekordbox" } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| switch (code) {
            0 => true,
            1 => false,
            else => error.ProcessListFailed,
        },
        else => error.ProcessListFailed,
    };
}

fn makeUuid(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
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
    const len = std.math.cast(usize, c.sqlite3_column_bytes(stmt, index)) orelse return "";
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

/// The slice of rekordbox's schema the write paths touch.
const test_schema =
    \\create table agentRegistry (registry_id text primary key, int_1 integer);
    \\insert into agentRegistry values ('localUpdateCount', 100);
    \\create table djmdPlaylist (ID text primary key, Seq integer, Name text, ParentID text, Attribute integer,
    \\    UUID text, rb_local_usn integer, rb_local_deleted integer default 0, created_at text, updated_at text);
    \\create table djmdSongPlaylist (ID text primary key, PlaylistID text, ContentID integer, TrackNo integer,
    \\    UUID text, rb_local_usn integer, rb_local_deleted integer default 0, created_at text, updated_at text);
;

fn notRunning(_: std.mem.Allocator, _: std.Io) anyerror!bool {
    return false;
}

fn alwaysRunning(_: std.mem.Allocator, _: std.Io) anyerror!bool {
    return true;
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
        .io = std.testing.io,
        .running_check = notRunning,
    };
}

fn rowNamed(lib: library.Library, name: []const u8) !library.Playlist {
    for (try lib.playlists()) |playlist| {
        if (std.mem.eql(u8, playlist.name, name)) return playlist;
    }
    return error.PlaylistNotFound;
}

test "values are bound in the order they are given" {
    var arena: std.heap.ArenaAllocator = undefined;
    var source = try testSource(&arena);
    defer source.arena.deinit();
    defer _ = c.sqlite3_close(source.db);

    try source.exec("create table t (id text, name text, n integer)");
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

test "a value too wide for SQLite is refused rather than wrapped" {
    var arena: std.heap.ArenaAllocator = undefined;
    var source = try testSource(&arena);
    defer source.arena.deinit();
    defer _ = c.sqlite3_close(source.db);

    try source.exec("create table t (n integer)");
    var stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(source.db, "insert into t values (?1)", -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    const too_wide: u64 = std.math.maxInt(u64);
    try std.testing.expectEqual(c.SQLITE_RANGE, bindValue(stmt.?, 1, too_wide));
    try std.testing.expectEqual(c.SQLITE_OK, bindValue(stmt.?, 1, @as(u64, 7)));
}

test "a transaction that is rolled back leaves nothing behind" {
    var arena: std.heap.ArenaAllocator = undefined;
    var source = try testSource(&arena);
    defer source.arena.deinit();
    defer _ = c.sqlite3_close(source.db);

    try source.exec("create table t (id integer primary key, name text)");
    try source.beginImmediate();
    try source.execBound("insert into t values (?1, ?2)", .{}, .{ 1, "first" });
    source.rollback();
    try std.testing.expectEqual(@as(i64, 0), try source.queryInt("select count(*) from t", .{}));

    try source.beginImmediate();
    try source.execBound("insert into t values (?1, ?2)", .{}, .{ 2, "second" });
    try source.commit();
    try std.testing.expectEqual(@as(i64, 1), try source.queryInt("select count(*) from t", .{}));
}

test "deleting a playlist that is gone reports it, as the demo source does" {
    var arena: std.heap.ArenaAllocator = undefined;
    var source = try testSource(&arena);
    defer source.arena.deinit();
    defer _ = c.sqlite3_close(source.db);

    try source.exec(test_schema);
    const lib = source.port();
    try std.testing.expectError(error.PlaylistNotFound, lib.deletePlaylist("7"));
}

test "replacing tracks in a playlist that is gone reports it" {
    var arena: std.heap.ArenaAllocator = undefined;
    var source = try testSource(&arena);
    defer source.arena.deinit();
    defer _ = c.sqlite3_close(source.db);

    try source.exec(test_schema);
    const lib = source.port();
    try std.testing.expectError(error.PlaylistNotFound, lib.replacePlaylistTracks("7", &.{}, &.{}));
}

test "a crate longer than 256 tracks saves and loads back whole" {
    var arena: std.heap.ArenaAllocator = undefined;
    var source = try testSource(&arena);
    defer source.arena.deinit();
    defer _ = c.sqlite3_close(source.db);
    try source.exec(test_schema);
    const lib = source.port();

    var crate: [300]u64 = undefined;
    for (&crate, 0..) |*id, index| id.* = 1000 + index;
    try lib.createPlaylist("Long", &crate);

    const playlist = try rowNamed(lib, "Long");
    const loaded = try lib.playlistTracks(std.testing.allocator, playlist.id);
    defer std.testing.allocator.free(loaded);
    try std.testing.expectEqualSlices(u64, &crate, loaded);

    var longer: [301]u64 = undefined;
    for (&longer, 0..) |*id, index| id.* = 5000 - index;
    try lib.replacePlaylistTracks(playlist.id, loaded, &longer);

    const reloaded = try lib.playlistTracks(std.testing.allocator, playlist.id);
    defer std.testing.allocator.free(reloaded);
    try std.testing.expectEqualSlices(u64, &longer, reloaded);
}

test "every row written takes the next local update number" {
    var arena: std.heap.ArenaAllocator = undefined;
    var source = try testSource(&arena);
    defer source.arena.deinit();
    defer _ = c.sqlite3_close(source.db);
    try source.exec(test_schema);
    const lib = source.port();

    try lib.createPlaylist("Usn", &.{ 1, 2 });
    const counter = try source.queryInt("select int_1 from agentRegistry where registry_id = 'localUpdateCount'", .{});
    // One header and two entries.
    try std.testing.expectEqual(@as(i64, 103), counter);
    const highest = try source.queryInt("select max(rb_local_usn) from djmdSongPlaylist", .{});
    try std.testing.expect(highest <= counter);
    try std.testing.expect(highest > 100);
}

test "a replace against a playlist that changed underneath is refused" {
    var arena: std.heap.ArenaAllocator = undefined;
    var source = try testSource(&arena);
    defer source.arena.deinit();
    defer _ = c.sqlite3_close(source.db);
    try source.exec(test_schema);
    const lib = source.port();

    try lib.createPlaylist("Shared", &.{ 1, 2, 3 });
    const playlist = try rowNamed(lib, "Shared");

    try std.testing.expectError(Error.StalePlaylist, lib.replacePlaylistTracks(playlist.id, &.{ 1, 2 }, &.{9}));
    const unchanged = try lib.playlistTracks(std.testing.allocator, playlist.id);
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, unchanged);

    try source.exec("update djmdPlaylist set rb_local_deleted = 1");
    try std.testing.expectError(Error.PlaylistNotFound, lib.replacePlaylistTracks(playlist.id, &.{ 1, 2, 3 }, &.{9}));
}

test "a deleted playlist comes back under its parent at its position" {
    var arena: std.heap.ArenaAllocator = undefined;
    var source = try testSource(&arena);
    defer source.arena.deinit();
    defer _ = c.sqlite3_close(source.db);
    try source.exec(test_schema);
    try source.exec(
        \\insert into djmdPlaylist (ID, Seq, Name, ParentID, Attribute, UUID, rb_local_usn) values
        \\  ('f', 1, 'Sets', 'root', 1, 'u-f', 1), ('a', 1, 'A', 'f', 0, 'u-a', 1),
        \\  ('b', 2, 'B', 'f', 0, 'u-b', 1), ('c', 3, 'C', 'f', 0, 'u-c', 1)
    );
    try source.reloadPlaylists();
    const lib = source.port();
    try lib.replacePlaylistTracks("b", &.{}, &.{ 7, 8 });

    const snapshot = try rowNamed(lib, "B");
    const tracks = try lib.playlistTracks(std.testing.allocator, snapshot.id);
    defer std.testing.allocator.free(tracks);
    try lib.deletePlaylist("b");
    try std.testing.expectEqual(@as(i64, 2), (try rowNamed(lib, "C")).seq);

    try lib.restorePlaylist(snapshot, tracks);
    const restored = try rowNamed(lib, "B");
    try std.testing.expectEqualStrings("b", restored.id);
    try std.testing.expectEqualStrings("f", restored.parent);
    try std.testing.expectEqualStrings("u-b", restored.uuid);
    try std.testing.expectEqual(@as(i64, 2), restored.seq);
    try std.testing.expectEqual(@as(i64, 3), (try rowNamed(lib, "C")).seq);
    const back = try lib.playlistTracks(std.testing.allocator, "b");
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualSlices(u64, &.{ 7, 8 }, back);

    // The id is taken now, so a second restore must not reuse it.
    try lib.restorePlaylist(snapshot, tracks);
    var copies: usize = 0;
    var kept_id: usize = 0;
    for (try lib.playlists()) |playlist| {
        if (!std.mem.eql(u8, playlist.name, "B")) continue;
        copies += 1;
        if (std.mem.eql(u8, playlist.id, "b")) kept_id += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), copies);
    try std.testing.expectEqual(@as(usize, 1), kept_id);
}

test "writes are refused while rekordbox runs" {
    var arena: std.heap.ArenaAllocator = undefined;
    var source = try testSource(&arena);
    defer source.arena.deinit();
    defer _ = c.sqlite3_close(source.db);
    try source.exec(test_schema);
    const lib = source.port();
    try lib.createPlaylist("Before", &.{1});
    const playlist = try rowNamed(lib, "Before");

    source.running_check = alwaysRunning;
    try std.testing.expectError(Error.RekordboxRunning, lib.createPlaylist("After", &.{1}));
    try std.testing.expectError(Error.RekordboxRunning, lib.restorePlaylist(playlist, &.{1}));
    try std.testing.expectError(Error.RekordboxRunning, lib.replacePlaylistTracks(playlist.id, &.{1}, &.{2}));
    try std.testing.expectError(Error.RekordboxRunning, lib.renamePlaylist(playlist.id, "Renamed"));
    try std.testing.expectError(Error.RekordboxRunning, lib.deletePlaylist(playlist.id));
    try std.testing.expectEqual(@as(i64, 1), try source.queryInt("select count(*) from djmdPlaylist", .{}));
}

fn denyUuidRead(_: ?*anyopaque, action: c_int, _: [*c]const u8, column_name: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
    if (action != c.SQLITE_READ or column_name == null) return c.SQLITE_OK;
    return if (std.mem.eql(u8, std.mem.span(column_name), "UUID")) c.SQLITE_DENY else c.SQLITE_OK;
}

test "a refresh that fails after the commit does not report the write as failed" {
    var arena: std.heap.ArenaAllocator = undefined;
    var source = try testSource(&arena);
    defer source.arena.deinit();
    defer _ = c.sqlite3_close(source.db);
    try source.exec(test_schema);
    const lib = source.port();
    try lib.createPlaylist("Old", &.{1});
    const playlist = try rowNamed(lib, "Old");

    // Only the refresh reads the UUID column, so it alone fails.
    _ = c.sqlite3_set_authorizer(source.db, denyUuidRead, null);
    try lib.renamePlaylist(playlist.id, "New");
    try lib.createPlaylist("Second", &.{2});
    try std.testing.expectError(Error.QueryFailed, lib.playlists());

    _ = c.sqlite3_set_authorizer(source.db, null, null);
    _ = try rowNamed(lib, "New");
    _ = try rowNamed(lib, "Second");
    try std.testing.expectEqual(@as(usize, 2), (try lib.playlists()).len);
}

test "a failed open frees what it took exactly once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "master.db", .data = "" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    const db_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/master.db", .{buffer[0..length]});
    defer std.testing.allocator.free(db_path);

    // The file holds no collection, so the first query after the key fails.
    const failed = Source.open(std.testing.allocator, .{ .io = std.testing.io, .db_path = db_path, .key = "key" });
    try std.testing.expectError(Error.QueryFailed, failed);
}
