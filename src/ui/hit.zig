//! What the pointer is over, and what a press-move-release does.
//!
//! The draw pass appends the rectangles it laid out; the pointer pass reads the
//! map from the previous frame. Nothing here imports dvui, so the rules run
//! under `zig build test` without a window.

const std = @import("std");
const pl = @import("alchimix");

const Track = pl.track.Track;

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn contains(self: Rect, p: Point) bool {
        return p.x >= self.x and p.x <= self.x + self.w and
            p.y >= self.y and p.y <= self.y + self.h;
    }

    pub fn centerY(self: Rect) f32 {
        return self.y + self.h / 2;
    }

    pub fn bottom(self: Rect) f32 {
        return self.y + self.h;
    }

    /// The part of `self` inside `bounds`. Zero-sized when they miss.
    pub fn clipped(self: Rect, bounds: Rect) Rect {
        const x0 = @max(self.x, bounds.x);
        const y0 = @max(self.y, bounds.y);
        const x1 = @min(self.x + self.w, bounds.x + bounds.w);
        const y1 = @min(self.y + self.h, bounds.y + bounds.h);
        return .{
            .x = x0,
            .y = y0,
            .w = @max(0, x1 - x0),
            .h = @max(0, y1 - y0),
        };
    }

    pub fn shiftedLeft(self: Rect, amount: f32) Rect {
        const cut = @min(amount, self.w);
        return .{ .x = self.x + cut, .y = self.y, .w = self.w - cut, .h = self.h };
    }
};

pub const Toggle = enum(u2) { hold, up, down };

pub const Target = union(enum) {
    toggle: Toggle,
    /// Switches the key display between wheel numbers and note names.
    notation,
    row: Track,
    block: usize,
    /// The waveform of a preview lane: dragging moves its start beat.
    lane: usize,
    /// The whole-track navigator under a preview lane.
    nav: usize,
    /// The EQ plot: spectrum and the curve the nodes sit on.
    eq_plot: usize,
    /// One draggable band node.
    eq_node: struct { lane: usize, band: usize },
    /// One preset choice left of the plot.
    eq_preset: struct { lane: usize, preset: pl.mixer.EqPreset },
    /// The trim slider and meter at the far right of a lane.
    trim: usize,
    /// Starts and stops the grid's shared transport.
    transport,
    /// Empties the crate and returns to the starting state.
    clear,
    /// A playlist row: selecting it filters suggestions.
    playlist: usize,
    /// A playlist folder: opens or closes its children.
    playlist_toggle: usize,
    /// Writes the current crate as a new playlist.
    save_playlist,
    /// Orders the suggestions by BPM.
    sort_bpm,
    /// Drifts the window, or stops it drifting.
    lsd,
    /// The gentler drift with mushrooms and rain, or stops it.
    mushroom,
    /// Folds the window into a mandala at full brightness.
    dmt,
    /// Folds it, dimmed throughout.
    dmt_a,
    /// Folds it, then paints the coloured fills back at full strength.
    dmt_b,
    /// The pinned look: full brightness, window border held still.
    dmt_og,
    /// Freezes the master tempo to the seed's BPM, or frees it.
    master_lock,
    /// Keeps the pitch while the master tempo changes.
    pitch_lock,
    /// Starts or stops one grid lane.
    lane_play: usize,
    /// Silences one grid lane without stopping it.
    lane_mute: usize,
    /// A waveform span choice, in beats.
    width: u8,
};

/// The spans the waveform can show, in beats.
pub const widths = [_]u8{ 16, 32, 64 };

pub fn isWidth(value: u8) bool {
    return std.mem.indexOfScalar(u8, &widths, value) != null;
}

