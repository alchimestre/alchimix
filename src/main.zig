const std = @import("std");
const pl = @import("playlister");
const runApp = @import("ui/run.zig").run;
const App = @import("ui/app.zig").App;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next(); // argv[0]

    const command = args.next() orelse return openCanvas(init);

    if (std.mem.eql(u8, command, "library")) {
        return showLibrary(init);
    }
    if (std.mem.eql(u8, command, "suggest")) {
        return showSuggestions(init, args.next() orelse "");
    }
    usage();
}

fn openCanvas(init: std.process.Init) !void {
    var collection: ?pl.rekordbox.Source = null;
    var demo: pl.memory.Source = undefined;

    const library = try openLibrary(init, &collection, &demo);
    defer library.deinit();

    var app = App.init(init.gpa, library, init.io);
    defer app.deinit();

    try app.refresh();
    try runApp(init, &app);
}

fn usage() void {
    std.debug.print(
        \\usage: playlister [command]
        \\
        \\  (no command)       open the block canvas
        \\  library            report what the collection holds
        \\  suggest <text>     rank what could follow the first match
        \\
    , .{});
}

/// The rekordbox collection when it can be read, a small demo otherwise, so
/// the window always opens. The source lives in `main`'s frame: the library
/// port hands out a pointer to it.
fn openLibrary(
    init: std.process.Init,
    collection: *?pl.rekordbox.Source,
    demo: *pl.memory.Source,
) !pl.library.Library {
    const home = init.environ_map.get("HOME") orelse return error.NoHome;
    const db_path = try pl.rekordbox.defaultDbPath(init.gpa, home);
    defer init.gpa.free(db_path);

    const maybe_key = resolveKey(init, home) catch null;
    if (maybe_key) |key| {
        defer init.gpa.free(key);
        collection.* = pl.rekordbox.Source.open(init.gpa, .{
            .io = init.io,
            .db_path = db_path,
            .key = key,
        }) catch null;
    }
    if (collection.*) |*source| return source.port();

    demo.* = pl.memory.Source.init(init.gpa);
    try demo.add(1, "Demo One", "Nobody", 12800, "Am");
    try demo.add(2, "Demo Two", "Nobody", 12600, "Em");
    try demo.add(3, "Demo Three", "Nobody", 13000, "C");
    return demo.port();
}

fn resolveKey(init: std.process.Init, home: []const u8) ![]const u8 {
    if (init.environ_map.get("PLAYLISTER_REKORDBOX_KEY")) |k| {
        return init.gpa.dupe(u8, std.mem.trim(u8, k, " \t\r\n"));
    }
    const cache = try pl.rekordbox.cachedKeyPath(init.gpa, home);
    defer init.gpa.free(cache);
    return pl.rekordbox.readCachedKey(init.gpa, init.io, cache);
}

fn showLibrary(init: std.process.Init) !void {
    var out_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &out_buffer);
    const out = &writer.interface;
    defer out.flush() catch {};

    var source = try openCollection(init);
    const lib = source.port();
    defer lib.deinit();

    const tracks = try lib.all();
    var with_key: usize = 0;
    for (tracks) |t| {
        if (t.key != null) with_key += 1;
    }
    try out.print("source: {s}\ntracks: {d}\nwith key: {d}\n", .{ lib.name(), tracks.len, with_key });
}

fn showSuggestions(init: std.process.Init, needle: []const u8) !void {
    var out_buffer: [8192]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &out_buffer);
    const out = &writer.interface;
    defer out.flush() catch {};

    var source = try openCollection(init);
    const lib = source.port();
    defer lib.deinit();

    const hits = try lib.search(needle);
    if (hits.len == 0) {
        try out.print("no track matches \"{s}\"\n", .{needle});
        return;
    }

    const seed = hits[0];
    try out.print("seed: {s} - {s}\n", .{ seed.artist, seed.title });
    try out.print("      {d:.1} bpm\n\n", .{seed.bpm});

    const ranked = try pl.suggest.rank(init.gpa, seed, try lib.all(), .{});
    defer init.gpa.free(ranked);

    try out.print("{d} compatible\n", .{ranked.len});
    for (ranked[0..@min(ranked.len, 10)]) |candidate| {
        const step = candidate.transition;
        const plus: []const u8 = if (step.bpm_delta >= 0) "+" else "";
        try out.print("  {s:<10} {s}{d:.1} bpm   {s} - {s}\n", .{
            step.key.label(),
            plus,
            step.bpm_delta,
            candidate.track.artist,
            candidate.track.title,
        });
    }
}

fn openCollection(init: std.process.Init) !pl.rekordbox.Source {
    const home = init.environ_map.get("HOME") orelse return error.NoHome;
    const db_path = try pl.rekordbox.defaultDbPath(init.gpa, home);
    defer init.gpa.free(db_path);
    const key = try resolveKey(init, home);
    defer init.gpa.free(key);

    return pl.rekordbox.Source.open(init.gpa, .{
        .io = init.io,
        .db_path = db_path,
        .key = key,
    });
}
