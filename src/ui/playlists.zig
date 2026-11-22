//! The playlist column: the source's playlists and folders, the crate's save
//! chip, and the rows that open, rename or delete them.

const std = @import("std");
const dvui = @import("dvui");
const pl = @import("alchimix");
const hit = @import("hit.zig");
const app_mod = @import("app.zig");
const undo_mod = @import("undo.zig");

const App = app_mod.App;
const Palette = app_mod.Palette;
const square = app_mod.square;
const secondsNow = app_mod.secondsNow;
const rectFrom = app_mod.rectFrom;
const fillRect = app_mod.fillRect;
const shortName = app_mod.shortName;
const labelStyled = app_mod.labelStyled;
const bodyFont = app_mod.bodyFont;
const metaFont = app_mod.metaFont;
const headingFont = app_mod.headingFont;

/// What the last write did, shown on the save chip until its timeout.
pub const Outcome = enum { none, saved, failed, stale, running };

/// Where a save writes: back into the open playlist, or into a new one.
pub const SaveTarget = union(enum) { replace: []const u8, create: []const u8, refused };

pub const Panel = struct {
    /// Playlists and folders from the source. Strings live in the source.
    rows: []const pl.library.Playlist = &.{},
    /// Folders whose children are shown; ids are borrowed from `rows`.
    folders: [64][]const u8 = undefined,
    open_count: usize = 0,
    /// The playlist open in the crate, for the row highlight.
    open_playlist: ?[]const u8 = null,
    /// The playlist's track ids as they were when the crate was loaded or last
    /// saved: what a save must still find in the source.
    open_ids: []u64 = &.{},
    /// What the last write did, shown on its chip until `outcome_until`.
    outcome: Outcome = .none,
    outcome_until: f64 = 0,
    /// The name a shift press on the save chip is typing, and the field's rect
    /// from the last frame, so a press outside it can close it.
    naming_save: bool = false,
    save_name: std.ArrayList(u8) = .empty,
    save_name_focus: bool = false,
    save_field: hit.Rect = .{},
    /// The playlist a shift right press armed the chip to delete, by id.
    delete_playlist: ?[]const u8 = null,
    /// The row open for an inline rename, by id, and the text in it.
    renaming: ?[]u8 = null,
    /// Where the rename field's caret goes this frame, painted after the row.
    rename_caret: ?hit.Rect = null,
    rename_text: std.ArrayList(u8) = .empty,
    /// A rename just started, so the next frame focuses its field and puts the
    /// cursor at the end.
    rename_focus: bool = false,

    pub fn deinit(self: *Panel, allocator: std.mem.Allocator) void {
        self.release(allocator);
        if (self.renaming) |id| allocator.free(id);
        self.rename_text.deinit(allocator);
        self.save_name.deinit(allocator);
        if (self.delete_playlist) |id| allocator.free(id);
    }

    fn release(self: *Panel, allocator: std.mem.Allocator) void {
        if (self.open_playlist) |id| allocator.free(id);
        allocator.free(self.open_ids);
        self.open_playlist = null;
        self.open_ids = &.{};
    }

    /// Opens `id` with the membership it had when loaded. A failed copy leaves
    /// the previous binding untouched.
    pub fn bind(self: *Panel, allocator: std.mem.Allocator, id: []const u8, loaded: []const u64) !void {
        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);
        const owned_ids = try allocator.dupe(u64, loaded);
        self.release(allocator);
        self.open_playlist = owned_id;
        self.open_ids = owned_ids;
    }

    /// Puts back the binding an undone crate edit had. The same playlist keeps
    /// its current membership, which is newer than the one in the entry.
    pub fn rebind(self: *Panel, allocator: std.mem.Allocator, playlist: ?[]const u8, loaded: []const u64) !void {
        const id = playlist orelse return self.release(allocator);
        if (self.open_playlist) |current| {
            if (std.mem.eql(u8, current, id)) return;
        }
        try self.bind(allocator, id, loaded);
    }

    /// After a successful replace the written ids are what the source holds.
    fn rebaseline(self: *Panel, allocator: std.mem.Allocator, written: []const u64) void {
        // A failed copy keeps the old baseline, so the next save reports stale instead of overwriting.
        const copy = allocator.dupe(u64, written) catch return;
        allocator.free(self.open_ids);
        self.open_ids = copy;
    }

    /// A cleared crate forgets the playlist it came from.
    pub fn clear(self: *Panel, app: *App) void {
        self.release(app.allocator);
        self.cancelRename(app);
        self.open_count = 0;
    }

    fn indexOf(self: *const Panel, id: []const u8) ?usize {
        for (self.rows, 0..) |row, index| {
            if (std.mem.eql(u8, row.id, id)) return index;
        }
        return null;
    }

    fn flash(self: *Panel, outcome: Outcome) void {
        self.outcome = outcome;
        self.outcome_until = secondsNow() + flash_seconds;
        dvui.refresh(null, @src(), null);
    }

    pub fn flashFailed(self: *Panel) void {
        self.flash(.failed);
    }

    pub fn flashError(self: *Panel, err: anyerror) void {
        self.flash(outcomeOf(err));
    }

    fn outcomeOf(err: anyerror) Outcome {
        return switch (err) {
            error.StalePlaylist, error.PlaylistNotFound => .stale,
            error.RekordboxRunning => .running,
            else => .failed,
        };
    }

    /// A plain press on the save chip: write, then show the result on the chip.
    pub fn save(self: *Panel, app: *App) void {
        self.flash(self.saveCratePlaylist(app, null));
    }

    /// True while a row is an open field, so the caret keeps asking for frames.
    pub fn editing(self: *const Panel) bool {
        return self.renaming != null;
    }

    pub fn folderOpen(self: *const Panel, id: []const u8) bool {
        for (self.folders[0..self.open_count]) |open| {
            if (std.mem.eql(u8, open, id)) return true;
        }
        return false;
    }

    pub fn toggleFolder(self: *Panel, id: []const u8) void {
        if (self.folderOpen(id)) {
            var index: usize = 0;
            while (index < self.open_count) : (index += 1) {
                if (!std.mem.eql(u8, self.folders[index], id)) continue;
                self.folders[index] = self.folders[self.open_count - 1];
                self.open_count -= 1;
                break;
            }
        } else if (self.open_count < self.folders.len) {
            self.folders[self.open_count] = id;
            self.open_count += 1;
        }
        dvui.refresh(null, @src(), null);
    }

    /// Shift-click on a playlist row: the name becomes a field in place.
    pub fn startRename(self: *Panel, app: *App, id: []const u8) void {
        const index = self.indexOf(id) orelse return;
        const playlist = self.rows[index];
        self.cancelRename(app);
        self.rename_text.appendSlice(app.allocator, playlist.name) catch return;
        self.renaming = app.allocator.dupe(u8, playlist.id) catch null;
        self.rename_focus = true;
        dvui.refresh(null, @src(), null);
    }

    pub fn cancelRename(self: *Panel, app: *App) void {
        if (self.renaming) |id| app.allocator.free(id);
        self.renaming = null;
        self.rename_text.clearRetainingCapacity();
        self.rename_focus = false;
        dvui.refresh(null, @src(), null);
    }

    /// Writes the field through the source, then reloads the rows. The crate
    /// stays on its playlist because the selection is a copy of the id.
    pub fn commitRename(self: *Panel, app: *App) void {
        const id = self.renaming orelse return;
        const name = std.mem.trim(u8, self.rename_text.items, " \t");
        if (name.len == 0) {
            self.cancelRename(app);
            return;
        }
        self.renameChecked(app, id, name) catch |err| self.flash(outcomeOf(err));
        self.rows = app.library.playlists() catch &.{};
        self.cancelRename(app);
    }

    /// The undo entry is built before the write and kept only once it commits.
    fn renameChecked(self: *Panel, app: *App, id: []const u8, name: []const u8) !void {
        const index = self.indexOf(id) orelse return error.PlaylistNotFound;
        const change = try undo_mod.Change.ofRename(app.allocator, id, self.rows[index].name);
        errdefer change.deinit(app.allocator);
        try app.undo_history.reserve();
        try app.library.renamePlaylist(id, name);
        app.undo_history.push(change);
    }

    /// True when the press lands on the row being renamed, where the field
    /// handles its own clicks.
    pub fn renamingRow(self: *const Panel, app: *App, p: hit.Point) bool {
        const id = self.renaming orelse return false;
        const target = app.hit_map.hit(p) orelse return false;
        return switch (target) {
            .playlist => |row_id| std.mem.eql(u8, row_id, id),
            else => false,
        };
    }

    /// Opens a playlist in the crate, in playlist order, ready to edit. A
    /// playlist that cannot be loaded whole leaves the crate as it was.
    pub fn selectPlaylist(self: *Panel, app: *App, id: []const u8) void {
        const index = self.indexOf(id) orelse return;
        const playlist = self.rows[index];
        if (playlist.kind == .folder) {
            self.toggleFolder(playlist.id);
            return;
        }
        if (playlist.kind == .smart) return;

        self.openPlaylist(app, playlist) catch |err| {
            std.log.err("opening playlist {s}: {s}", .{ playlist.name, @errorName(err) });
            self.flash(.failed);
        };
    }

    fn openPlaylist(self: *Panel, app: *App, playlist: pl.library.Playlist) !void {
        const ids = try app.library.playlistTracks(app.allocator, playlist.id);
        defer app.allocator.free(ids);
        const staged = try stageTracks(app.allocator, try app.library.all(), ids);
        defer app.allocator.free(staged);
        try app.crate.items.ensureTotalCapacity(app.allocator, staged.len);
        try self.bind(app.allocator, playlist.id, ids);

        app.player.stopAll();
        app.scheduled.clear();
        app.transport.stopAll();
        app.transport.beginSync();
        app.transport.endSync();
        app.crate.clear();
        app.selected.clearRetainingCapacity();
        app.query.clearRetainingCapacity();
        app.played = .{};
        for (staged) |track| _ = app.crate.append(track) catch unreachable;

        app.grid_dirty = true;
        app.refresh() catch {};
        dvui.refresh(null, @src(), null);
    }

    /// The library's track for every id, in order. A member the library does
    /// not hold would shorten the crate and the next save would drop it.
    fn stageTracks(allocator: std.mem.Allocator, all: []const pl.track.Track, ids: []const u64) ![]pl.track.Track {
        const staged = try allocator.alloc(pl.track.Track, ids.len);
        errdefer allocator.free(staged);
        for (ids, staged) |id, *slot| {
            slot.* = for (all) |candidate| {
                if (candidate.id == id) break candidate;
            } else return error.TrackMissing;
        }
        return staged;
    }

    /// Seconds the save chip keeps its result before returning to its label.
    const flash_seconds: f64 = 1.5;

    fn saveFlash(self: *const Panel) Outcome {
        if (self.outcome == .none) return .none;
        if (secondsNow() >= self.outcome_until) return .none;
        return self.outcome;
    }

    /// The name a plain save gives a crate with no playlist of its own.
    pub fn automaticCrateName(app: *App, buffer: []u8) []const u8 {
        return if (app.crate.seedTrack()) |seed|
            std.fmt.bufPrint(buffer, "Crate · {s}", .{seed.title}) catch "Crate"
        else
            "Crate";
    }

    /// Where the crate writes. A typed name always opens a new playlist and is
    /// refused when the library already holds it; otherwise the crate writes
    /// back to its playlist, or into a new one under the automatic name.
    pub fn saveTarget(selected: ?[]const u8, chosen: ?[]const u8, automatic: []const u8, names: []const pl.library.Playlist) SaveTarget {
        if (chosen) |name| {
            for (names) |playlist| {
                if (std.mem.eql(u8, playlist.name, name)) return .refused;
            }
            return .{ .create = name };
        }
        if (selected) |playlist_id| return .{ .replace = playlist_id };
        return .{ .create = automatic };
    }

    /// Writes the crate back to its playlist, or into a new one.
    pub fn saveCratePlaylist(self: *Panel, app: *App, chosen_name: ?[]const u8) Outcome {
        const ids = app.allocator.alloc(u64, app.crate.len()) catch return .failed;
        defer app.allocator.free(ids);
        for (app.crate.items.items, ids) |track, *slot| slot.* = track.id;
        if (ids.len == 0) return .failed;

        var name_buffer: [128]u8 = undefined;
        const automatic = automaticCrateName(app, &name_buffer);
        switch (saveTarget(self.open_playlist, chosen_name, automatic, self.rows)) {
            .refused => return .failed,
            .replace => |playlist_id| {
                app.library.replacePlaylistTracks(playlist_id, self.open_ids, ids) catch |err| return outcomeOf(err);
                self.rebaseline(app.allocator, ids);
            },
            .create => |name| app.library.createPlaylist(name, ids) catch |err| return outcomeOf(err),
        }
        self.rows = app.library.playlists() catch &.{};
        return .saved;
    }

    /// A shift press on the save chip: the field under the header asks for a
    /// name, prefilled with the one a plain save would use.
    pub fn startNamedSave(self: *Panel, app: *App) void {
        self.cancelNamedSave();
        var name_buffer: [128]u8 = undefined;
        const name = automaticCrateName(app, &name_buffer);
        self.save_name.appendSlice(app.allocator, name) catch return;
        self.naming_save = true;
        self.save_name_focus = true;
        dvui.refresh(null, @src(), null);
    }

    pub fn cancelNamedSave(self: *Panel) void {
        self.naming_save = false;
        self.save_name.clearRetainingCapacity();
        self.save_name_focus = false;
        self.save_field = .{};
        dvui.refresh(null, @src(), null);
    }

    /// Writes the crate under the typed name. A name already in the library
    /// leaves the chip on `failed` and writes nothing.
    pub fn commitNamedSave(self: *Panel, app: *App) void {
        // The field can report the same Enter twice; the first commit closes
        // it, and a second would read its own new playlist as a duplicate.
        if (!self.naming_save) return;
        const name = std.mem.trim(u8, self.save_name.items, " \t");
        if (name.len == 0) {
            self.cancelNamedSave();
            return;
        }
        self.flash(self.saveCratePlaylist(app, name));
        self.cancelNamedSave();
    }

    /// A folder still holding playlists is not deletable: the port removes one
    /// row, so its children would be left under a parent that is gone.
    pub fn deletable(playlists: []const pl.library.Playlist, index: usize) bool {
        if (index >= playlists.len) return false;
        const target = playlists[index];
        if (target.kind != .folder) return true;
        for (playlists, 0..) |playlist, other| {
            if (other == index) continue;
            if (std.mem.eql(u8, playlist.parent, target.id)) return false;
        }
        return true;
    }

    /// Shift right press on a playlist row: the chip offers to delete it.
    pub fn armDelete(self: *Panel, app: *App, id: []const u8) void {
        const index = self.indexOf(id) orelse return;
        if (!deletable(self.rows, index)) return;
        self.cancelDelete(app);
        self.delete_playlist = app.allocator.dupe(u8, id) catch null;
        dvui.refresh(null, @src(), null);
    }

    pub fn cancelDelete(self: *Panel, app: *App) void {
        if (self.delete_playlist) |id| app.allocator.free(id);
        self.delete_playlist = null;
        dvui.refresh(null, @src(), null);
    }

    /// Removes the armed playlist. Its tracks stay in the library; a crate
    /// opened from it keeps its rows and simply stops writing back.
    pub fn commitDelete(self: *Panel, app: *App) void {
        const id = self.delete_playlist orelse return;
        self.deleteChecked(app, id) catch |err| {
            self.flash(outcomeOf(err));
            self.cancelDelete(app);
            return;
        };
        if (self.open_playlist) |selected| {
            if (std.mem.eql(u8, selected, id)) self.release(app.allocator);
        }
        self.rows = app.library.playlists() catch &.{};
        self.cancelDelete(app);
    }

    /// A delete takes its rows with it, so the snapshot comes first and a
    /// snapshot that cannot be taken blocks the delete.
    fn deleteChecked(self: *Panel, app: *App, id: []const u8) !void {
        const index = self.indexOf(id) orelse return error.PlaylistNotFound;
        const ids = try app.library.playlistTracks(app.allocator, id);
        defer app.allocator.free(ids);
        const change = try undo_mod.Change.ofDelete(app.allocator, self.rows[index], ids);
        errdefer change.deinit(app.allocator);
        try app.undo_history.reserve();
        try app.library.deletePlaylist(id);
        app.undo_history.push(change);
    }

    /// The name field a shift press opens, under the header.
    fn saveNameField(self: *Panel, app: *App) void {
        var entry = dvui.textEntry(@src(), .{ .text = .{ .array_list = .{
            .backing = &self.save_name,
            .allocator = app.allocator,
        } } }, .{
            .expand = .horizontal,
            .min_size_content = .{ .h = 20 },
            .padding = .{ .x = 4, .y = 1 },
            .margin = .{ .y = 2 },
            .corners = square,
            .background = true,
            .color_fill = .{ .color = Palette.field },
            .color_text = .{ .color = Palette.ink },
            .font = metaFont(),
            .id_extra = 7203,
        });
        if (self.save_name_focus) {
            dvui.focusWidget(entry.data().id, null, null);
            entry.textLayout.selection.moveCursor(self.save_name.items.len, false);
            self.save_name_focus = false;
        }
        app.noteTyping(entry.data().id);
        const enter = entry.enter_pressed;
        self.save_field = rectFrom(entry.data().borderRectScale().r);
        entry.deinit();
        if (enter) self.commitNamedSave(app);
    }

    fn playlistRow(self: *Panel, app: *App, playlist: pl.library.Playlist, index: usize, depth: usize) void {
        const selected = if (self.open_playlist) |id| std.mem.eql(u8, id, playlist.id) else false;
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .h = 24 },
            .padding = .{ .x = 4 + 12 * @as(f32, @floatFromInt(depth)), .y = 2 },
            .margin = .{ .y = 1 },
            .background = selected,
            .color_fill = .{ .color = Palette.selection },
            .color_fill_hover = .{ .color = Palette.hover },
            .id_extra = 7000 + index,
        });
        defer row.deinit();

        const target: hit.Target = if (playlist.kind == .folder)
            .{ .playlist_toggle = playlist.id }
        else
            .{ .playlist = playlist.id };
        app.hit_map.append(rectFrom(row.data().contentRectScale().r), target);

        if (self.renaming) |renaming_id| {
            if (std.mem.eql(u8, renaming_id, playlist.id)) {
                self.renameField(app, index);
                return;
            }
        }

        const glyph = switch (playlist.kind) {
            .folder => if (self.folderOpen(playlist.id)) "▾ " else "▸ ",
            .smart => "◆ ",
            .list => "",
        };
        var name_buffer: [32]u8 = undefined;
        var text: [40]u8 = undefined;
        const label = std.fmt.bufPrint(&text, "{s}{s}", .{ glyph, shortName(playlist.name, &name_buffer) }) catch playlist.name;
        labelStyled(@src(), label, .{
            .expand = .horizontal,
            .color_text = .{ .color = if (playlist.kind == .folder) Palette.purple else Palette.ink },
            .font = if (playlist.kind == .folder) headingFont() else bodyFont(),
            .id_extra = 7100 + index,
        });
    }

    /// The row's name as a field. Enter writes it, Escape and any click
    /// elsewhere revert.
    fn renameField(self: *Panel, app: *App, index: usize) void {
        var entry = dvui.textEntry(@src(), .{ .text = .{ .array_list = .{
            .backing = &self.rename_text,
            .allocator = app.allocator,
        } } }, .{
            .expand = .horizontal,
            .min_size_content = .{ .h = 20 },
            .padding = .{ .x = 4, .y = 1 },
            .margin = .{ .y = 0 },
            .corners = square,
            .background = true,
            .color_fill = .{ .color = Palette.field },
            .color_text = .{ .color = Palette.ink },
            .font = bodyFont(),
            .id_extra = 7200 + index,
        });
        if (self.rename_focus) {
            dvui.focusWidget(entry.data().id, null, null);
            entry.textLayout.selection.moveCursor(self.rename_text.items.len, false);
            self.rename_focus = false;
        }
        app.noteTyping(entry.data().id);
        const field = entry.data().borderRectScale().r;
        const caret = entry.textLayout.screenRectScale(entry.textLayout.cursor_rect).r;
        const enter = entry.enter_pressed;
        entry.deinit();

        // dvui's own caret sits past the field's right edge once the name is
        // wider than the row, so this one is clamped into the field and blinks.
        // The row paints its background after its children, so the caret is
        // only kept here and drawn by the row once that background is down.
        self.rename_caret = .{
            .x = @min(caret.x, field.x + field.w - 5),
            .y = caret.y,
            .w = 2,
            .h = caret.h,
        };

        if (enter) self.commitRename(app);
    }

    fn playlistStats(app: *App) void {
        var seconds: u64 = 0;
        var bpm_sum: f64 = 0;
        var bpm_count: usize = 0;
        for (0..app.crate.len()) |index| {
            const track = app.crate.at(index) orelse continue;
            seconds += track.length_s;
            if (track.bpm > 0) {
                bpm_sum += track.bpm;
                bpm_count += 1;
            }
        }
        const average = if (bpm_count > 0) bpm_sum / @as(f64, @floatFromInt(bpm_count)) else 0;
        const hours = seconds / 3600;
        const minutes = (seconds % 3600) / 60;

        var line: [96]u8 = undefined;
        const extent = if (hours > 0)
            std.fmt.bufPrint(&line, "{d} tracks · {d}h {d:0>2}m", .{ app.crate.len(), hours, minutes }) catch ""
        else
            std.fmt.bufPrint(&line, "{d} tracks · {d}m", .{ app.crate.len(), minutes }) catch "";
        labelStyled(@src(), extent, .{
            .color_text = .{ .color = Palette.secondary },
            .font = metaFont(),
            .margin = .{ .x = 4, .y = 3 },
            .id_extra = 7250,
        });

        var bpm_line: [48]u8 = undefined;
        const bpm_text = std.fmt.bufPrint(&bpm_line, "avg {d:.1} bpm", .{average}) catch "";
        labelStyled(@src(), bpm_text, .{
            .color_text = .{ .color = Palette.muted },
            .font = metaFont(),
            .margin = .{ .x = 4, .y = 1 },
            .id_extra = 7251,
        });
    }

    fn playlistChildren(self: *Panel, app: *App, parent: []const u8, depth: usize) void {
        for (self.rows, 0..) |playlist, index| {
            if (!std.mem.eql(u8, playlist.parent, parent)) continue;
            if (playlist.kind == .smart) continue;
            self.playlistRow(app, playlist, index, depth);
            if (self.rename_caret) |caret| {
                const phase = @mod(secondsNow(), 1.06);
                if (phase < 0.53) {
                    fillRect(app.allocator, caret.x, caret.y, caret.w, caret.h, Palette.ink);
                }
                self.rename_caret = null;
            }
            if (playlist.kind == .folder and self.folderOpen(playlist.id)) {
                self.playlistChildren(app, playlist.id, depth + 1);
            }
        }
    }

    pub fn frame(self: *Panel, app: *App) void {
        var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
            .min_size_content = .{ .w = 204 },
            .max_size_content = .{ .w = 204, .h = 100000 },
            .expand = .vertical,
            .background = true,
            .color_fill = .{ .color = Palette.panel },
            .padding = .{ .x = 8, .y = 8 },
        });
        defer panel.deinit();

        playlistStats(app);

        {
            var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer head.deinit();
            labelStyled(@src(), "playlists", .{
                .color_text = .{ .color = Palette.purple },
                .font = headingFont(),
                .margin = .{ .x = 2, .y = 2 },
                .id_extra = 7200,
            });

            // The title must not expand, or it pushes the chip out of the
            // column entirely.
            var gap = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            gap.deinit();

            const armed = self.delete_playlist != null;
            const shown = self.saveFlash();
            var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .min_size_content = .{ .w = 60, .h = 20 },
                .margin = .{ .y = 2 },
                .background = true,
                .color_fill = .{ .color = Palette.field },
                .id_extra = 7201,
            });
            defer chip.deinit();
            labelStyled(@src(), if (armed) "Delete ?" else switch (shown) {
                .none => "Save",
                .saved => "saved",
                .failed => "failed",
                .stale => "stale",
                .running => "rb open",
            }, .{
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .color_text = .{ .color = if (armed) Palette.red else switch (shown) {
                    .none => Palette.muted,
                    .saved => Palette.green,
                    .failed, .stale, .running => Palette.red,
                } },
                .font = metaFont(),
                .id_extra = 7202,
            });
            app.hit_map.append(rectFrom(chip.data().contentRectScale().r), .save_playlist);
            // The flash reverts on the clock, so it needs its own frames.
            if (shown != .none) dvui.refresh(null, @src(), null);
        }

        if (self.naming_save) self.saveNameField(app);

        self.playlistChildren(app, "root", 0);
    }

};