/// Screen rectangles for one frame, with what each one means.
pub const HitMap = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub const Entry = struct {
        rect: Rect,
        target: Target,
    };

    pub fn init(allocator: std.mem.Allocator) HitMap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *HitMap) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Forget the previous frame: a target that stops being drawn must stop
    /// taking presses.
    pub fn reset(self: *HitMap) void {
        self.entries.clearRetainingCapacity();
    }

    pub fn append(self: *HitMap, rect: Rect, target: Target) void {
        if (rect.isEmpty()) return;
        self.entries.append(self.allocator, .{ .rect = rect, .target = target }) catch {};
    }

    pub fn hit(self: *const HitMap, p: Point) ?Target {
        for (self.entries.items) |entry| {
            if (entry.rect.contains(p)) return entry.target;
        }
        return null;
    }

    const Surface = enum { wave, nav };

    /// The rectangle the current frame drew for one lane surface.
    fn surfaceRect(self: *const HitMap, surface: Surface, index: usize) ?Rect {
        for (self.entries.items) |entry| {
            const matches = switch (entry.target) {
                .lane => |at| surface == .wave and at == index,
                .nav => |at| surface == .nav and at == index,
                else => false,
            };
            if (matches and !entry.rect.isEmpty()) return entry.rect;
        }
        return null;
    }

    /// How far a waveform drag moves the window, in beats. Dragging left shows
    /// later audio.
    pub fn waveformDragBeats(self: *const HitMap, index: usize, dx: f32, visible_beats: f32) ?f32 {
        const rect = self.surfaceRect(.wave, index) orelse return null;
        if (!(visible_beats > 0)) return null;
        return -dx * visible_beats / rect.w;
    }

    /// How far a navigator drag moves the playhead, in beats.
    pub fn navDragBeats(self: *const HitMap, index: usize, dx: f32, total_beats: f32) ?f32 {
        const rect = self.surfaceRect(.nav, index) orelse return null;
        if (!(total_beats > 0)) return null;
        return dx * total_beats / rect.w;
    }

    /// The beat under a press on the navigator, clamped to the whole track.
    pub fn navBeatAt(self: *const HitMap, index: usize, x: f32, total_beats: f32) ?f32 {
        const rect = self.surfaceRect(.nav, index) orelse return null;
        if (!(total_beats > 0)) return null;
        return horizontalFraction(rect, x) * total_beats;
    }

    pub fn eqPlotRect(self: *const HitMap, lane: usize) ?Rect {
        for (self.entries.items) |entry| {
            switch (entry.target) {
                .eq_plot => |at| if (at == lane and !entry.rect.isEmpty()) return entry.rect,
                else => {},
            }
        }
        return null;
    }

    pub const EqPoint = struct { freq_hz: f32, gain_db: f32 };

    /// Maps a pointer position inside the plot to the frequency and gain the
    /// node should take. X is logarithmic from `eq_min_hz` to `eq_max_hz`.
    pub fn eqPointAt(self: *const HitMap, lane: usize, p: Point) ?EqPoint {
        const rect = self.eqPlotRect(lane) orelse return null;
        const fx = std.math.clamp((p.x - rect.x) / rect.w, 0, 1);
        const fy = std.math.clamp((p.y - rect.y) / rect.h, 0, 1);
        const freq = pl.mixer.eq_min_hz * std.math.pow(f32, pl.mixer.eq_max_hz / pl.mixer.eq_min_hz, fx);
        return .{
            .freq_hz = freq,
            .gain_db = (0.5 - fy) * 2 * pl.mixer.eq_max_gain_db,
        };
    }

    fn trimRect(self: *const HitMap, lane: usize) ?Rect {
        for (self.entries.items) |entry| {
            switch (entry.target) {
                .trim => |at| if (at == lane and !entry.rect.isEmpty()) return entry.rect,
                else => {},
            }
        }
        return null;
    }

    /// Maps a pointer position on a trim bar to decibels: top is full boost,
    /// bottom full cut, and anything outside clamps to that range.
    pub fn trimValueAt(self: *const HitMap, lane: usize, y: f32) ?f32 {
        const rect = self.trimRect(lane) orelse return null;
        return (0.5 - verticalFraction(rect, y)) * 2 * pl.mixer.trim_max_db;
    }

    /// The gap nearest `y`: how many block middles sit above it.
    pub fn gapAt(self: *const HitMap, y: f32) usize {
        var gap: usize = 0;
        for (self.entries.items) |entry| {
            switch (entry.target) {
                .block => if (entry.rect.centerY() < y) {
                    gap += 1;
                },
                else => {},
            }
        }
        return gap;
    }

    /// The insertion gap from full row rectangles, which keep their true
    /// centres even when scrolled out of view.
    pub fn gapAtRows(rows: []const Rect, y: f32) usize {
        var gap: usize = 0;
        for (rows) |row| {
            if (row.centerY() < y) gap += 1;
        }
        return gap;
    }
};

