//! The eight garden features mushroom mode can switch on, with the short line
//! shown in the panel and the longer one behind its arrow.

const std = @import("std");

pub const Feature = struct {
    title: []const u8,
    blurb: []const u8,
    detail: []const u8,
};

pub const count = 4;

pub const list = [_]Feature{
    .{
        .title = "Fairy ring",
        .blurb = "Light rings",
        .detail = "Every so often a ring of small mushrooms lights in order, " ++
            "the glow running around the circle.",
    },
    .{
        .title = "Press wave",
        .blurb = "Ripples out",
        .detail = "A press sends one bright front travelling out from the shamrock " ++
            "across the field.",
    },
    .{
        .title = "Birth spot",
        .blurb = "Same spot",
        .detail = "A retiring mushroom is replaced a short step away, so patches persist " ++
            "instead of the field reshuffling.",
    },
    .{
        .title = "Stems lean",
        .blurb = "Tips at bugs",
        .detail = "A nearby insect bends the stems toward it for a moment, then they " ++
            "straighten.",
    },
};

/// Which features are on, and which rows have their arrow dropped.
pub const State = struct {
    on: [count]bool = @splat(true),
    open: [count]bool = @splat(false),

    pub fn enabled(self: State, index: usize) bool {
        return index < count and self.on[index];
    }

    pub fn toggle(self: *State, index: usize) void {
        if (index >= count) return;
        self.on[index] = !self.on[index];
    }

    pub fn dropDown(self: *State, index: usize) void {
        if (index >= count) return;
        self.open[index] = !self.open[index];
    }
};

test "a feature toggles independently" {
    var state: State = .{};
    try std.testing.expect(state.enabled(3));
    state.toggle(2);
    try std.testing.expect(!state.enabled(2));
    try std.testing.expect(state.enabled(3));
}

test "an out of range feature is refused rather than crashing" {
    var state: State = .{};
    state.toggle(count + 4);
    state.dropDown(count + 4);
    try std.testing.expect(!state.enabled(count + 4));
}
