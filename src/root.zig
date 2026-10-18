//! Public surface of the playlist builder.

pub const camelot = @import("domain/camelot.zig");
pub const bpm = @import("domain/bpm.zig");
pub const track = @import("domain/track.zig");
pub const crate = @import("domain/crate.zig");
pub const suggest = @import("domain/suggest.zig");
pub const analysis = @import("domain/analysis.zig");
pub const mixer = @import("audio/mixer.zig");

pub const library = @import("ports/library.zig");
pub const player = @import("audio/player.zig");

pub const memory = @import("adapters/memory.zig");
pub const rekordbox = @import("adapters/rekordbox.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = camelot;
    _ = bpm;
    _ = track;
    _ = crate;
    _ = library;
    _ = player;
    _ = memory;
}