/// Press selects, movement past a threshold turns the press into a drag, release
/// drops it. A toggle flips on the press instead.
pub const Drag = struct {
    pressed: ?Target = null,
    press_at: Point = .{},
    carrying: ?Target = null,
    gap: ?usize = null,

    pub const Action = union(enum) {
        none,
        toggle: Toggle,
        toggle_notation,
        toggle_transport,
        clear_all,
        toggle_sort_bpm,
        toggle_lsd,
        toggle_mushroom,
        toggle_dmt,
        toggle_dmt_a,
        toggle_dmt_b,
        toggle_dmt_og,
        select_playlist: usize,
        toggle_playlist: usize,
        save_playlist,
        toggle_master_lock,
        toggle_pitch,
        toggle_lane_play: usize,
        toggle_lane_mute: usize,
        /// A press on the width selector: show this many beats per lane.
        set_width: u8,
        /// A press on a lane's scrub bar: jump the window to that point.
        seek_nav: usize,
        /// A press on a band node: the drag moves it in frequency and gain.
        grab_eq: struct { lane: usize, band: usize },
        /// A press on a preset: applies it, or clears the EQ when already on.
        set_eq_preset: struct { lane: usize, preset: pl.mixer.EqPreset },
        /// A press or drag on a trim bar: sets the lane's gain from the pointer.
        set_trim: usize,
        select_block: usize,
        toggle_block: usize,
        move_block: struct { from: usize, gap: usize },
        drop_track: struct { gap: usize, track: Track },
    };

    /// `shift` adds the block to the selection instead of making it the seed,
    /// and never starts a drag.
    pub fn press(self: *Drag, target: Target, p: Point, shift: bool) Action {
        self.* = .{ .press_at = p };
        return switch (target) {
            .toggle => |toggle| .{ .toggle = toggle },
            .notation => .toggle_notation,
            .transport => .toggle_transport,
            .clear => .clear_all,
            .sort_bpm => .toggle_sort_bpm,
            .lsd => .toggle_lsd,
            .mushroom => .toggle_mushroom,
            .dmt => .toggle_dmt,
            .dmt_a => .toggle_dmt_a,
            .dmt_b => .toggle_dmt_b,
            .dmt_og => .toggle_dmt_og,
            .playlist => |index| .{ .select_playlist = index },
            .playlist_toggle => |index| .{ .toggle_playlist = index },
            .save_playlist => .save_playlist,
            .master_lock => .toggle_master_lock,
            .pitch_lock => .toggle_pitch,
            .lane_play => |index| .{ .toggle_lane_play = index },
            .lane_mute => |index| .{ .toggle_lane_mute = index },
            .width => |beats| .{ .set_width = beats },
            .block => |index| blk: {
                if (shift) break :blk .{ .toggle_block = index };
                self.pressed = target;
                break :blk .{ .select_block = index };
            },
            .nav => |index| blk: {
                self.pressed = target;
                break :blk .{ .seek_nav = index };
            },
            .eq_node => |at| blk: {
                self.pressed = target;
                break :blk .{ .grab_eq = .{ .lane = at.lane, .band = at.band } };
            },
            .eq_preset => |at| .{ .set_eq_preset = .{ .lane = at.lane, .preset = at.preset } },
            .trim => |index| blk: {
                self.pressed = target;
                break :blk .{ .set_trim = index };
            },
            .eq_plot => .none,
            .row, .lane => blk: {
                self.pressed = target;
                break :blk .none;
            },
        };
    }

    pub const Pull = struct {
        target: Target,
        /// Movement since the previous call, in screen units.
        dx: f32,
        dy: f32,
        /// Current pointer position, for surfaces that track it absolutely.
        p: Point,
    };

    /// Horizontal movement of a lane or a slider, measured incrementally so the
    /// caller can apply it without knowing the press point.
    pub fn pull(self: *Drag, p: Point) ?Pull {
        const pressed = self.pressed orelse return null;
        switch (pressed) {
            .lane, .nav, .eq_node, .trim => {},
            else => return null,
        }
        const dx = p.x - self.press_at.x;
        const dy = p.y - self.press_at.y;
        self.press_at = p;
        return .{ .target = pressed, .dx = dx, .dy = dy, .p = p };
    }

    /// True when the frame has something new to draw.
    pub fn motion(self: *Drag, p: Point, threshold: f32, canvas: Rect, rows: []const Rect) bool {
        const pressed = self.pressed orelse return false;
        switch (pressed) {
            .lane, .nav, .eq_node, .eq_plot, .eq_preset, .trim, .clear, .playlist, .playlist_toggle, .save_playlist, .sort_bpm, .lsd, .mushroom, .dmt, .dmt_a, .dmt_b, .dmt_og => return false,
            else => {},
        }
        if (self.carrying == null) {
            if (!moved(self.press_at, p, threshold)) return false;
            self.carrying = pressed;
        }
        self.gap = if (canvas.contains(p)) HitMap.gapAtRows(rows, p.y) else null;
        return true;
    }

    pub fn release(self: *Drag) Action {
        const carrying = self.carrying;
        const gap = self.gap;
        self.* = .{};

        const target = carrying orelse return .none;
        const to = gap orelse return .none;
        return switch (target) {
            .block => |from| .{ .move_block = .{ .from = from, .gap = to } },
            .row => |track| .{ .drop_track = .{ .gap = to, .track = track } },
            .toggle, .notation, .lane, .nav, .eq_node, .eq_plot, .eq_preset, .trim, .transport, .clear, .playlist, .playlist_toggle, .save_playlist, .sort_bpm, .lsd, .mushroom, .dmt, .dmt_a, .dmt_b, .dmt_og, .master_lock, .pitch_lock, .lane_play, .lane_mute, .width => .none,
        };
    }

    pub fn carriedTrack(self: *const Drag) ?Track {
        const target = self.carrying orelse return null;
        return switch (target) {
            .row => |track| track,
            else => null,
        };
    }

    pub fn carriedBlock(self: *const Drag) ?usize {
        const target = self.carrying orelse return null;
        return switch (target) {
            .block => |index| index,
            else => null,
        };
    }

    pub fn gapIndex(self: *const Drag) ?usize {
        return self.gap;
    }
};

