//! Which controller moves which parameter.
//!
//! The table is a line per assignment: `channel control parameter lane`, where
//! parameter is one of the names below. It lives beside the key bindings so the
//! whole of the input surface is in one directory.

const std = @import("std");
const midi = @import("alchimix").midi;

pub const Param = enum {
    eq_low,
    eq_mid,
    eq_high,
    trim,
    master_bpm,

    /// Which EQ band this names, if any.
    pub fn band(self: Param) ?usize {
        return switch (self) {
            .eq_low => 0,
            .eq_mid => 1,
            .eq_high => 2,
            else => null,
        };
    }
};

pub const Target = struct {
    lane: usize = 0,
    param: Param = .trim,
};

pub const Assignment = struct {
    channel: u4 = 0,
    control: u7 = 0,
    target: Target,

    pub fn matches(self: Assignment, message: midi.Message) bool {
        return self.channel == message.channel and self.control == message.control;
    }
};

/// A full turn of the knob maps the parameter's whole range.
pub fn value(param: Param, cc: u7) f32 {
    const fraction = @as(f32, @floatFromInt(cc)) / 127;
    return switch (param) {
        .eq_low, .eq_mid, .eq_high, .trim => -12 + 24 * fraction,
        .master_bpm => 90 + 90 * fraction,
    };
}

pub const ParseError = error{TooMany};

/// Reads a table into `out`, skipping blank lines and comments. A malformed
/// line is ignored rather than failing the load: one bad edit of the file must
/// not leave the controller dead.
pub fn parse(text: []const u8, out: []Assignment) ParseError![]Assignment {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (count >= out.len) return error.TooMany;

        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const channel = std.fmt.parseInt(u8, fields.next() orelse continue, 10) catch continue;
        const control = std.fmt.parseInt(u8, fields.next() orelse continue, 10) catch continue;
        const name = fields.next() orelse continue;
        const param = std.meta.stringToEnum(Param, name) orelse continue;
        const lane = std.fmt.parseInt(usize, fields.next() orelse "0", 10) catch continue;
        if (channel > 15 or control > 127) continue;

        out[count] = .{
            .channel = @intCast(channel),
            .control = @intCast(control),
            .target = .{ .lane = lane, .param = param },
        };
        count += 1;
    }
    return out[0..count];
}

/// The same table, one line per assignment, for writing the file back.
pub fn format(assignments: []const Assignment, writer: anytype) !void {
    try writer.writeAll("# channel control parameter lane\n");
    for (assignments) |assignment| {
        try writer.print("{d} {d} {s} {d}\n", .{
            assignment.channel,
            assignment.control,
            @tagName(assignment.target.param),
            assignment.target.lane,
        });
    }
}

const testing = std.testing;

test "a table line names a channel, a control, a parameter and a lane" {
    var buffer: [8]Assignment = undefined;
    const parsed = try parse(
        \\# controllers
        \\0 7 trim 2
        \\1 21 eq_low 0
        \\
    , &buffer);
    try testing.expectEqual(@as(usize, 2), parsed.len);
    try testing.expectEqual(@as(u4, 0), parsed[0].channel);
    try testing.expectEqual(@as(u7, 7), parsed[0].control);
    try testing.expectEqual(Param.trim, parsed[0].target.param);
    try testing.expectEqual(@as(usize, 2), parsed[0].target.lane);
    try testing.expectEqual(Param.eq_low, parsed[1].target.param);
}

test "a broken line is skipped and the rest of the table loads" {
    var buffer: [8]Assignment = undefined;
    const parsed = try parse(
        \\nonsense
        \\0 7 nothing 0
        \\16 7 trim 0
        \\0 200 trim 0
        \\0 9 master_bpm 0
        \\
    , &buffer);
    try testing.expectEqual(@as(usize, 1), parsed.len);
    try testing.expectEqual(Param.master_bpm, parsed[0].target.param);
}

test "a table longer than the buffer is refused rather than truncated" {
    var buffer: [1]Assignment = undefined;
    try testing.expectError(error.TooMany, parse("0 1 trim 0\n0 2 trim 0\n", &buffer));
}

test "a control matches on both channel and number" {
    const assignment = Assignment{ .channel = 3, .control = 42, .target = .{ .param = .trim } };
    try testing.expect(assignment.matches(.{ .channel = 3, .control = 42, .value = 0 }));
    try testing.expect(!assignment.matches(.{ .channel = 3, .control = 41, .value = 0 }));
    try testing.expect(!assignment.matches(.{ .channel = 2, .control = 42, .value = 0 }));
}

test "the knob's ends are the parameter's ends" {
    try testing.expectEqual(@as(f32, -12), value(.trim, 0));
    try testing.expectEqual(@as(f32, 12), value(.trim, 127));
    try testing.expectApproxEqAbs(@as(f32, 0), value(.eq_mid, 63), 0.25);
    try testing.expectEqual(@as(f32, 90), value(.master_bpm, 0));
    try testing.expectEqual(@as(f32, 180), value(.master_bpm, 127));
}

test "a table written out reads back the same" {
    var buffer: [8]Assignment = undefined;
    var list: std.Io.Writer.Allocating = .init(testing.allocator);
    defer list.deinit();

    const original = [_]Assignment{
        .{ .channel = 2, .control = 10, .target = .{ .lane = 1, .param = .eq_high } },
        .{ .channel = 0, .control = 64, .target = .{ .lane = 3, .param = .master_bpm } },
    };
    try format(&original, &list.writer);

    const parsed = try parse(list.written(), &buffer);
    try testing.expectEqual(@as(usize, 2), parsed.len);
    try testing.expectEqual(original[0].channel, parsed[0].channel);
    try testing.expectEqual(original[0].control, parsed[0].control);
    try testing.expectEqual(original[0].target.param, parsed[0].target.param);
    try testing.expectEqual(original[1].target.lane, parsed[1].target.lane);
}
