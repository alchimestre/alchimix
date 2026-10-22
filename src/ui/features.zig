//! The eight garden features mushroom mode can switch on, with the short line
//! shown in the panel and the longer one behind its arrow.

const std = @import("std");

pub const Feature = struct {
    title: []const u8,
    blurb: []const u8,
    detail: []const u8,
};

pub const count = 8;

pub const list = [_]Feature{
    .{
        .title = "Fairy ring",
        .blurb = "Light runs a ring",
        .detail = "Once a minute a ring of small mushrooms lights in sequence, " ++
            "the glow travelling around the circle before settling back.",
    },
    .{
        .title = "Music is weather",
        .blurb = "No music, no rain",
        .detail = "While a track plays, rain falls, insects walk and the field shimmers. " ++
            "When playback stops the drops finish and no new ones come, leaving only the drift.",
    },
    .{
        .title = "Press sends a wave",
        .blurb = "Press ripples out",
        .detail = "A press on the shamrock sends one expanding wave of mushrooms popping " ++
            "away from it, rather than a single patch reacting.",
    },
    .{
        .title = "Wet caps",
        .blurb = "Rain tints caps",
        .detail = "A drop that waters a mushroom turns its cap colder and brighter for a few " ++
            "seconds, drying back to its own colour.",
    },
    .{
        .title = "Birth inherits",
        .blurb = "Regrows in place",
        .detail = "A retiring mushroom is replaced within a short step of where it stood, so " ++
            "patches persist instead of the field reshuffling.",
    },
    .{
        .title = "Stems lean",
        .blurb = "Stems tip at bugs",
        .detail = "When an insect walks close, the nearest stems bend toward it for a moment " ++
            "and then straighten.",
    },
    .{
        .title = "Spore puff",
        .blurb = "A puff as it goes",
        .detail = "As a mushroom retires, three dots rise from its cap in its own colour and " ++
            "fade, so it leaves with a breath rather than vanishing.",
    },
    .{
        .title = "Snail",
        .blurb = "Crawler and trail",
        .detail = "A snail crosses the garden far slower than the insects, leaving a trail of " ++
            "dots that fades behind it.",
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
    state.toggle(3);
    try std.testing.expect(!state.enabled(3));
    try std.testing.expect(state.enabled(4));
}

test "an out of range feature is refused rather than crashing" {
    var state: State = .{};
    state.toggle(count + 4);
    state.dropDown(count + 4);
    try std.testing.expect(!state.enabled(count + 4));
}
