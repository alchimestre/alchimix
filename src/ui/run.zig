//! Opens the window and drives one frame per event.

const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");
const App = @import("app.zig").App;
const Demo = @import("demo.zig").Demo;

const font_family = "caskaydia";
const font_file = "CaskaydiaCoveNerdFont-Regular.ttf";

pub fn run(init: std.process.Init, app: *App) !void {
    var backend = try SDLBackend.initWindow(.{
        .io = init.io,
        .environ_map = init.environ_map,
        .size = .{ .w = 1180, .h = 720 },
        .min_size = .{ .w = 720, .h = 460 },
        .vsync = true,
        .title = "playlister",
    });
    defer backend.deinit();

    const theme = switch (backend.preferredColorScheme() orelse .dark) {
        .light => dvui.Theme.builtin.adwaita_light,
        .dark => dvui.Theme.builtin.adwaita_dark,
    };

    var window_open = true;
    var win = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .theme = theme,
        .open_flag = &window_open,
    });
    defer win.deinit();

    // dvui only accepts a font while a frame is open, so the first frame does it.
    var fonts_ready = false;

    var interrupted = false;
    while (window_open) {
        const frame_start = win.beginWait(interrupted);
        try win.begin(frame_start);
        try backend.addAllEvents(&win);

        if (!fonts_ready) {
            fonts_ready = true;
            if (loadNerdFont(init)) {
                applyNerdFont();
                app.arrow_font = true;
            }
        }

        if (!app.frame()) break;

        const frame_end = try win.end(.{});
        // A preview needs frames while it runs: waiting for the next event would
        // leave the bar frozen until something else moved.
        const wait_micros = win.waitTime(frame_end);
        const timeout = if (app.player.animating() or app.animating()) @min(wait_micros, 33_000) else wait_micros;
        interrupted = try backend.waitEventTimeout(timeout);
    }
}

/// Four waveform typologies on synthetic data. No crate, no interaction.
pub fn runWaveformDemo(init: std.process.Init) !void {
    var demo = try Demo.init(init.gpa);
    defer demo.deinit(init.gpa);

    var backend = try SDLBackend.initWindow(.{
        .io = init.io,
        .environ_map = init.environ_map,
        .size = .{ .w = 1000, .h = 700 },
        .min_size = .{ .w = 760, .h = 620 },
        .vsync = true,
        .title = "playlister waveform demo",
    });
    defer backend.deinit();

    const theme = switch (backend.preferredColorScheme() orelse .dark) {
        .light => dvui.Theme.builtin.adwaita_light,
        .dark => dvui.Theme.builtin.adwaita_dark,
    };

    var window_open = true;
    var win = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .theme = theme,
        .open_flag = &window_open,
    });
    defer win.deinit();

    var interrupted = false;
    while (window_open) {
        const frame_start = win.beginWait(interrupted);
        try win.begin(frame_start);
        try backend.addAllEvents(&win);
        demo.frame(init.gpa);
        const frame_end = try win.end(.{});
        interrupted = try backend.waitEventTimeout(win.waitTime(frame_end));
    }
}

fn applyNerdFont() void {
    var theme = dvui.themeGet();
    theme.font_body = theme.font_body.withFamily(font_family);
    theme.font_heading = theme.font_heading.withFamily(font_family);
    theme.font_title = theme.font_title.withFamily(font_family);
    dvui.themeSet(theme);
}

/// The bundled font has no arrow glyph, and a Nerd Font is already installed on
/// most machines that would run this. It is read at runtime rather than
/// embedded, so the repository stays small.
fn loadNerdFont(init: std.process.Init) bool {
    const home = init.environ_map.get("HOME") orelse return false;

    const path = std.fmt.allocPrint(init.gpa, "{s}/Library/Fonts/{s}", .{ home, font_file }) catch return false;
    defer init.gpa.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        init.gpa,
        .limited(8 * 1024 * 1024),
    ) catch return false;

    dvui.addFont(font_family, bytes, init.gpa) catch {
        init.gpa.free(bytes);
        return false;
    };
    return true;
}
