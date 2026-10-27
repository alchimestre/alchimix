//! Opens the window and drives one frame per event.

const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");
const App = @import("app.zig").App;
const Demo = @import("demo.zig").Demo;

const font_family = "caskaydia";
const mono_family = "caskaydia mono";
const font_file = "CaskaydiaCoveNerdFont-Regular.ttf";
const mono_file = "CaskaydiaMonoNerdFontMono-Regular.ttf";

pub fn run(init: std.process.Init, app: *App) !void {
    var backend = try SDLBackend.initWindow(.{
        .io = init.io,
        .allocator = init.gpa,
        .size = .{ .w = 1180, .h = 720 },
        .min_size = .{ .w = 720, .h = 460 },
        .vsync = true,
        .title = "alchimix",
    });
    defer backend.deinit();
    // Registered after the backend so it runs first: the backend shuts SDL
    // down, and SDL frees the audio stream the pump thread polls.
    defer app.mixer.shutdown();

    const theme = quietTheme(switch (backend.preferredColorScheme() orelse .dark) {
        .light => dvui.Theme.builtin.adwaita_light,
        .dark => dvui.Theme.builtin.adwaita_dark,
    });

    var window_open = true;
    var win = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .theme = theme,
        .open_flag = &window_open,
    });
    defer win.deinit();

    // dvui only accepts a font while a frame is open, so the first frame does it.
    var fonts_ready = false;
    app.loadKeys(init.environ_map.get("HOME"), init.environ_map.get("XDG_CONFIG_HOME"));
    app.startMidi(init.environ_map.get("HOME"), init.environ_map.get("XDG_CONFIG_HOME"));

    var interrupted = false;
    while (window_open) {
        const frame_start = win.beginWait(interrupted);
        try win.begin(frame_start);
        if (try backend.addAllEvents(&win)) break;

        if (!fonts_ready) {
            fonts_ready = true;
            try loadFonts();
        }

        if (!app.frame()) break;

        const frame_end = try win.end(.{});
        // A preview needs frames while it runs: waiting for the next event would
        // leave the bar frozen until something else moved.
        const wait_micros = win.waitTime(frame_end);
        const timeout = if (app.player.animating() or app.animating()) @min(wait_micros, 16_667) else wait_micros;
        interrupted = try backend.waitEventTimeout(timeout);
    }
}

/// Four waveform typologies on synthetic data. No crate, no interaction.
pub fn runWaveformDemo(init: std.process.Init) !void {
    var demo = try Demo.init(init.gpa);
    defer demo.deinit(init.gpa);

    var backend = try SDLBackend.initWindow(.{
        .io = init.io,
        .allocator = init.gpa,
        .size = .{ .w = 1000, .h = 700 },
        .min_size = .{ .w = 760, .h = 620 },
        .vsync = true,
        .title = "alchimix waveform demo",
    });
    defer backend.deinit();

    const theme = quietTheme(switch (backend.preferredColorScheme() orelse .dark) {
        .light => dvui.Theme.builtin.adwaita_light,
        .dark => dvui.Theme.builtin.adwaita_dark,
    });

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
        if (try backend.addAllEvents(&win)) break;
        demo.frame(init.gpa);
        const frame_end = try win.end(.{});
        interrupted = try backend.waitEventTimeout(win.waitTime(frame_end));
    }
}

/// Both faces are compiled in: a machine without the font installed would
/// otherwise render in the theme default, and the arrows and block glyphs the
/// layout is drawn around only exist in a Nerd Font.
fn loadFonts() !void {
    try dvui.addFont(font_family, @embedFile("../assets/" ++ font_file), null);
    try dvui.addFont(mono_family, @embedFile("../assets/" ++ mono_file), null);

    var theme = dvui.themeGet();
    theme.font_body = theme.font_body.withFamily(font_family);
    theme.font_heading = theme.font_heading.withFamily(font_family);
    theme.font_title = theme.font_title.withFamily(font_family);
    theme.font_mono = theme.font_mono.withFamily(mono_family);
    dvui.themeSet(theme);
}

/// Focus rings are noise on a surface driven by the mouse: the ring drew a red
/// box around whichever slider was last clicked.
fn quietTheme(base: dvui.Theme) dvui.Theme {
    var theme = base;
    theme.focus = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    return theme;
}
