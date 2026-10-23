//! The port every track source implements. The app talks to this and never to
//! a database.

const std = @import("std");
const Track = @import("../domain/track.zig").Track;
const Analysis = @import("../domain/analysis.zig").Analysis;

pub const PlaylistKind = enum { list, smart, folder };

/// One rekordbox playlist, intelligent playlist or folder. Strings live as
/// long as the source.
pub const Playlist = struct {
    id: []const u8,
    name: []const u8,
    parent: []const u8,
    kind: PlaylistKind,
};

pub const Library = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Every track, in source order. Slice is owned by the source and lives
        /// until `deinit`.
        all: *const fn (ctx: *anyopaque) anyerror![]const Track,
        /// Tracks whose title, artist, genre or tags match `needle`, best
        /// match first. An empty needle returns `all`.
        search: *const fn (ctx: *anyopaque, needle: []const u8) anyerror![]const Track,
        /// The beat grid and preview waveform for one track. The caller owns
        /// the result and must `deinit` it with the same allocator.
        analysis: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, track_id: u64) anyerror!Analysis,
        /// Every playlist and folder, in source order.
        playlists: *const fn (ctx: *anyopaque) anyerror![]const Playlist,
        /// Track ids in a playlist, in playlist order. Caller frees.
        playlistTracks: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, playlist_id: []const u8) anyerror![]const u64,
        /// Writes a new playlist with the given tracks, in order.
        createPlaylist: *const fn (ctx: *anyopaque, name: []const u8, track_ids: []const u64) anyerror!void,
        /// Replaces an existing playlist's tracks, in order.
        replacePlaylistTracks: *const fn (ctx: *anyopaque, playlist_id: []const u8, track_ids: []const u64) anyerror!void,
        /// Renames a playlist in place, leaving its tracks untouched.
        renamePlaylist: *const fn (ctx: *anyopaque, playlist_id: []const u8, playlist_name: []const u8) anyerror!void,
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

    pub fn analysis(self: Library, allocator: std.mem.Allocator, track_id: u64) !Analysis {
        return self.vtable.analysis(self.ctx, allocator, track_id);
    }

    pub fn playlists(self: Library) ![]const Playlist {
        return self.vtable.playlists(self.ctx);
    }

    pub fn playlistTracks(self: Library, allocator: std.mem.Allocator, playlist_id: []const u8) ![]const u64 {
        return self.vtable.playlistTracks(self.ctx, allocator, playlist_id);
    }

    pub fn createPlaylist(self: Library, playlist_name: []const u8, track_ids: []const u64) !void {
        return self.vtable.createPlaylist(self.ctx, playlist_name, track_ids);
    }

    pub fn replacePlaylistTracks(self: Library, playlist_id: []const u8, track_ids: []const u64) !void {
        return self.vtable.replacePlaylistTracks(self.ctx, playlist_id, track_ids);
    }

    pub fn renamePlaylist(self: Library, playlist_id: []const u8, playlist_name: []const u8) !void {
        return self.vtable.renamePlaylist(self.ctx, playlist_id, playlist_name);
    }

    pub fn name(self: Library) []const u8 {
        return self.vtable.name(self.ctx);
    }

    pub fn deinit(self: Library) void {
        self.vtable.deinit(self.ctx);
    }
};
