//! Colour schemes and intensity curves for the band waveform, side by side on
//! the same synthetic data. Pick one in `wave_colour.zig`.

const std = @import("std");
const dvui = @import("dvui");
const pl = @import("playlister");
const app = @import("app.zig");
const hit = @import("hit.zig");
const base = @import("demo.zig");
const wave_colour = @import("wave_colour.zig");

const Palette = app.Palette;

const Combo = struct {
    scheme: wave_colour.Scheme,
    curve: wave_colour.Curve,
    label: []const u8,
};

const combos = [_]Combo{
    .{ .scheme = .band_rgb, .curve = .fixed, .label = "rgb · fixed (current lane)" },
    .{ .scheme = .band_rgb_level, .curve = .sqrt, .label = "rgb · level sqrt" },
    .{ .scheme = .band_rgb_level, .curve = .square, .label = "rgb · level square" },
    .{ .scheme = .pastel, .curve = .linear, .label = "pastel · linear" },
    .{ .scheme = .heat, .curve = .linear, .label = "heat · linear" },
    .{ .scheme = .heat, .curve = .square, .label = "heat · square" },
};

pub const Demo = struct {
    source: base.Demo,
    bands: []pl.analysis.Band,

    pub fn init(allocator: std.mem.Allocator) !Demo {
        var source = try base.Demo.init(allocator);
        errdefer source.deinit(allocator);
        const bands = try allocator.alloc(pl.analysis.Band, source.low.len);
        for (bands, 0..) |*band, i| {
            band.* = .{
                .low = @intCast(source.low[i] >> 5),
                .mid = @intCast(source.mid[i] >> 5),
                .high = @intCast(source.high[i] >> 5),
            };
        }
        return .{ .source = source, .bands = bands };
    }

    pub fn deinit(self: Demo, allocator: std.mem.Allocator) void {
        allocator.free(self.bands);
        self.source.deinit(allocator);
    }

    pub fn frame(self: *const Demo, allocator: std.mem.Allocator) void {
        var builder = dvui.Path.Builder.init(allocator);
        defer builder.deinit();

        var root = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = true,
            .color_fill = .{ .color = Palette.background },
            .padding = .{ .x = 16, .y = 10 },
        });
        defer root.deinit();

        dvui.labelNoFmt(@src(), "waveform colours · same synthetic bands · six schemes and curves", .{}, .{
            .font = dvui.themeGet().font_title,
            .color_text = .{ .color = Palette.purple },
            .margin = .{ .x = 2, .y = 4 },
            .id_extra = 1,
        });

        for (0..3) |row| {
            var line = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .min_size_content = .{ .h = 196 },
                .id_extra = 10 + row,
            });
            defer line.deinit();
            self.panel(&builder, &combos[row * 2], row * 2 + 2);
            self.panel(&builder, &combos[row * 2 + 1], row * 2 + 3);
        }
    }

    fn panel(self: *const Demo, builder: *dvui.Path.Builder, combo: *const Combo, id: usize) void {
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .margin = .{ .x = 6, .y = 4 },
            .id_extra = id * 10,
        });
        defer col.deinit();

        dvui.labelNoFmt(@src(), combo.label, .{}, .{
            .font = dvui.themeGet().font_body,
            .color_text = .{ .color = Palette.secondary },
            .margin = .{ .x = 2, .y = 2 },
            .id_extra = id * 10 + 1,
        });

        var canvas = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .id_extra = id * 10 + 2,
        });
        defer canvas.deinit();

        const physical = canvas.data().contentRectScale().r;
        const rect = hit.Rect{ .x = physical.x, .y = physical.y, .w = physical.w, .h = physical.h };
        if (rect.w <= 4 or rect.h <= 4) return;

        app.fillRectInto(builder, rect.x, rect.y, rect.w, rect.h, Palette.field);

        const step: f32 = 6;
        const len = self.bands.len;
        var x: f32 = 0;
        while (x < rect.w) : (x += step) {
            const from: usize = @intFromFloat(x / rect.w * @as(f32, @floatFromInt(len)));
            const to: usize = @min(len, @as(usize, @intFromFloat(@min(x + step, rect.w) / rect.w * @as(f32, @floatFromInt(len)))) + 1);
            if (to <= from) continue;

            var low: f32 = 0;
            var mid: f32 = 0;
            var high: f32 = 0;
            var sum: usize = 0;
            for (self.bands[from..to], from..to) |band, i| {
                low += @floatFromInt(band.low);
                mid += @floatFromInt(band.mid);
                high += @floatFromInt(band.high);
                sum += self.source.samples[i];
            }
            const count = @as(f32, @floatFromInt(to - from));
            const level = @as(f32, @floatFromInt(sum)) / count / 255;
            const color = wave_colour.tint(combo.scheme, combo.curve, level, low / count / 7, mid / count / 7, high / count / 7);
            const height = @max(1, (rect.h - 4) * level);
            app.fillRectInto(builder, rect.x + x, rect.bottom() - height - 2, @min(step, rect.w - x), height, .{
                .r = color.r,
                .g = color.g,
                .b = color.b,
                .a = color.a,
            });
        }

        const beat_w = rect.w / 32;
        var beat: usize = 0;
        while (beat <= 32) : (beat += 1) {
            const bx = rect.x + beat_w * @as(f32, @floatFromInt(beat));
            app.fillRectInto(builder, bx, rect.y, if (beat % 4 == 0) 2 else 1, rect.h, app.fade(Palette.muted, if (beat % 4 == 0) 80 else 40));
        }
    }
};
