//! Four ways of drawing the same waveform, side by side, so one can be picked.
//! Synthetic data: 32 beats at 128 bpm, no crate or analysis file needed.

const std = @import("std");
const dvui = @import("dvui");
const hit = @import("hit.zig");
const app = @import("app.zig");
const wave = @import("wave.zig");

const Palette = app.Palette;
const samples_per_second = 150;

const Variant = enum {
    silhouette,
    outline_body,
    band_rows,
    beat_blocks,
};

pub const Demo = struct {
    samples: []u8 = &.{},
    low: []u8 = &.{},
    mid: []u8 = &.{},
    high: []u8 = &.{},
    beats: usize = 32,

    pub fn init(allocator: std.mem.Allocator) !Demo {
        const samples_per_beat: f32 = @as(f32, samples_per_second) * 60 / 128;
        const count: usize = @intFromFloat(@ceil(32 * samples_per_beat));

        var demo = Demo{};
        errdefer demo.deinit(allocator);
        demo.samples = try allocator.alloc(u8, count);
        demo.low = try allocator.alloc(u8, count);
        demo.mid = try allocator.alloc(u8, count);
        demo.high = try allocator.alloc(u8, count);

        for (0..count) |i| {
            const beat = @as(f32, @floatFromInt(i)) / samples_per_beat;
            const beat_index: usize = @intFromFloat(@floor(beat));
            const phase = beat - @floor(beat);
            const quarter = beat_index % 4;
            const accent = 0.55 + 0.45 * noise01(beat_index * 1013 + 7);

            const kick = std.math.exp(-phase * 7) * accent;
            const snare = if (quarter == 1 or quarter == 3) std.math.exp(-phase * 11) * 0.8 else 0;
            const half = beat * 2 - @floor(beat * 2);
            const hat = std.math.exp(-half * 26) * (0.3 + 0.35 * noise01(i));

            const low_level = std.math.clamp(kick * (0.8 + 0.2 * noise01(i * 3 + 1)), 0, 1);
            const mid_level = std.math.clamp(snare * (0.6 + 0.4 * noise01(i * 5 + 2)), 0, 1);
            const high_level = std.math.clamp(hat * (0.7 + 0.3 * noise01(i * 7 + 3)), 0, 1);

            demo.low[i] = toByte(low_level);
            demo.mid[i] = toByte(mid_level);
            demo.high[i] = toByte(high_level);
            demo.samples[i] = toByte(low_level * 0.95 + mid_level * 0.55 + high_level * 0.4);
        }
        return demo;
    }

    pub fn deinit(self: Demo, allocator: std.mem.Allocator) void {
        if (self.samples.len > 0) allocator.free(self.samples);
        if (self.low.len > 0) allocator.free(self.low);
        if (self.mid.len > 0) allocator.free(self.mid);
        if (self.high.len > 0) allocator.free(self.high);
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

        dvui.labelNoFmt(@src(), "waveform demo · synthetic 128 bpm · 32 beats · one data set, four typologies", .{}, .{
            .font = dvui.themeGet().font_title,
            .color_text = .{ .color = Palette.purple },
            .margin = .{ .x = 2, .y = 4 },
            .id_extra = 1,
        });

        self.panel(&builder, "1  amplitude silhouette · bar lines dominant, beat lines weak", .silhouette, 2);
        self.panel(&builder, "2  peak outline over a smoothed body (two envelopes)", .outline_body, 3);
        self.panel(&builder, "3  low / mid / high energy · one tinted row each", .band_rows, 4);
        self.panel(&builder, "4  per-beat intensity blocks · one block per beat", .beat_blocks, 5);
    }

    fn panel(self: *const Demo, builder: *dvui.Path.Builder, label: []const u8, variant: Variant, id: usize) void {
        var row = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 132 },
            .margin = .{ .x = 2, .y = 5 },
            .id_extra = id * 10,
        });
        defer row.deinit();

        dvui.labelNoFmt(@src(), label, .{}, .{
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
        if (rect.isEmpty()) return;

        app.fillRectInto(builder, rect.x, rect.y, rect.w, rect.h, Palette.field);
        switch (variant) {
            .silhouette => self.paintSilhouette(builder, rect),
            .outline_body => self.paintOutlineBody(builder, rect),
            .band_rows => self.paintBandRows(builder, rect),
            .beat_blocks => self.paintBeatBlocks(builder, rect),
        }
        self.paintGrid(builder, rect);
    }

    fn paintSilhouette(self: *const Demo, builder: *dvui.Path.Builder, rect: hit.Rect) void {
        var x: f32 = 0;
        var smoothed: f32 = 0.15;
        while (x < rect.w) : (x += 4) {
            const span = spanFor(self.samples.len, x, 4, rect.w);
            smoothed = smoothed * 0.6 + peakOf(self.samples, span) * 0.4;
            const height = @max(1, rect.h * smoothed);
            app.fillRectInto(builder, rect.x + x, rect.bottom() - height, @min(4, rect.w - x), height, app.bandColor(smoothed));
        }
    }

    fn paintOutlineBody(self: *const Demo, builder: *dvui.Path.Builder, rect: hit.Rect) void {
        const radius: usize = 23;
        var x: f32 = 0;
        var smoothed: f32 = 0.15;
        while (x < rect.w) : (x += 4) {
            const span = spanFor(self.samples.len, x, 4, rect.w);
            smoothed = smoothed * 0.6 + peakOf(self.samples, span) * 0.4;
            const body = @min(smoothed, wave.lowBand(self.samples, span.from, span.to, radius, @as(f32, 1.15) / 255));

            const peak_height = @max(1, rect.h * smoothed);
            const body_height = @max(1, rect.h * body);
            app.fillRectInto(builder, rect.x + x, rect.bottom() - body_height, @min(4, rect.w - x), body_height, app.mixColor(Palette.field, app.bandColor(body), 0.55));
            app.fillRectInto(builder, rect.x + x, rect.bottom() - peak_height, @min(4, rect.w - x), @max(1, peak_height - body_height), app.bandColor(smoothed));
        }
    }

    fn paintBandRows(self: *const Demo, builder: *dvui.Path.Builder, rect: hit.Rect) void {
        const rows = [_]struct { samples: []const u8, color: dvui.Color }{
            .{ .samples = self.low, .color = Palette.heat1 },
            .{ .samples = self.mid, .color = Palette.heat2 },
            .{ .samples = self.high, .color = Palette.heat4 },
        };
        const row_h = rect.h / 3;
        for (rows, 0..) |row, index| {
            const top = rect.y + row_h * @as(f32, @floatFromInt(index));
            if (index > 0) app.fillRectInto(builder, rect.x, top, rect.w, 1, app.fade(Palette.muted, 60));

            var x: f32 = 0;
            while (x < rect.w) : (x += 4) {
                const span = spanFor(row.samples.len, x, 4, rect.w);
                const level = peakOf(row.samples, span);
                const height = @max(1, (row_h - 4) * level);
                app.fillRectInto(
                    builder,
                    rect.x + x,
                    top + row_h - height - 1,
                    @min(4, rect.w - x),
                    height,
                    app.mixColor(Palette.field, row.color, 0.35 + 0.65 * level),
                );
            }
        }
    }

    fn paintBeatBlocks(self: *const Demo, builder: *dvui.Path.Builder, rect: hit.Rect) void {
        const beat_count: f32 = @floatFromInt(self.beats);
        const beat_w = rect.w / beat_count;
        for (0..self.beats) |beat| {
            const from: usize = @intFromFloat(@as(f32, @floatFromInt(beat)) / beat_count * @as(f32, @floatFromInt(self.samples.len)));
            const to: usize = @intFromFloat(@as(f32, @floatFromInt(beat + 1)) / beat_count * @as(f32, @floatFromInt(self.samples.len)));
            if (to <= from) continue;

            var sum: usize = 0;
            for (self.samples[from..to]) |value| sum += value;
            const level = @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(to - from)) / 255;
            const height = @max(1, (rect.h - 4) * level);
            app.fillRectInto(
                builder,
                rect.x + beat_w * @as(f32, @floatFromInt(beat)) + 1,
                rect.bottom() - height - 2,
                @max(1, beat_w - 2),
                height,
                app.bandColor(level),
            );
        }
    }

    fn paintGrid(self: *const Demo, builder: *dvui.Path.Builder, rect: hit.Rect) void {
        const beat_w = rect.w / @as(f32, @floatFromInt(self.beats));
        for (0..self.beats) |beat| {
            const bar = beat % 4 == 0;
            app.fillRectInto(
                builder,
                rect.x + beat_w * @as(f32, @floatFromInt(beat)),
                rect.y,
                if (bar) 3 else 1,
                rect.h,
                app.fade(if (bar) Palette.ink else Palette.muted, if (bar) 110 else 50),
            );
        }
    }
};

