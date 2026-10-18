//! The port every track source implements. The app talks to this and never to
//! a database.

const std = @import("std");
const Track = @import("../domain/track.zig").Track;

pub const Library = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Every track, in source order. Slice is owned by the source and lives
        /// until `deinit`.
        all: *const fn (ctx: *anyopaque) anyerror![]const Track,
        /// Tracks whose title or artist contains `needle`. An empty needle
        /// returns `all`.
        search: *const fn (ctx: *anyopaque, needle: []const u8) anyerror![]const Track,
        /// Shown in the UI so the active source is never a guess.
        name: *const fn (ctx: *anyopaque) []const u8,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn all(self: Library) ![]const Track {
        return self.vtable.all(self.ctx);
    }

    pub fn search(self: Library, needle: []const u8) ![]const Track {
        return self.vtable.search(self.ctx, needle);
    }

    pub fn name(self: Library) []const u8 {
        return self.vtable.name(self.ctx);
    }

    pub fn deinit(self: Library) void {
        self.vtable.deinit(self.ctx);
    }
};