test "a typed name always creates and is refused when taken" {
    const names = [_]pl.library.Playlist{
        .{ .id = "1", .name = "Daily Note", .parent = "", .kind = .list },
    };
    try std.testing.expect(Panel.saveTarget("1", "Daily Note", "Crate", &names) == .refused);
    try std.testing.expectEqualStrings("Fresh", Panel.saveTarget("1", "Fresh", "Crate", &names).create);
    try std.testing.expectEqualStrings("1", Panel.saveTarget("1", null, "Crate", &names).replace);
    try std.testing.expectEqualStrings("Crate", Panel.saveTarget(null, null, "Crate", &names).create);
}

test "a folder is only deletable once its children are gone" {
    const playlists = [_]pl.library.Playlist{
        .{ .id = "root", .name = "root", .parent = "", .kind = .folder },
        .{ .id = "1", .name = "Sets", .parent = "root", .kind = .folder },
        .{ .id = "2", .name = "Warmup", .parent = "1", .kind = .list },
        .{ .id = "3", .name = "Empty", .parent = "root", .kind = .folder },
    };
    try std.testing.expect(!Panel.deletable(&playlists, 1));
    try std.testing.expect(Panel.deletable(&playlists, 2));
    try std.testing.expect(Panel.deletable(&playlists, 3));
    try std.testing.expect(!Panel.deletable(&playlists, 9));
}