fn moved(from: Point, to: Point, limit: f32) bool {
    return @abs(from.x - to.x) > limit or @abs(from.y - to.y) > limit;
}

fn horizontalFraction(rect: Rect, x: f32) f32 {
    return std.math.clamp((x - rect.x) / rect.w, 0, 1);
}

fn verticalFraction(rect: Rect, y: f32) f32 {
    return std.math.clamp((y - rect.y) / rect.h, 0, 1);
}

fn isNone(action: Drag.Action) bool {
    return switch (action) {
        .none => true,
        else => false,
    };
}

const T = struct {
    fn track(id: u64) Track {
        return Track.init(id, "title", "artist");
    }
};

const viewport: Rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };

test "a target that stops being drawn stops taking presses" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();

    // Frame one: three rows, the first one at the top.
    map.append(.{ .x = 0, .y = 0, .w = 400, .h = 80 }, .{ .row = T.track(1) });
    map.append(.{ .x = 0, .y = 80, .w = 400, .h = 80 }, .{ .row = T.track(2) });
    map.append(.{ .x = 0, .y = 160, .w = 400, .h = 80 }, .{ .row = T.track(3) });

    // Frame two: track 1 is filtered out, so it is not appended at all.
    map.reset();
    map.append(.{ .x = 0, .y = 0, .w = 400, .h = 80 }, .{ .row = T.track(2) });
    map.append(.{ .x = 0, .y = 80, .w = 400, .h = 80 }, .{ .row = T.track(3) });

    const hit = map.hit(.{ .x = 10, .y = 10 }).?;
    const id = switch (hit) {
        .row => |track| track.id,
        else => 0,
    };
    try std.testing.expectEqual(@as(u64, 2), id);
}

test "a row clipped by its viewport only takes presses inside it" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();

    const row: Rect = .{ .x = 0, .y = 560, .w = 400, .h = 80 };
    map.append(row.clipped(viewport), .{ .row = T.track(1) });

    try std.testing.expect(map.hit(.{ .x = 10, .y = 570 }) != null);
    try std.testing.expect(map.hit(.{ .x = 10, .y = 620 }) == null);
}

fn blockRows(map: *const HitMap, buffer: *[8]Rect) []const Rect {
    var count: usize = 0;
    for (map.entries.items) |entry| {
        switch (entry.target) {
            .block => {
                if (count < buffer.len) {
                    buffer[count] = entry.rect;
                    count += 1;
                }
            },
            else => {},
        }
    }
    return buffer[0..count];
}

