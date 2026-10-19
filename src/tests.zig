//! Tests for modules the library root does not re-export.

test {
    _ = @import("ui/hit.zig");
    _ = @import("ui/wave.zig");
    _ = @import("ui/wave_colour.zig");
}
