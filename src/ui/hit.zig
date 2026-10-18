//! What the pointer is over, and what a press-move-release does.
//!
//! The draw pass appends the rectangles it laid out; the pointer pass reads the
//! map from the previous frame. Nothing here imports dvui, so the rules run
//! under `zig build test` without a window.

const std = @import("std");
const pl = @import("playlister");

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
    /// The filter slider of a preview lane.
    slider: usize,
};

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
            .block => |index| blk: {
                if (shift) break :blk .{ .toggle_block = index };
                self.pressed = target;
                break :blk .{ .select_block = index };
            },
            .row, .lane, .slider => blk: {
                self.pressed = target;
                break :blk .none;
            },
        };
    }

    pub const Pull = struct {
        target: Target,
        /// Movement since the previous call, in screen units.
        dx: f32,
    };

    /// Horizontal movement of a lane or a slider, measured incrementally so the
    /// caller can apply it without knowing the press point.
    pub fn pull(self: *Drag, p: Point) ?Pull {
        const pressed = self.pressed orelse return null;
        switch (pressed) {
            .lane, .slider => {},
            else => return null,
        }
        const dx = p.x - self.press_at.x;
        self.press_at = p;
        return .{ .target = pressed, .dx = dx };
    }

    /// True when the frame has something new to draw.
    pub fn motion(self: *Drag, p: Point, threshold: f32, canvas: Rect, hit_map: *const HitMap) bool {
        const pressed = self.pressed orelse return false;
        switch (pressed) {
            .lane, .slider => return false,
            else => {},
        }
        if (self.carrying == null) {
            if (!moved(self.press_at, p, threshold)) return false;
            self.carrying = pressed;
        }
        self.gap = if (canvas.contains(p)) hit_map.gapAt(p.y) else null;
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
            .toggle, .notation, .lane, .slider => .none,
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

test "a press with no movement adds nothing" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    map.append(.{ .x = 0, .y = 0, .w = 400, .h = 80 }, .{ .row = T.track(1) });

    var drag = Drag{};
    _ = drag.press(.{ .row = T.track(1) }, .{ .x = 10, .y = 10 }, false);
    try std.testing.expect(!drag.motion(.{ .x = 12, .y = 11 }, 6, viewport, &map));
    try std.testing.expect(isNone(drag.release()));
}

test "movement past the threshold starts carrying" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    map.append(.{ .x = 0, .y = 0, .w = 400, .h = 80 }, .{ .row = T.track(7) });

    var drag = Drag{};
    _ = drag.press(.{ .row = T.track(7) }, .{ .x = 10, .y = 10 }, false);
    try std.testing.expect(drag.motion(.{ .x = 40, .y = 40 }, 6, viewport, &map));
    try std.testing.expectEqual(@as(u64, 7), drag.carriedTrack().?.id);
    try std.testing.expectEqual(@as(?usize, 0), drag.gapIndex());
}

test "releasing over the canvas drops the carried track at the gap" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    map.append(.{ .x = 0, .y = 0, .w = 400, .h = 100 }, .{ .block = 0 });
    map.append(.{ .x = 0, .y = 100, .w = 400, .h = 100 }, .{ .block = 1 });

    var drag = Drag{};
    _ = drag.press(.{ .row = T.track(9) }, .{ .x = 10, .y = 10 }, false);
    _ = drag.motion(.{ .x = 300, .y = 180 }, 6, viewport, &map);

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

    var drag = Drag{};
    _ = drag.press(.{ .row = T.track(9) }, .{ .x = 10, .y = 10 }, false);
    _ = drag.motion(.{ .x = 900, .y = 10 }, 6, viewport, &map);
    try std.testing.expect(drag.gapIndex() == null);
    try std.testing.expect(isNone(drag.release()));
}

test "a block drag reports the move and its source" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    map.append(.{ .x = 0, .y = 0, .w = 400, .h = 100 }, .{ .block = 0 });
    map.append(.{ .x = 0, .y = 100, .w = 400, .h = 100 }, .{ .block = 1 });

    var drag = Drag{};
    const pressed = drag.press(.{ .block = 0 }, .{ .x = 10, .y = 10 }, false);
    switch (pressed) {
        .select_block => |index| try std.testing.expectEqual(@as(usize, 0), index),
        else => return error.WrongAction,
    }

    _ = drag.motion(.{ .x = 10, .y = 150 }, 6, viewport, &map);
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
    try std.testing.expect(!drag.motion(.{ .x = 90, .y = 60 }, 6, viewport, &map));
    try std.testing.expect(isNone(drag.release()));
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
    try std.testing.expect(!drag.motion(.{ .x = 60, .y = 60 }, 6, viewport, &map));
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
    try std.testing.expect(!drag.motion(.{ .x = 10, .y = 200 }, 6, viewport, &map));
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

test "a slider press pulls without a gap" {
    var map = HitMap.init(std.testing.allocator);
    defer map.deinit();
    map.append(.{ .x = 0, .y = 0, .w = 400, .h = 20 }, .{ .slider = 0 });

    var drag = Drag{};
    _ = drag.press(.{ .slider = 0 }, .{ .x = 10, .y = 10 }, false);
    const pull = drag.pull(.{ .x = 25, .y = 10 }).?;
    try std.testing.expectEqual(@as(f32, 15), pull.dx);
    try std.testing.expect(drag.gapIndex() == null);
}