test "the gap is the number of block middles above the pointer" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();

    map.append(.{ .x = 0, .y = 0, .w = 400, .h = 100 }, .{ .block = 0 });
    map.append(.{ .x = 0, .y = 100, .w = 400, .h = 100 }, .{ .block = 1 });
    map.append(.{ .x = 0, .y = 200, .w = 400, .h = 100 }, .{ .block = 2 });

    try std.testing.expectEqual(@as(usize, 0), map.gapAt(10));
    try std.testing.expectEqual(@as(usize, 1), map.gapAt(110));
    try std.testing.expectEqual(@as(usize, 2), map.gapAt(210));
    try std.testing.expectEqual(@as(usize, 3), map.gapAt(400));
}

test "a scrolled-out row keeps its centre for the gap" {
    // The first row is above the viewport, so its clipped rect would sit on the
    // top edge and read as a drop before it; the full rect does not.
    const rows = [_]Rect{
        .{ .x = 0, .y = -60, .w = 400, .h = 100 },
        .{ .x = 0, .y = 40, .w = 400, .h = 100 },
        .{ .x = 0, .y = 140, .w = 400, .h = 100 },
    };
    try std.testing.expectEqual(@as(usize, 1), HitMap.gapAtRows(&rows, 30));
    try std.testing.expectEqual(@as(usize, 2), HitMap.gapAtRows(&rows, 120));
}

test "a press with no movement adds nothing" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    map.append(.{ .x = 0, .y = 0, .w = 400, .h = 80 }, .{ .row = T.track(1) });

    var rows_buffer: [8]Rect = undefined;
    const rows = blockRows(&map, &rows_buffer);

    var drag = Drag{};
    _ = drag.press(.{ .row = T.track(1) }, .{ .x = 10, .y = 10 }, false);
    try std.testing.expect(!drag.motion(.{ .x = 12, .y = 11 }, 6, viewport, rows));
    try std.testing.expect(isNone(drag.release()));
}

test "movement past the threshold starts carrying" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    map.append(.{ .x = 0, .y = 0, .w = 400, .h = 80 }, .{ .row = T.track(7) });

    var rows_buffer: [8]Rect = undefined;
    const rows = blockRows(&map, &rows_buffer);

    var drag = Drag{};
    _ = drag.press(.{ .row = T.track(7) }, .{ .x = 10, .y = 10 }, false);
    try std.testing.expect(drag.motion(.{ .x = 40, .y = 40 }, 6, viewport, rows));
    try std.testing.expectEqual(@as(u64, 7), drag.carriedTrack().?.id);
    try std.testing.expectEqual(@as(?usize, 0), drag.gapIndex());
}

test "releasing over the canvas drops the carried track at the gap" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    map.append(.{ .x = 0, .y = 0, .w = 400, .h = 100 }, .{ .block = 0 });
    map.append(.{ .x = 0, .y = 100, .w = 400, .h = 100 }, .{ .block = 1 });

    var rows_buffer: [8]Rect = undefined;
    const rows = blockRows(&map, &rows_buffer);

    var drag = Drag{};
    _ = drag.press(.{ .row = T.track(9) }, .{ .x = 10, .y = 10 }, false);
    _ = drag.motion(.{ .x = 300, .y = 180 }, 6, viewport, rows);

    const action = drag.release();
    switch (action) {
        .drop_track => |drop| {
            try std.testing.expectEqual(@as(usize, 2), drop.gap);
            try std.testing.expectEqual(@as(u64, 9), drop.track.id);
        },
        else => return error.WrongAction,
    }
}

test "releasing outside the canvas drops nothing" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    map.append(.{ .x = 0, .y = 0, .w = 400, .h = 100 }, .{ .block = 0 });

    var rows_buffer: [8]Rect = undefined;
    const rows = blockRows(&map, &rows_buffer);

    var drag = Drag{};
    _ = drag.press(.{ .row = T.track(9) }, .{ .x = 10, .y = 10 }, false);
    _ = drag.motion(.{ .x = 900, .y = 10 }, 6, viewport, rows);
    try std.testing.expect(drag.gapIndex() == null);
    try std.testing.expect(isNone(drag.release()));
}

