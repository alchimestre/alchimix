//! Reads a rekordbox 6 collection through the library port.
//!
//! rekordbox stores the collection in a SQLCipher database, so this links
//! libsqlcipher rather than SQLite and opens the file read-only. Nothing here
//! writes: a playlist builder that corrupts a collection is worse than none.

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

    pub fn open(allocator: std.mem.Allocator, options: Options) !Source {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const path = try a.dupe(u8, options.db_path);
        std.Io.Dir.accessAbsolute(options.io, path, .{}) catch return Error.NoDatabase;
        const key = try a.dupe(u8, options.key);

        const path_z = try a.dupeSentinel(u8, path, 0);
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(path_z.ptr, &db, c.SQLITE_OPEN_READONLY, null) != c.SQLITE_OK) {
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

        var self = Source{
            .arena = arena,
            .backing = allocator,
            .db = handle,
            .path = path,
            .io = options.io,
        };
        errdefer self.arena.deinit();
        try self.reload();
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
            const dat_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ root, t.analysis_path });
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
        .name = nameFn,
        .deinit = deinitFn,
    };
};

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
