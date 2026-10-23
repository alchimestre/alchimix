//! Draws one fixed frame through the DMT fold and holds it on screen.
//!
//! The frame is a grid of coloured squares on flat grey and every parameter of
//! the fold is a constant, so two runs render the same pixels. That is what
//! makes one backend comparable against another: capture the window, diff the
//! two images.

const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");
const dmt = @import("dmt.zig");
const geom = @import("geom.zig");

const window_size = dvui.Size{ .w = 900, .h = 600 };

/// Fixed fold parameters: clock at rest, no heart, no mirror, six facets.
const fold_shade: f32 = 0.55;
const fold_rings: f32 = 6;
const fold_mirrors: f32 = 0;
const fold_heart: f32 = 0;

const grey = dvui.Color{ .r = 0x80, .g = 0x80, .b = 0x80, .a = 0xff };
const palette = [_]dvui.Color{
    .{ .r = 0xff, .g = 0x20, .b = 0x20, .a = 0xff },
    .{ .r = 0x20, .g = 0xc0, .b = 0x40, .a = 0xff },
    .{ .r = 0x20, .g = 0x60, .b = 0xff, .a = 0xff },
    .{ .r = 0xff, .g = 0xe0, .b = 0x20, .a = 0xff },
    .{ .r = 0x20, .g = 0xe0, .b = 0xe0, .a = 0xff },
    .{ .r = 0xe0, .g = 0x40, .b = 0xff, .a = 0xff },
    .{ .r = 0xff, .g = 0x90, .b = 0x20, .a = 0xff },
    .{ .r = 0xf0, .g = 0xf0, .b = 0xf0, .a = 0xff },
};

const columns = 8;
const rows = 5;

pub fn main(init: std.process.Init) !void {
    // The two backends take different init fields, so only the shared ones are
    // set here and the rest are added when the field exists.
    var options: SDLBackend.InitOptions = .{
        .io = init.io,
        .size = window_size,
        .vsync = false,
        .title = "alchimix render check",
    };
    if (@hasField(SDLBackend.InitOptions, "allocator")) options.allocator = init.gpa;
    if (@hasField(SDLBackend.InitOptions, "environ_map")) options.environ_map = init.environ_map;

    var backend = try SDLBackend.initWindow(options);
    defer backend.deinit();

    var window_open = true;
    var win = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{ .open_flag = &window_open });
    defer win.deinit();

    var target: ?dvui.Texture.Target = null;
    defer if (target) |made| made.destroyLater();

    var interrupted = false;
    while (window_open) {
        const frame_start = win.beginWait(interrupted);
        try win.begin(frame_start);
        const events = try backend.addAllEvents(&win);
        if (@TypeOf(events) == bool and events) break;

        const rect = dvui.currentWindow().rect_pixels;
        const size = dvui.Size.Physical{ .w = rect.w, .h = rect.h };
        const arena = dvui.currentWindow().arena();

        const evidence = target orelse made: {
            target = try dvui.Texture.Target.create(.{
                .width = @intFromFloat(@max(1, size.w)),
                .height = @intFromFloat(@max(1, size.h)),
            });
            break :made target.?;
        };

        const previous = dvui.RenderTarget.setAsCurrent(.{ .texture = evidence, .offset = .{} });
        drawPattern(arena, size) catch {};
        _ = dvui.RenderTarget.setAsCurrent(previous);

        try dmt.draw(
            try dvui.textureFromTarget(evidence),
            arena,
            .{},
            size,
            &.{},
            fold_shade,
            0,
            fold_rings,
            fold_heart,
            fold_mirrors,
        );

        const frame_end = try win.end(.{});
        interrupted = try backend.waitEventTimeout(@max(win.waitTime(frame_end), 16_667));
    }
}

/// Grey ground with a centred grid of coloured squares, drawn as one mesh.
fn drawPattern(arena: std.mem.Allocator, size: dvui.Size.Physical) !void {
    var quads: std.ArrayListUnmanaged(geom.Quad) = .empty;
    try quads.append(arena, .{
        .rect = .{ .x = 0, .y = 0, .w = size.w, .h = size.h },
        .colour = grey,
    });

    const cell = @min(size.w / (columns * 2.4), size.h / (rows * 2.4));
    const gap = cell * 0.12;
    const grid_w = @as(f32, @floatFromInt(columns)) * (cell + gap) - gap;
    const grid_h = @as(f32, @floatFromInt(rows)) * (cell + gap) - gap;
    const left = (size.w - grid_w) / 2;
    const top = (size.h - grid_h) / 2;

    for (0..rows) |row| {
        for (0..columns) |column| {
            const x = left + @as(f32, @floatFromInt(column)) * (cell + gap);
            const y = top + @as(f32, @floatFromInt(row)) * (cell + gap);
            try quads.append(arena, .{
                .rect = .{ .x = x, .y = y, .w = cell, .h = cell },
                .colour = palette[(row * columns + column) % palette.len],
            });
        }
    }

    const mesh = try geom.solidQuads(arena, quads.items);
    try dvui.renderTriangles(.{
        .vertexes = mesh.vertexes,
        .indices = mesh.indices,
        .bounds = .{ .x = 0, .y = 0, .w = size.w, .h = size.h },
    }, null);
}