test "a block drag reports the move and its source" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    map.append(.{ .x = 0, .y = 0, .w = 400, .h = 100 }, .{ .block = 0 });
    map.append(.{ .x = 0, .y = 100, .w = 400, .h = 100 }, .{ .block = 1 });

    var rows_buffer: [8]Rect = undefined;
    const rows = blockRows(&map, &rows_buffer);

    var drag = Drag{};
    const pressed = drag.press(.{ .block = 0 }, .{ .x = 10, .y = 10 }, false);
    switch (pressed) {
        .select_block => |index| try std.testing.expectEqual(@as(usize, 0), index),
        else => return error.WrongAction,
    }

    _ = drag.motion(.{ .x = 10, .y = 150 }, 6, viewport, rows);
    const action = drag.release();
    switch (action) {
        .move_block => |move| {
            try std.testing.expectEqual(@as(usize, 0), move.from);
            try std.testing.expectEqual(@as(usize, 1), move.gap);
        },
        else => return error.WrongAction,
    }
}

test "the notation toggle fires on the press and carries nothing" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    map.append(.{ .x = 0, .y = 0, .w = 60, .h = 30 }, .notation);

    var drag = Drag{};
    const action = drag.press(.notation, .{ .x = 10, .y = 10 }, false);
    switch (action) {
        .toggle_notation => {},
        else => return error.WrongAction,
    }
    var rows_buffer: [8]Rect = undefined;
    const rows = blockRows(&map, &rows_buffer);
    try std.testing.expect(!drag.motion(.{ .x = 90, .y = 60 }, 6, viewport, rows));
    try std.testing.expect(isNone(drag.release()));
}

test "a width press reports the span and carries nothing" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    map.append(.{ .x = 0, .y = 0, .w = 30, .h = 20 }, .{ .width = 32 });

    var drag = Drag{};
    const hit = map.hit(.{ .x = 10, .y = 10 }).?;
    switch (drag.press(hit, .{ .x = 10, .y = 10 }, false)) {
        .set_width => |beats| try std.testing.expectEqual(@as(u8, 32), beats),
        else => return error.WrongAction,
    }
    var rows_buffer: [8]Rect = undefined;
    const rows = blockRows(&map, &rows_buffer);
    try std.testing.expect(!drag.motion(.{ .x = 90, .y = 60 }, 6, viewport, rows));
    try std.testing.expect(isNone(drag.release()));
}

test "only the offered spans are widths" {
    try std.testing.expect(isWidth(16));
    try std.testing.expect(isWidth(32));
    try std.testing.expect(isWidth(64));
    try std.testing.expect(!isWidth(0));
    try std.testing.expect(!isWidth(48));
}

test "a toggle flips on the press and carries nothing" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    map.append(.{ .x = 0, .y = 0, .w = 40, .h = 30 }, .{ .toggle = .up });

    var drag = Drag{};
    const action = drag.press(.{ .toggle = .up }, .{ .x = 10, .y = 10 }, false);
    switch (action) {
        .toggle => |toggle| try std.testing.expectEqual(Toggle.up, toggle),
        else => return error.WrongAction,
    }
    try std.testing.expect(!drag.motion(.{ .x = 60, .y = 60 }, 6, viewport, &.{}));
    try std.testing.expect(isNone(drag.release()));
}

test "a press on the mute button toggles that lane and carries nothing" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    map.append(.{ .x = 0, .y = 0, .w = 26, .h = 18 }, .{ .lane_mute = 2 });

    var drag = Drag{};
    const action = drag.press(.{ .lane_mute = 2 }, .{ .x = 10, .y = 10 }, false);
    switch (action) {
        .toggle_lane_mute => |index| try std.testing.expectEqual(@as(usize, 2), index),
        else => return error.WrongAction,
    }
    var rows_buffer: [8]Rect = undefined;
    const rows = blockRows(&map, &rows_buffer);
    try std.testing.expect(!drag.motion(.{ .x = 90, .y = 60 }, 6, viewport, rows));
    try std.testing.expect(isNone(drag.release()));
}

test "a shift press toggles the block without carrying it" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    map.append(.{ .x = 0, .y = 0, .w = 400, .h = 100 }, .{ .block = 2 });

    var drag = Drag{};
    const action = drag.press(.{ .block = 2 }, .{ .x = 10, .y = 10 }, true);
    switch (action) {
        .toggle_block => |index| try std.testing.expectEqual(@as(usize, 2), index),
        else => return error.WrongAction,
    }
    try std.testing.expect(!drag.motion(.{ .x = 10, .y = 200 }, 6, viewport, &.{}));
    try std.testing.expect(isNone(drag.release()));
}

