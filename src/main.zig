const std = @import("std");
const pl = @import("playlister");
const runApp = @import("ui/run.zig").run;
const runWaveformDemo = @import("ui/run.zig").runWaveformDemo;
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
    if (std.mem.eql(u8, command, "mix")) {
        return renderMix(init, &args);
    }
    if (std.mem.eql(u8, command, "waveform-demo")) {
        return runWaveformDemo(init);
    }
    if (std.mem.eql(u8, command, "playlists")) {
        return showPlaylists(init);
    }
    if (std.mem.eql(u8, command, "playlist-save")) {
        return savePlaylist(init, args.next() orelse "", &args);
    }
    usage();
}

fn showPlaylists(init: std.process.Init) !void {
    var collection: ?pl.rekordbox.Source = null;
    var demo: pl.memory.Source = undefined;
    const library = try openLibrary(init, &collection, &demo);
    defer library.deinit();
    for (try library.playlists()) |playlist| {
        const kind = if (playlist.folder) "folder" else "list";
        std.debug.print("{s}\t{s}\t{s}\n", .{ playlist.id, kind, playlist.name });
    }
}

fn savePlaylist(init: std.process.Init, name: []const u8, args: *std.process.Args.Iterator) !void {
    var ids: [256]u64 = undefined;
    var count: usize = 0;
    while (args.next()) |text| {
        if (count >= ids.len) break;
        ids[count] = std.fmt.parseInt(u64, text, 10) catch continue;
        count += 1;
    }
    if (count == 0) return error.NoTracks;

    var collection: ?pl.rekordbox.Source = null;
    var demo: pl.memory.Source = undefined;
    const library = try openLibrary(init, &collection, &demo);
    defer library.deinit();
    try library.createPlaylist(name, ids[0..count]);
    std.debug.print("saved {d} tracks to {s}\n", .{ count, name });
}

fn openCanvas(init: std.process.Init) !void {
    var collection: ?pl.rekordbox.Source = null;
    var demo: pl.memory.Source = undefined;

    const library = try openLibrary(init, &collection, &demo);
    defer library.deinit();

    var app = try App.init(init.gpa, library, init.io);
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
        \\  mix <out> <s> <files...>  render the mixer to raw f32le, no window
        \\  playlists          list rekordbox playlists and folders
        \\  playlist-save <name> <ids...>  create a playlist from track ids
        \\  waveform-demo      compare four lane waveform renderings
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

/// Renders the mixer's own output to a raw file so it can be compared with a
/// reference render. No window, no audio device.
fn renderMix(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const out_path = args.next() orelse return error.MissingOutput;
    const seconds = try std.fmt.parseFloat(f64, args.next() orelse "5");

    var mixer = pl.mixer.Mixer.init(init.gpa, init.io);
    defer mixer.deinit();

    var lanes: [8]pl.mixer.Lane = undefined;
    var count: usize = 0;
    while (args.next()) |spec| {
        if (count >= lanes.len) break;

        // `file`, or `file@start_seconds@tempo`, optionally followed by
        // `@low,mid,high` gains in dB.
        var parts = std.mem.splitScalar(u8, spec, '@');
        const path = parts.next() orelse continue;
        const start = if (parts.next()) |text| std.fmt.parseFloat(f64, text) catch 0 else 0;
        const tempo = if (parts.next()) |text| std.fmt.parseFloat(f32, text) catch 1 else 1;
        var eq: pl.mixer.EqParams = .{};
        if (parts.next()) |text| {
            var gains = std.mem.splitScalar(u8, text, ',');
            for (&eq.gain_db) |*gain| gain.* = if (gains.next()) |value| std.fmt.parseFloat(f32, value) catch 0 else 0;
        }

        var track = pl.track.Track.init(count + 1, "", "");
        track.file_path = path;
        lanes[count] = .{
            .track = track,
            .start_s = start,
            .tempo = tempo,
            .eq = eq,
            .keylock = true,
        };
        count += 1;
    }
    if (count == 0) return error.NoInputs;

    const file = try std.Io.Dir.cwd().createFile(init.io, out_path, .{});
    defer file.close(init.io);
    try mixer.render(lanes[0..count], seconds, file);
    std.debug.print("rendered\n", .{});
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
