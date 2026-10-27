//! Tests for modules the library root does not re-export.

test {
    _ = @import("ui/app.zig");
    _ = @import("ui/dmt.zig");
    _ = @import("ui/geom.zig");
    _ = @import("ui/hit.zig");
    _ = @import("ui/keys.zig");
    _ = @import("ui/lsd.zig");
    _ = @import("ui/mushroom.zig");
    _ = @import("ui/playlists.zig");
    _ = @import("ui/undo.zig");
    _ = @import("ui/wave.zig");
    _ = @import("ui/wave_colour.zig");
}