test "a lane press pulls horizontal movement and carries nothing" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    map.append(.{ .x = 0, .y = 0, .w = 400, .h = 80 }, .{ .lane = 1 });

    var drag = Drag{};
    _ = drag.press(.{ .lane = 1 }, .{ .x = 100, .y = 20 }, false);

    const pull = drag.pull(.{ .x = 130, .y = 20 }).?;
    try std.testing.expectEqual(@as(f32, 30), pull.dx);
    switch (pull.target) {
        .lane => |lane| try std.testing.expectEqual(@as(usize, 1), lane),
        else => return error.WrongTarget,
    }

    const second = drag.pull(.{ .x = 140, .y = 20 }).?;
    try std.testing.expectEqual(@as(f32, 10), second.dx);
    try std.testing.expect(drag.carriedTrack() == null);
    try std.testing.expect(isNone(drag.release()));
}

test "a navigator press pulls without a gap" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    map.append(.{ .x = 0, .y = 0, .w = 400, .h = 20 }, .{ .nav = 0 });

    var drag = Drag{};
    _ = drag.press(.{ .nav = 0 }, .{ .x = 10, .y = 10 }, false);
    const pull = drag.pull(.{ .x = 25, .y = 10 }).?;
    try std.testing.expectEqual(@as(f32, 15), pull.dx);
    try std.testing.expect(drag.gapIndex() == null);
}

const lane_wave: Rect = .{ .x = 40, .y = 100, .w = 400, .h = 80 };
const lane_nav: Rect = .{ .x = 40, .y = 180, .w = 320, .h = 20 };
const lane_plot: Rect = .{ .x = 440, .y = 100, .w = 120, .h = 80 };
const lane_nodes: [3]Rect = .{
    .{ .x = 445, .y = 130, .w = 10, .h = 10 },
    .{ .x = 495, .y = 135, .w = 10, .h = 10 },
    .{ .x = 545, .y = 120, .w = 10, .h = 10 },
};
const lane_presets: [3]Rect = .{
    .{ .x = 400, .y = 100, .w = 40, .h = 20 },
    .{ .x = 400, .y = 124, .w = 40, .h = 20 },
    .{ .x = 400, .y = 148, .w = 40, .h = 20 },
};

fn drawLaneFrame(map: *HitMap, index: usize, wave: Rect) void {
    map.append(wave, .{ .lane = index });
    map.append(lane_nav, .{ .nav = index });
    for (lane_nodes, 0..) |rect, band| map.append(rect, .{ .eq_node = .{ .lane = index, .band = band } });
    for (lane_presets, 0..) |rect, choice| map.append(rect, .{ .eq_preset = .{ .lane = index, .preset = @enumFromInt(choice + 1) } });
    map.append(lane_plot, .{ .eq_plot = index });
}

fn expectClose(expected: f32, actual: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
}

test "lane geometry follows the current frame after a resize" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();

    drawLaneFrame(&map, 0, lane_wave);
    try expectClose(0.4, map.waveformDragBeats(0, -10, 16).?);

    map.reset();
    drawLaneFrame(&map, 0, .{ .x = 40, .y = 100, .w = 200, .h = 80 });
    try expectClose(0.8, map.waveformDragBeats(0, -10, 16).?);
}

test "a surface that stops being drawn maps to nothing" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();

    drawLaneFrame(&map, 0, lane_wave);
    map.reset();
    try std.testing.expect(map.waveformDragBeats(0, 10, 16) == null);
    try std.testing.expect(map.navBeatAt(0, 100, 128) == null);
    try std.testing.expect(map.eqPointAt(0, .{ .x = 500, .y = 140 }) == null);

    map.append(.{ .x = 40, .y = 100, .w = 0, .h = 80 }, .{ .lane = 0 });
    try std.testing.expect(map.waveformDragBeats(0, 10, 16) == null);
}

test "lane surfaces do not borrow another lane's geometry" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();

    map.append(lane_wave, .{ .lane = 1 });
    try std.testing.expect(map.waveformDragBeats(0, 10, 16) == null);
    try std.testing.expect(map.waveformDragBeats(1, 10, 16) != null);
    try std.testing.expect(map.navDragBeats(1, 10, 128) == null);
    try std.testing.expect(map.eqPointAt(1, .{ .x = 500, .y = 140 }) == null);

    map.append(lane_nav, .{ .nav = 1 });
    map.append(lane_plot, .{ .eq_plot = 1 });
    try std.testing.expect(map.navDragBeats(1, 10, 128) != null);
    try std.testing.expect(map.eqPointAt(1, .{ .x = 500, .y = 140 }) != null);
}