test "undoing a crate edit restores the playlist it was open on" {
    const allocator = std.testing.allocator;
    var panel = Panel{};
    defer panel.deinit(allocator);

    try panel.bind(allocator, "a", &.{ 1, 2 });
    try panel.bind(allocator, "b", &.{3});
    try panel.rebind(allocator, "a", &.{ 1, 2 });
    try std.testing.expectEqualStrings("a", Panel.saveTarget(panel.open_playlist, null, "Crate", &.{}).replace);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, panel.open_ids);

    // The same playlist keeps the newer membership it has now.
    panel.rebaseline(allocator, &.{ 1, 2, 9 });
    try panel.rebind(allocator, "a", &.{ 1, 2 });
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 9 }, panel.open_ids);

    try panel.rebind(allocator, null, &.{});
    try std.testing.expect(panel.open_playlist == null);
}

test "a playlist with a member the library lacks is not staged" {
    const all = [_]pl.track.Track{.{ .id = 1, .title = "one", .artist = "a" }};
    const staged = try Panel.stageTracks(std.testing.allocator, &all, &.{1});
    std.testing.allocator.free(staged);
    try std.testing.expectError(error.TrackMissing, Panel.stageTracks(std.testing.allocator, &all, &.{ 1, 2 }));
}

test "write errors map to their own chip" {
    try std.testing.expectEqual(Outcome.stale, Panel.outcomeOf(error.StalePlaylist));
    try std.testing.expectEqual(Outcome.running, Panel.outcomeOf(error.RekordboxRunning));
    try std.testing.expectEqual(Outcome.failed, Panel.outcomeOf(error.OutOfMemory));
}
