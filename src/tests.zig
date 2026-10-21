//! Tests for modules the library root does not re-export.

test {
    _ = @import("ui/dmt.zig");
    _ = @import("ui/geom.zig");
    _ = @import("ui/hit.zig");
    _ = @import("ui/lsd.zig");
    _ = @import("ui/wave.zig");
    _ = @import("ui/wave_colour.zig");
}