test "a waveform drag moves the window against the pointer" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    drawLaneFrame(&map, 0, lane_wave);

    try expectClose(0.4, map.waveformDragBeats(0, -10, 16).?);
    try expectClose(-0.4, map.waveformDragBeats(0, 10, 16).?);
    try std.testing.expect(map.waveformDragBeats(0, 10, 0) == null);
}

test "a navigator drag scales by the whole track" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    drawLaneFrame(&map, 0, lane_wave);

    try expectClose(32, map.navDragBeats(0, 80, 128).?);
    try std.testing.expect(map.navDragBeats(0, 80, 0) == null);
}

test "a navigator press clamps to the track bounds" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    drawLaneFrame(&map, 0, lane_wave);

    try expectClose(0, map.navBeatAt(0, 0, 128).?);
    try expectClose(64, map.navBeatAt(0, 200, 128).?);
    try expectClose(128, map.navBeatAt(0, 900, 128).?);
}

test "an EQ plot maps x to frequency and y to gain" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    drawLaneFrame(&map, 0, lane_wave);

    const low = map.eqPointAt(0, .{ .x = 440, .y = 100 }).?;
    try expectClose(pl.mixer.eq_min_hz, low.freq_hz);
    try expectClose(pl.mixer.eq_max_gain_db, low.gain_db);

    const middle = map.eqPointAt(0, .{ .x = 500, .y = 140 }).?;
    try expectClose(800, middle.freq_hz);
    try expectClose(0, middle.gain_db);

    const high = map.eqPointAt(0, .{ .x = 900, .y = 400 }).?;
    try expectClose(pl.mixer.eq_max_hz, high.freq_hz);
    try expectClose(-pl.mixer.eq_max_gain_db, high.gain_db);
}

test "a press on a ball targets that band" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    drawLaneFrame(&map, 0, lane_wave);

    switch (map.hit(.{ .x = 450, .y = 135 }).?) {
        .eq_node => |at| {
            try std.testing.expectEqual(@as(usize, 0), at.lane);
            try std.testing.expectEqual(@as(usize, 0), at.band);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "an EQ node drag reports the current point" {
    var drag = Drag{};
    _ = drag.press(.{ .eq_node = .{ .lane = 0, .band = 1 } }, .{ .x = 495, .y = 135 }, false);
    const pull = drag.pull(.{ .x = 505, .y = 125 }).?;
    try expectClose(505, pull.p.x);
    try expectClose(125, pull.p.y);
}

test "a trim bar maps the top to boost and the bottom to cut" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    const bar: Rect = .{ .x = 900, .y = 100, .w = 16, .h = 200 };
    map.append(bar, .{ .trim = 0 });

    try expectClose(pl.mixer.trim_max_db, map.trimValueAt(0, bar.y).?);
    try expectClose(0, map.trimValueAt(0, bar.centerY()).?);
    try expectClose(-pl.mixer.trim_max_db, map.trimValueAt(0, bar.bottom()).?);
    try expectClose(pl.mixer.trim_max_db, map.trimValueAt(0, bar.y - 50).?);
    try expectClose(-pl.mixer.trim_max_db, map.trimValueAt(0, bar.bottom() + 50).?);
    try std.testing.expect(map.trimValueAt(1, bar.centerY()) == null);
}

test "a trim press sets the gain and drags in place" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    map.append(.{ .x = 900, .y = 100, .w = 16, .h = 200 }, .{ .trim = 0 });

    var drag = Drag{};
    const action = drag.press(.{ .trim = 0 }, .{ .x = 908, .y = 150 }, false);
    switch (action) {
        .set_trim => |index| try std.testing.expectEqual(@as(usize, 0), index),
        else => return error.TestUnexpectedResult,
    }

    const pull = drag.pull(.{ .x = 908, .y = 250 }).?;
    switch (pull.target) {
        .trim => |index| try std.testing.expectEqual(@as(usize, 0), index),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!drag.motion(.{ .x = 908, .y = 250 }, 4, viewport, &.{}));
}