const Span = struct {
    from: usize,
    to: usize,
};

fn spanFor(len: usize, x: f32, step: f32, width: f32) Span {
    if (len == 0) return .{ .from = 0, .to = 0 };
    const from: usize = @intFromFloat(std.math.clamp(x / width, 0, 1) * @as(f32, @floatFromInt(len)));
    const to: usize = @intFromFloat(std.math.clamp((x + step) / width, 0, 1) * @as(f32, @floatFromInt(len)));
    const start = @min(from, len - 1);
    return .{ .from = start, .to = @max(@min(to, len), @min(start + 1, len)) };
}

fn peakOf(samples: []const u8, span: Span) f32 {
    if (span.to <= span.from) return 0;
    var peak: u8 = 0;
    for (samples[span.from..span.to]) |value| peak = @max(peak, value);
    return @as(f32, @floatFromInt(peak)) / 255;
}

fn toByte(level: f32) u8 {
    return @intFromFloat(std.math.clamp(level, 0, 1) * 255);
}

fn noise01(seed: u64) f32 {
    var h = seed;
    h ^= h >> 33;
    h *%= 0xff51afd7ed558ccd;
    h ^= h >> 33;
    h *%= 0xc4ceb9fe1a85ec53;
    h ^= h >> 33;
    return @as(f32, @floatFromInt(h >> 40)) / @as(f32, @floatFromInt(1 << 24));
}
