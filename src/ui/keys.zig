//! Key bindings, read from a file so a key is not a source edit.
//!
//! The file is one `name = key` per line, in the order the actions are listed
//! here; `#` starts a comment. Keys are dvui's key names, lowercase, so `u`,
//! `space`, `escape`. A line naming an action that does not exist is ignored,
//! and a missing file leaves the defaults in place: the app is usable without
//! one.

const std = @import("std");

pub const Action = enum {
    /// Walks back through the edit history.
    undo,
    /// Starts and stops the transport.
    play,

    /// One key per variant, in the order the variants are listed above.
    pub const default_keys = [_][]const u8{ "u", "space" };

    pub fn defaultKey(self: Action) []const u8 {
        return default_keys[@intFromEnum(self)];
    }
};

pub const Bindings = struct {
    keys: [@typeInfo(Action).@"enum".field_names.len][]const u8 = Action.default_keys,

    pub fn keyFor(self: *const Bindings, action: Action) []const u8 {
        return self.keys[@intFromEnum(action)];
    }

    /// The action a key name asks for, or null when the key is unbound.
    pub fn actionFor(self: *const Bindings, key_name: []const u8) ?Action {
        for (self.keys, 0..) |bound, index| {
            if (std.ascii.eqlIgnoreCase(bound, key_name)) return @enumFromInt(index);
        }
        return null;
    }
};

/// The default path: `$XDG_CONFIG_HOME/alchimix/keys`, or under `$HOME`.
pub fn defaultPath(allocator: std.mem.Allocator, home: ?[]const u8, config_home: ?[]const u8) ![]u8 {
    if (config_home) |base| return std.fmt.allocPrint(allocator, "{s}/alchimix/keys", .{base});
    const base = home orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/alchimix/keys", .{base});
}

/// Parses a bindings file over the defaults. Only the names present take
/// effect, so a file may name one action and inherit the rest.
pub fn parse(contents: []const u8) Bindings {
    var bindings = Bindings{};
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const split = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..split], " \t");
        const key = std.mem.trim(u8, line[split + 1 ..], " \t");
        if (name.len == 0 or key.len == 0) continue;
        const action = std.meta.stringToEnum(Action, name) orelse continue;
        // The key has to outlive the file contents, so it is interned into the
        // static table of names the config may use.
        bindings.keys[@intFromEnum(action)] = intern(key) orelse continue;
    }
    return bindings;
}

/// Key names are short and few; a fixed table keeps `Bindings` free of an
/// allocator and of a lifetime tied to the file.
const names = [_][]const u8{
    "u",      "space", "escape", "enter", "a", "b", "c", "d", "e", "f", "g",
    "h",      "i",     "j",      "k",     "l", "m", "n", "o", "p", "q", "r",
    "s",      "t",     "v",      "w",     "x", "y", "z", ".", ",", "/", ";",
    "backspace", "tab", "delete", "up", "down", "left", "right",
};

fn intern(key: []const u8) ?[]const u8 {
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(name, key)) return name;
    }
    return null;
}

const testing = std.testing;

test "the defaults bind undo to u and play to space" {
    const bindings = Bindings{};
    try testing.expectEqualStrings("u", bindings.keyFor(.undo));
    try testing.expectEqualStrings("space", bindings.keyFor(.play));
    try testing.expectEqual(Action.undo, bindings.actionFor("u"));
    try testing.expectEqual(Action.play, bindings.actionFor("space"));
    try testing.expectEqual(@as(?Action, null), bindings.actionFor("z"));
}

test "a file rebinds one action and leaves the others alone" {
    const bindings = parse(
        \\# keys
        \\undo = z
        \\
        \\play = enter
        \\
    );
    try testing.expectEqualStrings("z", bindings.keyFor(.undo));
    try testing.expectEqualStrings("enter", bindings.keyFor(.play));
    try testing.expectEqual(Action.undo, bindings.actionFor("Z"));
}

test "a line naming no action, or a key the app cannot name, changes nothing" {
    const bindings = parse(
        \\nonsense = q
        \\undo = meta_cmd_t
        \\play
        \\
    );
    try testing.expectEqualStrings("u", bindings.keyFor(.undo));
    try testing.expectEqualStrings("space", bindings.keyFor(.play));
}

test "the path follows XDG_CONFIG_HOME, then HOME" {
    const allocator = testing.allocator;
    const with_xdg = try defaultPath(allocator, "/home/u", "/xdg");
    defer allocator.free(with_xdg);
    try testing.expectEqualStrings("/xdg/alchimix/keys", with_xdg);

    const with_home = try defaultPath(allocator, "/home/u", null);
    defer allocator.free(with_home);
    try testing.expectEqualStrings("/home/u/.config/alchimix/keys", with_home);
}
