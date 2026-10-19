//! The block canvas, the suggestion column, and the bottom bar.
//!
//! Layout follows one scale, so the eye reads the same rhythm everywhere:
//!   space  4 8 12 16 24
//!   type   meta 11 · body 13 · title 15
//! Colour is Dracula, one flat window surface, and the intensity ramp from
//! green (holds) through yellow and orange to red (clash).

const std = @import("std");
const dvui = @import("dvui");
const pl = @import("playlister");
const hit = @import("hit.zig");
const wave_colour = @import("wave_colour.zig");

const Track = pl.track.Track;
const Transition = pl.crate.Transition;
const Candidate = pl.suggest.Candidate;

const Lane = struct {
    track_id: u64 = 0,
    analysis: ?pl.analysis.Analysis = null,
    /// Set when the source has no analysis for this track.
    missing: bool = false,
};

fn mixerOutputPlay(context: *anyopaque, lanes: []const pl.mixer.Lane) void {
    const mixer: *pl.mixer.Mixer = @ptrCast(@alignCast(context));
    mixer.play(lanes);
}

fn mixerOutputStop(context: *anyopaque) void {
    const mixer: *pl.mixer.Mixer = @ptrCast(@alignCast(context));
    mixer.stop();
}

fn mixerLaneState(context: *anyopaque, uid: u64) pl.mixer.LaneState {
    const mixer: *pl.mixer.Mixer = @ptrCast(@alignCast(context));
    return mixer.laneState(uid);
}

fn mixerClockNs(context: *anyopaque) i128 {
    const mixer: *const pl.mixer.Mixer = @ptrCast(@alignCast(context));
    return mixer.nowNs();
}

fn mixerSpectrum(context: *anyopaque, uid: u64, out: []f32) void {
    const mixer: *pl.mixer.Mixer = @ptrCast(@alignCast(context));
    mixer.spectrum(uid, out);
}

fn mixerLevel(context: *anyopaque, uid: u64) f32 {
    const mixer: *pl.mixer.Mixer = @ptrCast(@alignCast(context));
    return mixer.level(uid);
}

fn byBpmDesc(_: void, a: Candidate, b: Candidate) bool {
    if (a.track.bpm_centi != b.track.bpm_centi) return a.track.bpm_centi > b.track.bpm_centi;
    return a.rank < b.rank;
}

fn shortName(name: []const u8, buffer: *[32]u8) []const u8 {
    const limit: usize = 24;
    if (name.len <= limit) return name;
    var cut: usize = limit;
    while (cut > 0 and (name[cut] & 0xC0) == 0x80) cut -= 1;
    @memcpy(buffer[0..cut], name[0..cut]);
    @memcpy(buffer[cut..][0..3], "…");
    return buffer[0 .. cut + 3];
}

fn presetName(preset: pl.mixer.EqPreset) []const u8 {
    return switch (preset) {
        .lpf => "LPF",
        .hpf => "HPF",
        .bpf => "BPF",
        .none => "",
    };
}


pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    library: pl.library.Library,
    player: pl.player.Player,
    mixer: *pl.mixer.Mixer,
    transport: pl.transport.Transport,
    crate: pl.crate.Crate,

    /// Playlists and folders from the source. Strings live in the source.
    playlists: []const pl.library.Playlist = &.{},
    /// Folders whose children are shown; ids are borrowed from `playlists`.
    open_folders: [64][]const u8 = undefined,
    open_count: usize = 0,
    /// Owning copies: the source may rebuild its playlist list after a write.
    /// The playlist currently open in the crate, for the row highlight.
    selected_playlist: ?[]const u8 = null,
    /// Lanes inside the canvas viewport this frame; global transport uses them
    /// once more than four tracks are loaded.
    lane_rects: [64]hit.Rect = undefined,
    lane_drawn: [64]bool = @splat(false),
    lane_count: usize = 0,
    /// Full row rectangles from the last frame, unclipped, for drop gaps.
    block_rects: [256]hit.Rect = undefined,
    block_count: usize = 0,
    lane_right: f32 = 0,
    /// First lane of the four-lane group global play/stop acts on.
    group_start: usize = 0,
    /// A preview waiting for the next master bar so it lands in sync.
    preview_pending: ?Track = null,
    preview_at_ns: i128 = 0,
    group: [4]usize = undefined,

    query: std.ArrayList(u8) = .empty,
    found: []const Track = &.{},
    ranked: []Candidate = &.{},

    /// Energy filters: the list shows exactly the directions enabled here.
    filter_up: bool = true,
    filter_down: bool = true,
    filter_hold: bool = true,
    /// Key display: wheel numbers by default, note names on request.
    note_names: bool = false,
    /// Beats shown across a preview lane: 16, 32 or 64.
    beats_visible: u8 = 16,
    /// Candidates the tempo window admits, so the field shows its effect even
    /// when the top of the list looks the same.
    in_range: usize = 0,
    /// Blocks picked for the previewer, by crate index. Empty means none.
    selected: std.ArrayListUnmanaged(usize) = .empty,
    /// One grid lane per block, in crate order.
    grid: std.ArrayListUnmanaged(Lane) = .empty,
    /// A crate edit happened this frame, including moves that keep the same
    /// track sequence, so the grid must be rebuilt anyway.
    grid_dirty: bool = false,

    /// Master tempo: follows the seed while locked, manual otherwise.
    master_bpm: f32 = 128,
    master_text: std.ArrayList(u8) = .empty,
    master_locked: bool = true,
    /// The master field had keyboard focus last frame, to detect leaving it.
    master_focus: bool = false,

    /// Where the last press landed, for controls that act on absolute position.
    last_point: hit.Point = .{},

    /// Tempo window for suggestions, as a percentage of the seed's BPM.
    bpm_pct: f32 = 5,
    bpm_text: std.ArrayList(u8) = .empty,
    /// Suggestions ordered by BPM, highest first.
    sort_by_bpm: bool = false,

    /// What the pointer is over, and what it is carrying. Filled while drawing,
    /// read on the next frame's pointer pass.
    hit_map: hit.HitMap,
    drag: hit.Drag = .{},
    pointer: hit.Point = .{},
    /// Visible area of the canvas: a track only lands when released over it.
    canvas: hit.Rect = .{},

    /// Visible area of the suggestion list, so a row scrolled out of sight
    /// keeps its presses inside it.
    list: hit.Rect = .{},

    /// Set on press, applied once the frame has finished drawing.
    pending_select: ?usize = null,
    /// True once a font with arrows is loaded, so the list can show ↑ and ↓.
    arrow_font: bool = false,
    /// Height of the window's content, so the list can fill what is left.
    viewport_h: f32 = 600,
    scale_hint: f32 = 1,

    /// Every visible row is a real widget, so the list is capped.
    const visible_rows = 60;
    const lane_panel_width: f32 = 380;
    /// Toolbar plus footer, measured once and fixed: reading them back made a
    /// resize lag a frame and flicker.
    const chrome_height: f32 = 104;

    pub fn init(allocator: std.mem.Allocator, library: pl.library.Library, io: std.Io) !App {
        const mixer = try allocator.create(pl.mixer.Mixer);
        mixer.* = pl.mixer.Mixer.init(allocator, io);
        var app: App = .{
            .allocator = allocator,
            .io = io,
            .library = library,
            .player = pl.player.Player.init(io, allocator),
            .mixer = mixer,
            .transport = pl.transport.Transport.init(
                allocator,
                .{
                    .context = mixer,
                    .play = mixerOutputPlay,
                    .stop = mixerOutputStop,
                    .laneState = mixerLaneState,
                    .spectrum = mixerSpectrum,
                    .level = mixerLevel,
                },
                .{ .context = mixer, .nowNs = mixerClockNs },
            ),
            .crate = pl.crate.Crate.init(allocator),
            .hit_map = hit.HitMap.init(allocator),
        };
        app.playlists = library.playlists() catch &.{};
        return app;
    }

    pub fn deinit(self: *App) void {
        self.transport.deinit();
        self.mixer.deinit();
        self.allocator.destroy(self.mixer);
        for (self.grid.items) |*lane| {
            if (lane.analysis) |*a| a.deinit(self.allocator);
        }
        self.grid.deinit(self.allocator);
        self.selected.deinit(self.allocator);
        self.master_text.deinit(self.allocator);
        self.hit_map.deinit();
        self.player.deinit();
        self.allocator.free(self.ranked);
        self.query.deinit(self.allocator);
        self.bpm_text.deinit(self.allocator);
        if (self.selected_playlist) |id| {
            if (id.len > 0) self.allocator.free(id);
        }
        self.crate.deinit();
    }

    /// Re-run the search, then rank what could follow the selected track.
    pub fn refresh(self: *App) !void {
        self.found = self.library.search(self.query.items) catch &.{};

        self.allocator.free(self.ranked);
        self.ranked = &.{};

        const seed = self.crate.seedTrack() orelse return;
        const tolerance = seed.bpm * self.bpm_pct / 100;
        self.ranked = try pl.suggest.rank(self.allocator, seed.*, self.found, .{
            .tolerance_bpm = tolerance,
        });
        self.in_range = self.ranked.len;
        if (self.sort_by_bpm) std.mem.sort(Candidate, self.ranked, {}, byBpmDesc);
    }

    pub fn frame(self: *App) bool {
        var root = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = true,
            .color_fill = .{ .color = Palette.background },
        });
        defer root.deinit();

        const root_scale = root.data().contentRectScale();
        self.viewport_h = root_scale.r.h / root_scale.s;
        self.scale_hint = root_scale.s;

        self.player.poll();
        self.transport.setTempo(self.masterBpm());
        self.transport.sync();

        if (self.preview_pending) |track| {
            if (self.transport.nowNs() >= self.preview_at_ns) {
                self.preview_pending = null;
                const tempo: f32 = if (track.bpm > 0) self.masterBpm() / @as(f32, @floatCast(track.bpm)) else 1;
                self.player.play(track, tempo);
            }
        }

        // The pointer pass reads the map the previous frame drew, then the map
        // is rebuilt from this frame's layout.
        self.handlePointer();
        self.syncGrid();

        self.hit_map.reset();

        frameToolbar(self);
        self.frameBody();
        frameFooter(self);
        self.drawGhost();

        if (self.pending_select) |index| {
            self.pending_select = null;
            self.crate.setSeed(index);
            self.query.clearRetainingCapacity();
            self.refresh() catch {};
            dvui.refresh(null, @src(), null);
        }

        return true;
    }

    fn frameToolbar(self: *App) void {
        _ = self;
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 16, .y = 8 },
            .background = true,
            .color_fill = .{ .color = Palette.background },
        });
        defer bar.deinit();

        labelStyled(@src(), "playlister", .{
            .font = titleFont(),
            .color_text = .{ .color = Palette.purple },
            .margin = .{ .x = 4 },
        });

        var spacer = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        spacer.deinit();
    }

    /// Orders the suggestions by BPM. Dim and inert until there are any.
    fn sortButton(self: *App) void {
        const enabled = self.ranked.len > 0;
        const active = enabled and self.sort_by_bpm;
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .min_size_content = .{ .w = 64, .h = 26 },
            .margin = .{ .x = 6, .y = 2 },
            .padding = .{ .x = 6, .y = 2 },
            .background = true,
            .color_fill = .{ .color = if (active) Palette.green else Palette.field },
            .id_extra = 7110,
        });
        defer chip.deinit();

        labelStyled(@src(), "bpm ↓", .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = .{ .color = if (active) Palette.background else if (enabled) Palette.secondary else Palette.muted },
            .font = metaFont(),
            .id_extra = 7111,
        });
        if (enabled) self.hit_map.append(rectFrom(chip.data().contentRectScale().r), .sort_bpm);
    }

    /// Three fixed spans. The active one is filled, so the current width reads
    /// at a glance.
    fn frameWidthSelector(self: *App) void {
        var group = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .margin = .{ .x = 12, .y = 4 },
            .padding = .{ .x = 2, .y = 2 },
            .background = true,
            .color_fill = .{ .color = Palette.field },
            .id_extra = 95,
        });
        defer group.deinit();

        for (hit.widths, 0..) |beats, slot| {
            const active = self.beats_visible == beats;
            var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .min_size_content = .{ .w = 30, .h = 20 },
                .margin = .{ .x = 2, .y = 1 },
                .padding = .{ .x = 6, .y = 1 },
                .background = true,
                .color_fill = .{ .color = if (active) Palette.green else Palette.field },
                .id_extra = 96 + slot,
            });
            defer cell.deinit();

            var buffer: [4]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "{d}", .{beats}) catch "";
            labelStyled(@src(), text, .{
                .color_text = .{ .color = if (active) Palette.background else Palette.secondary },
                .font = metaFont(),
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .id_extra = 100 + slot,
            });
            self.hit_map.append(rectFrom(cell.data().contentRectScale().r), .{ .width = beats });
        }
    }

    fn folderOpen(self: *const App, id: []const u8) bool {
        for (self.open_folders[0..self.open_count]) |open| {
            if (std.mem.eql(u8, open, id)) return true;
        }
        return false;
    }

    fn toggleFolder(self: *App, id: []const u8) void {
        if (self.folderOpen(id)) {
            var index: usize = 0;
            while (index < self.open_count) : (index += 1) {
                if (!std.mem.eql(u8, self.open_folders[index], id)) continue;
                self.open_folders[index] = self.open_folders[self.open_count - 1];
                self.open_count -= 1;
                break;
            }
        } else if (self.open_count < self.open_folders.len) {
            self.open_folders[self.open_count] = id;
            self.open_count += 1;
        }
        dvui.refresh(null, @src(), null);
    }

    /// Opens a playlist in the crate, in playlist order, ready to edit.
    fn selectPlaylist(self: *App, index: usize) void {
        const playlist = self.playlists[index];
        if (playlist.kind == .folder) {
            self.toggleFolder(playlist.id);
            return;
        }
        if (playlist.kind == .smart) return;

        const ids = self.library.playlistTracks(self.allocator, playlist.id) catch return;
        defer if (ids.len > 0) self.allocator.free(ids);

        self.player.stopAll();
        self.preview_pending = null;
        self.transport.stopAll();
        self.transport.beginSync();
        self.transport.endSync();
        self.crate.clear();
        self.selected.clearRetainingCapacity();
        self.query.clearRetainingCapacity();

        const all = self.library.all() catch &.{};
        for (ids) |id| {
            for (all) |track| {
                if (track.id != id) continue;
                _ = self.crate.append(track) catch break;
                break;
            }
        }

        self.grid_dirty = true;
        self.group_start = 0;
        if (self.selected_playlist) |old| {
            if (old.len > 0) self.allocator.free(old);
        }
        self.selected_playlist = self.allocator.dupe(u8, playlist.id) catch null;
        self.refresh() catch {};
        dvui.refresh(null, @src(), null);
    }

    fn saveCratePlaylist(self: *App) void {
        var ids: [256]u64 = undefined;
        const count = @min(self.crate.len(), ids.len);
        for (0..count) |index| {
            const track = self.crate.at(index) orelse continue;
            ids[index] = track.id;
        }
        if (count == 0) return;

        var name_buffer: [128]u8 = undefined;
        const name = if (self.crate.seedTrack()) |seed|
            std.fmt.bufPrint(&name_buffer, "Crate · {s}", .{seed.title}) catch "Crate"
        else
            "Crate";
        self.library.createPlaylist(name, ids[0..count]) catch return;
        self.playlists = self.library.playlists() catch &.{};
        dvui.refresh(null, @src(), null);
    }

    fn playlistRow(self: *App, playlist: pl.library.Playlist, index: usize, depth: usize) void {
        const selected = if (self.selected_playlist) |id| std.mem.eql(u8, id, playlist.id) else false;
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

        const target: hit.Target = if (playlist.kind == .folder)
            .{ .playlist_toggle = index }
        else
            .{ .playlist = index };
        self.hit_map.append(rectFrom(row.data().contentRectScale().r), target);
    }

    fn playlistStats(self: *App) void {
        var seconds: u64 = 0;
        var bpm_sum: f64 = 0;
        var bpm_count: usize = 0;
        for (0..self.crate.len()) |index| {
            const track = self.crate.at(index) orelse continue;
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
            std.fmt.bufPrint(&line, "{d} tracks · {d}h {d:0>2}m", .{ self.crate.len(), hours, minutes }) catch ""
        else
            std.fmt.bufPrint(&line, "{d} tracks · {d}m", .{ self.crate.len(), minutes }) catch "";
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

    fn playlistChildren(self: *App, parent: []const u8, depth: usize) void {
        for (self.playlists, 0..) |playlist, index| {
            if (!std.mem.eql(u8, playlist.parent, parent)) continue;
            if (playlist.kind == .smart) continue;
            self.playlistRow(playlist, index, depth);
            if (playlist.kind == .folder and self.folderOpen(playlist.id)) {
                self.playlistChildren(playlist.id, depth + 1);
            }
        }
    }

    fn framePlaylists(self: *App) void {
        var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
            .min_size_content = .{ .w = 210 },
            .max_size_content = .{ .w = 210, .h = 100000 },
            .expand = .vertical,
            .background = true,
            .color_fill = .{ .color = Palette.panel },
            .padding = .{ .x = 8, .y = 8 },
        });
        defer panel.deinit();

        self.playlistStats();

        {
            var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer head.deinit();
            labelStyled(@src(), "playlists", .{
                .expand = .horizontal,
                .color_text = .{ .color = Palette.purple },
                .font = headingFont(),
                .margin = .{ .x = 4, .y = 2 },
                .id_extra = 7200,
            });

            var save = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .min_size_content = .{ .w = 74, .h = 20 },
                .margin = .{ .x = 2, .y = 2 },
                .background = true,
                .color_fill = .{ .color = Palette.field },
                .id_extra = 7201,
            });
            defer save.deinit();
            labelStyled(@src(), "save crate", .{
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .color_text = .{ .color = Palette.muted },
                .font = metaFont(),
                .id_extra = 7202,
            });
            self.hit_map.append(rectFrom(save.data().contentRectScale().r), .save_playlist);
        }

        self.playlistChildren("root", 0);
    }

    fn frameBody(self: *App) void {
        // A minimum of zero lets the body shrink to the window; measuring the
        // strips instead made every resize lag a frame.
        var body = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .min_size_content = .{ .h = 0 },
            .max_size_content = .{ .w = 100000, .h = @max(120, self.viewport_h - chrome_height) },
        });
        defer body.deinit();

        self.framePicker();
        self.frameCanvas();
        self.framePlaylists();
    }

    fn framePicker(self: *App) void {
        var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
            .min_size_content = .{ .w = 420 },
            .max_size_content = .{ .w = 420, .h = 100000 },
            .expand = .vertical,
            .background = true,
            .color_fill = .{ .color = Palette.panel },
            .padding = .{ .x = 0, .y = 0 },
        });
        defer panel.deinit();

        self.frameSearch();
        self.framePickerHeading();

        const list_height = @max(120, self.viewport_h - 165);
        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 420, .h = 120 },
            .max_size_content = .{ .w = 420, .h = list_height },
            .background = false,
        });
        defer scroll.deinit();
        self.list = rectFrom(scroll.data().borderRectScale().r);

        var list = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .max_size_content = .{ .w = 420, .h = 100000 },
        });
        defer list.deinit();

        switch (self.mode()) {
            .search, .browse => {
                const rows = self.found[0..@min(self.found.len, visible_rows)];
                for (rows, 0..) |track, row_index| {
                    pickRow(self, row_index, track, null);
                }
            },
            .suggest => {
                const rows = self.ranked[0..@min(self.ranked.len, visible_rows)];
                // Slots follow the drawn rows, not the candidate list: a
                // filtered candidate must leave no slot behind.
                var slot: usize = 0;
                for (rows) |candidate| {
                    if (!passesFilter(self, candidate.transition)) continue;
                    pickRow(self, slot, candidate.track, candidate.transition);
                    slot += 1;
                }
            },
        }
    }

    const Mode = enum { browse, search, suggest };

    fn mode(self: *App) Mode {
        if (self.query.items.len > 0) return .search;
        if (self.crate.seedTrack() != null) return .suggest;
        return .browse;
    }

    fn framePickerHeading(self: *App) void {
        const heading = self.crate.seedTrack();
        var text_buffer: [128]u8 = undefined;
        var text: []const u8 = "";
        if (self.mode() != .suggest or heading == null) {
            text = switch (self.mode()) {
                .search => "Search results",
                .browse => "Pick a seed",
                .suggest => "",
            };
        } else {
            var title_buffer: [34]u8 = undefined;
            text = std.fmt.bufPrint(&text_buffer, "Next to {s}", .{clippedTitle(heading.?.title, &title_buffer)}) catch "Next to";
        }

        labelStyled(@src(), text, headingOptions());
    }

    fn headingOptions() dvui.Options {
        return .{
            .font = headingFont(),
            .color_text = .{ .color = Palette.ink },
            .margin = .{ .x = 12, .y = 8 },
        };
    }

    /// The field sits at the top of the column it filters, so its width is the
    /// column's width and nothing floats above it.
    fn frameSearch(self: *App) void {
        var entry = dvui.textEntry(@src(), .{
            .text = .{ .array_list = .{ .backing = &self.query, .allocator = self.allocator } },
            .placeholder = "search title, artist, genre or tag",
        }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 1, .h = 30 },
            .padding = .{ .x = 12, .y = 5 },
            .margin = .{ .y = 0 },
            .corners = square,
            .background = true,
            .color_fill = .{ .color = Palette.field },
            .color_text = .{ .color = Palette.ink },
            .font = bodyFont(),
        });
        const typed = entry.text_changed;
        entry.deinit();
        if (typed) self.refresh() catch {};
    }

    /// Tempo window in percent: the list keeps tracks within this much of the
    /// selected track's BPM.
    pub fn frameBpmWindow(self: *App) void {
        if (self.bpm_text.items.len == 0) {
            self.bpm_text.append(self.allocator, '5') catch {};
        }

        labelStyled(@src(), "bpm ±", .{
            .color_text = .{ .color = Palette.muted },
            .font = metaFont(),
            .margin = .{ .x = 4, .y = 6 },
            .id_extra = 7100,
        });

        var entry = dvui.textEntry(@src(), .{
            .text = .{ .array_list = .{ .backing = &self.bpm_text, .allocator = self.allocator } },
        }, .{
            .min_size_content = .{ .w = 46, .h = 26 },
            .padding = .{ .x = 6, .y = 2 },
            .margin = .{ .x = 2, .y = 2 },
            .corners = square,
            .background = true,
            .color_fill = .{ .color = Palette.field },
            .color_text = .{ .color = Palette.ink },
            .font = metaFont(),
            .id_extra = 7101,
        });
        const changed = entry.text_changed;
        entry.deinit();

        var count_buffer: [24]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buffer, "{d} in range", .{self.in_range}) catch "";
        labelStyled(@src(), count, .{
            .color_text = .{ .color = Palette.muted },
            .font = metaFont(),
            .margin = .{ .x = 6, .y = 6 },
            .id_extra = 7102,
        });

        if (!changed) return;
        const parsed = std.fmt.parseFloat(f32, std.mem.trim(u8, self.bpm_text.items, " ")) catch return;
        self.bpm_pct = std.math.clamp(parsed, 0.5, 50);
        self.refresh() catch {};
    }

    pub fn energyToggle(self: *App, glyph: []const u8, color: dvui.Color, value: *bool, toggle: hit.Toggle) void {
        const on = value.*;
        var widget: dvui.WidgetData = undefined;
        _ = dvui.button(@src(), glyph, .{}, .{
            .min_size_content = .{ .w = 36, .h = 26 },
            .margin = .{ .x = 6 },
            .padding = .{ .x = 6, .y = 1 },
            .data_out = &widget,
            .id_extra = @intFromEnum(toggle) + 1,
            .corners = square,
            .font = headingFont().withSize(18),
            .background = true,
            .color_fill = .{ .color = if (on) Palette.field else Palette.background },
            .color_text = .{ .color = if (on) color else Palette.muted },
        });

        self.hit_map.append(rectFrom(widget.rectScaleFromParent().r), .{ .toggle = toggle });
    }

    /// The key chip doubles as the notation switch, so the current spelling is
    /// always visible.
    fn notationToggle(self: *App) void {
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .margin = .{ .x = 12, .y = 4 },
            .padding = .{ .x = 8, .y = 2 },
            .background = true,
            .color_fill = .{ .color = Palette.field },
            .id_extra = 90,
        });
        defer chip.deinit();

        var buffer: [16]u8 = undefined;
        const sample = if (self.note_names) "Am" else "8A";
        const text = std.fmt.bufPrint(&buffer, "key {s}", .{sample}) catch "key";

        labelStyled(@src(), text, .{
            .color_text = .{ .color = Palette.secondary },
            .font = metaFont(),
            .id_extra = 91,
        });

        self.hit_map.append(rectFrom(chip.data().rectScaleFromParent().r), .notation);
    }

    fn frameCanvas(self: *App) void {
        // Without an explicit fill the theme paints its own content surface,
        // which reads as a box stretching to the window edge.
        var canvas = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .padding = .{ .x = 24, .y = 24 },
            .background = true,
            .color_fill = .{ .color = Palette.background },
            .min_size_content = .{ .h = 0 },
        });
        defer canvas.deinit();
        self.canvas = rectFrom(canvas.data().borderRectScale().r);

        self.lane_count = 0;
        self.lane_right = 0;
        self.lane_drawn = @splat(false);
        self.block_count = 0;

        if (self.crate.len() == 0) {
            labelStyled(@src(), "Drag a track here to start the crate.", .{
                .color_text = .{ .color = Palette.muted },
                .margin = .{ .x = 4, .y = 4 },
            });
            return;
        }

        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .both,
            .min_size_content = .{ .h = 0 },
            .background = false,
        });
        defer scroll.deinit();

        var stack = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .y = 4 },
        });
        defer stack.deinit();

        var next_action: Action = .none;

        for (0..self.crate.len()) |index| {
            const track = self.crate.at(index).?;
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .id_extra = 8000 + index,
                });
                defer row.deinit();

                const block = drawBlock(self, index, track.*);
                switch (block.action) {
                    .remove => next_action = .{ .remove = index },
                    .none => {},
                }
                self.dropLine(index, block.rect);
                // Only the rows near the viewport are painted; a crate of
                // dozens of tracks otherwise redraws every waveform per frame.
                const margin: f32 = 320;
                const near = block.rect.y + block.rect.h >= self.canvas.y - margin and
                    block.rect.y <= self.canvas.bottom() + margin;
                if (near) self.drawLane(index);
            }

            if (self.crate.transition(index)) |step| connector(self.allocator, index, step);
        }

        self.drawGroupBrace();

        // Scroll room past the last block: dropping at the end should not need
        // the pointer on the very last block.
        var tail = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .min_size_content = .{ .h = 420 },
        });
        tail.deinit();

        switch (next_action) {
            .remove => |index| {
                if (self.crate.at(index)) |track| self.player.stopPreview(track.id);
                self.crate.remove(index) catch return;
                self.transport.remove(index);
                self.grid_dirty = true;
                self.selected.clearRetainingCapacity();
                self.refresh() catch {};
                dvui.refresh(null, @src(), null);
            },
            .none => {},
        }

    }

    /// One pass over the frame's events, before any widget can take them.
    fn handlePointer(self: *App) void {
        for (dvui.events()) |*event| {
            if (event.evt != .mouse) continue;
            const mouse = event.evt.mouse;
            const p = pointFrom(mouse.p);

            switch (mouse.action) {
                .press => {
                    if (!mouse.button.pointer()) continue;
                    const target = self.hit_map.hit(p) orelse continue;
                    self.last_point = p;
                    self.apply(self.drag.press(target, p, mouse.mod.shift()));
                    switch (target) {
                        .lane => |index| {
                            if (self.transport.isPlaying(index)) self.transport.jogPause(index, .now);
                        },
                        else => {},
                    }
                },
                .motion => {
                    if (self.drag.motion(p, 6 * self.scale_hint, self.canvas, self.block_rects[0..self.block_count])) {
                        dvui.refresh(null, @src(), null);
                    }
                    if (self.drag.pull(p)) |pull| self.applyPull(pull);
                },
                .release => {
                    if (!mouse.button.pointer()) continue;
                    self.apply(self.drag.release());
                    self.transport.jogResume();
                },
                else => {},
            }
        }
    }

    /// The crate edits an interaction asks for. Kept here so the pointer rules
    /// stay free of the crate.
    fn apply(self: *App, action: hit.Drag.Action) void {
        switch (action) {
            .none => {},
            .toggle => |toggle| {
                const value = switch (toggle) {
                    .hold => &self.filter_hold,
                    .up => &self.filter_up,
                    .down => &self.filter_down,
                };
                value.* = !value.*;
                self.refresh() catch {};
                dvui.refresh(null, @src(), null);
            },
            .toggle_notation => {
                self.note_names = !self.note_names;
                dvui.refresh(null, @src(), null);
            },
            .grab_eq => {},
            .set_eq_preset => |at| {
                if (at.lane >= self.grid.items.len) return;
                const next: pl.mixer.EqPreset = if (self.transport.eqPreset(at.lane) == at.preset) .none else at.preset;
                self.transport.setEqPreset(at.lane, next);
                dvui.refresh(null, @src(), null);
            },
            .set_trim => |lane| {
                if (lane >= self.grid.items.len) return;
                const db = self.hit_map.trimValueAt(lane, self.last_point.y) orelse return;
                self.transport.setTrim(lane, db);
                dvui.refresh(null, @src(), null);
            },
            .seek_nav => |index| {
                if (index >= self.grid.items.len) return;
                const total: f32 = @floatFromInt(totalBeats(&self.grid.items[index]));
                const beat = self.hit_map.navBeatAt(index, self.last_point.x, total) orelse return;
                self.transport.seek(index, beat);
                dvui.refresh(null, @src(), null);
            },
            .set_width => |beats| {
                if (!hit.isWidth(beats)) return;
                self.beats_visible = beats;
                dvui.refresh(null, @src(), null);
            },
            .toggle_master_lock => {
                self.master_locked = !self.master_locked;
                if (!self.master_locked) self.master_bpm = self.masterBpm();
                self.transport.setTempo(self.masterBpm());
                dvui.refresh(null, @src(), null);
            },
            .toggle_pitch => {
                self.transport.setKeylock(!self.transport.keylocked());
                dvui.refresh(null, @src(), null);
            },
            .toggle_transport => {
                // Stop is global; play starts only the braced four lanes.
                if (self.transport.anyPlaying()) {
                    self.transport.stopAll();
                } else {
                    self.transport.startGroup(self.transportGroup());
                }
                dvui.refresh(null, @src(), null);
            },
            .clear_all => self.clearAll(),
            .toggle_sort_bpm => {
                self.sort_by_bpm = !self.sort_by_bpm;
                self.refresh() catch {};
                dvui.refresh(null, @src(), null);
            },
            .select_playlist => |index| {
                if (index >= self.playlists.len) return;
                self.selectPlaylist(index);
            },
            .toggle_playlist => |index| {
                if (index >= self.playlists.len) return;
                self.toggleFolder(self.playlists[index].id);
            },
            .save_playlist => self.saveCratePlaylist(),
            .toggle_lane_play => |index| {
                if (index >= self.grid.items.len) return;
                if (self.transport.isPlaying(index)) {
                    self.transport.stop(index);
                } else {
                    self.transport.start(index, .next_bar);
                }
                dvui.refresh(null, @src(), null);
            },
            .toggle_lane_mute => |index| {
                if (index >= self.grid.items.len) return;
                self.transport.setMute(index, !self.transport.muted(index));
                dvui.refresh(null, @src(), null);
            },
            .select_block => |index| self.pending_select = index,
            .toggle_block => |index| {
                self.toggleSelected(index);
                dvui.refresh(null, @src(), null);
            },
            .drop_track => |drop| {
                _ = self.crate.insertAt(drop.gap, drop.track) catch return;
                self.transport.insert(drop.gap);
                self.grid_dirty = true;
                self.selected.clearRetainingCapacity();
                self.refresh() catch {};
                dvui.refresh(null, @src(), null);
            },
            .move_block => |move| {
                if (self.crate.at(move.from)) |track| self.player.stopPreview(track.id);
                self.crate.moveTo(move.from, move.gap) catch return;
                self.transport.move(move.from, move.gap);
                self.grid_dirty = true;
                self.selected.clearRetainingCapacity();
                self.refresh() catch {};
                dvui.refresh(null, @src(), null);
            },
        }
    }

    fn masterBpm(self: *const App) f32 {
        if (!self.master_locked) return self.master_bpm;
        if (self.crate.seed) |seed| {
            if (seed < self.grid.items.len) {
                if (self.grid.items[seed].analysis) |*analysis| {
                    if (analysis.bpm() > 0) return analysis.bpm();
                }
            }
        }
        if (self.crate.seedTrack()) |track| {
            if (track.bpm > 0) return @floatCast(track.bpm);
        }
        for (self.grid.items) |*lane| {
            if (lane.analysis) |*analysis| {
                if (analysis.bpm() > 0) return analysis.bpm();
            }
        }
        return 128;
    }

    /// Beat at the left edge of a lane's window. Negative at the start of a
    /// track, before the first bar.
    fn laneStart(self: *App, index: usize) f32 {
        return self.transport.beat(index) - self.visibleBeats() / 2;
    }

    fn visibleBeats(self: *const App) f32 {
        return @floatFromInt(self.beats_visible);
    }

    pub fn animating(self: *const App) bool {
        return self.transport.anyPlaying();
    }

    /// Loads a grid lane for every block. Lanes survive edits: a lane matched
    /// by track keeps its audio, position and analysis, and a new block starts
    /// paused.
    fn syncGrid(self: *App) void {
        if (!self.grid_dirty and self.grid.items.len == self.crate.len()) {
            var same = true;
            for (0..self.crate.len()) |index| {
                if (self.grid.items[index].track_id != self.crate.at(index).?.id) {
                    same = false;
                    break;
                }
            }
            if (same) return;
        }

        const consumed = self.allocator.alloc(bool, self.grid.items.len) catch return;
        defer self.allocator.free(consumed);
        @memset(consumed, false);

        var next: std.ArrayListUnmanaged(Lane) = .empty;
        for (0..self.crate.len()) |index| {
            const track = self.crate.at(index).?.*;
            var lane = Lane{ .track_id = track.id };
            var reused = false;

            for (self.grid.items, 0..) |old, old_index| {
                if (consumed[old_index] or old.track_id != track.id) continue;
                consumed[old_index] = true;
                lane = old;
                reused = true;
                break;
            }

            if (!reused) {
                lane.analysis = self.library.analysis(self.allocator, track.id) catch null;
                lane.missing = lane.analysis == null;
            }

            next.append(self.allocator, lane) catch {};
        }

        self.transport.beginSync();
        for (next.items, 0..) |*lane, index| self.resolveLane(index, lane);
        self.transport.endSync();

        for (self.grid.items, 0..) |*old, old_index| {
            if (consumed[old_index]) continue;
            if (old.analysis) |*a| a.deinit(self.allocator);
        }

        self.grid.deinit(self.allocator);
        self.grid = next;
        self.grid_dirty = false;
    }

    fn resolveLane(self: *App, index: usize, lane: *Lane) void {
        const track = self.crate.at(index) orelse return;
        const analysis: ?*const pl.analysis.Analysis = if (lane.analysis) |*a| a else null;
        const grid_bpm: f32 = if (analysis) |a| blk: {
            if (a.bpm() > 0) break :blk a.bpm();
            break :blk 128;
        } else if (track.bpm > 0) @floatCast(track.bpm) else 128;
        self.transport.resolve(index, .{
            .track = track.*,
            .analysis = analysis,
            .grid_bpm = grid_bpm,
            .total_beats = if (analysis) |a| @floatFromInt(a.beats.len) else 0,
            .offset = if (analysis) |a| a.downbeatOffset() else 0,
            .first_downbeat = if (analysis) |a| @floatFromInt(a.firstDownbeat()) else 0,
        });
    }

    /// Picks a block for the previewer; three lanes is the cap.
    fn toggleSelected(self: *App, index: usize) void {
        for (self.selected.items, 0..) |value, slot| {
            if (value == index) {
                _ = self.selected.orderedRemove(slot);
                return;
            }
        }
        if (self.selected.items.len >= 3) return;
        self.selected.append(self.allocator, index) catch {};
    }

    fn commitMaster(self: *App) void {
        const parsed = std.fmt.parseFloat(f32, self.master_text.items) catch null;
        if (parsed) |value| self.master_bpm = std.math.clamp(value, 40, 220);
        self.master_locked = false;
        self.transport.setTempo(self.masterBpm());
    }

    /// Master tempo at the right corner, with a lock that ties it to the seed.
    fn frameMaster(self: *App) void {
        labelStyled(@src(), "master", .{
            .color_text = .{ .color = Palette.muted },
            .font = metaFont(),
            .margin = .{ .x = 8, .y = 6 },
        });

        if (self.master_locked) {
            var buffer: [8]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "{d:.0}", .{self.masterBpm()}) catch "";
            if (!std.mem.eql(u8, self.master_text.items, text)) {
                self.master_text.clearRetainingCapacity();
                self.master_text.appendSlice(self.allocator, text) catch {};
            }
        }
        if (self.master_text.items.len == 0) {
            self.master_text.appendSlice(self.allocator, "128") catch {};
        }

        var entry = dvui.textEntry(@src(), .{ .text = .{ .array_list = .{
            .backing = &self.master_text,
            .allocator = self.allocator,
        } } }, .{
            .min_size_content = .{ .w = 46, .h = 26 },
            .padding = .{ .x = 6, .y = 2 },
            .margin = .{ .x = 2, .y = 2 },
            .background = true,
            .color_fill = .{ .color = Palette.field },
            .color_text = .{ .color = Palette.ink },
            .font = metaFont(),
            .id_extra = 70,
        });
        const enter = entry.enter_pressed;
        const focused = dvui.focusedWidgetId() == entry.data().id;
        entry.deinit();

        const left_box = self.master_focus and !focused;
        self.master_focus = focused;

        if (enter or left_box) self.commitMaster();

        {
            var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .margin = .{ .x = 3, .y = 4 },
                .padding = .{ .x = 5, .y = 2 },
                .background = true,
                .color_fill = .{ .color = Palette.field },
                .id_extra = 72,
            });
            defer chip.deinit();
            labelStyled(@src(), if (self.master_locked) "locked" else "free", .{
                .color_text = .{ .color = if (self.master_locked) Palette.green else Palette.secondary },
                .font = metaFont(),
                .id_extra = 73,
            });
            self.hit_map.append(rectFrom(chip.data().rectScaleFromParent().r), .master_lock);
        }

        {
            var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .margin = .{ .x = 4, .y = 4 },
                .padding = .{ .x = 8, .y = 2 },
                .background = true,
                .color_fill = .{ .color = Palette.field },
                .id_extra = 74,
            });
            defer chip.deinit();
            labelStyled(@src(), if (self.transport.keylocked()) "pitch" else "vinyl", .{
                .color_text = .{ .color = if (self.transport.keylocked()) Palette.green else Palette.secondary },
                .font = metaFont(),
                .id_extra = 75,
            });
            self.hit_map.append(rectFrom(chip.data().rectScaleFromParent().r), .pitch_lock);
        }
    }

    fn lanePlayButton(self: *App, index: usize) void {
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .min_size_content = .{ .w = 26, .h = 26 },
            .margin = .{ .x = 4 },
            .background = true,
            .color_fill = .{ .color = Palette.background },
            .id_extra = 7000 + index,
        });
        defer chip.deinit();

        const rect_scale = chip.data().contentRectScale();
        const rect = rect_scale.r;
        const scale = rect_scale.s;
        const center_x = rect.x + rect.w / 2;
        const center_y = rect.y + rect.h / 2;

        const playing = index < self.grid.items.len and self.transport.isPlaying(index);
        if (playing) {
            drawPauseBars(self.allocator, center_x, center_y, 5 * scale);
        } else {
            drawPlayTriangle(self.allocator, center_x, center_y, 6 * scale);
        }

        self.hit_map.append(rectFrom(rect), .{ .lane_play = index });
    }

    fn laneMuteButton(self: *App, index: usize) void {
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .min_size_content = .{ .w = 26, .h = 18 },
            .margin = .{ .x = 4 },
            .background = true,
            .color_fill = .{ .color = Palette.background },
            .id_extra = 7500 + index,
        });
        defer chip.deinit();

        const muted = self.transport.muted(index);
        labelStyled(@src(), "M", .{
            .color_text = .{ .color = if (muted) Palette.green else Palette.secondary },
            .font = metaFont(),
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .id_extra = 7600 + index,
        });

        self.hit_map.append(rectFrom(chip.data().contentRectScale().r), .{ .lane_mute = index });
    }

    fn transportToggle(self: *App) void {
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .margin = .{ .x = 8, .y = 4 },
            .padding = .{ .x = 10, .y = 2 },
            .background = true,
            .color_fill = .{ .color = Palette.field },
            .id_extra = 80,
        });
        defer chip.deinit();

        labelStyled(@src(), if (self.transport.anyPlaying()) "stop" else "play", .{
            .color_text = .{ .color = if (self.transport.anyPlaying()) Palette.green else Palette.secondary },
            .font = metaFont(),
            .id_extra = 81,
        });
        self.hit_map.append(rectFrom(chip.data().rectScaleFromParent().r), .transport);
    }

    /// Empties the crate and returns every control to its starting value.
    fn clearButton(self: *App) void {
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .margin = .{ .x = 18, .y = 4 },
            .padding = .{ .x = 10, .y = 2 },
            .background = true,
            .color_fill = .{ .color = Palette.field },
            .id_extra = 82,
        });
        defer chip.deinit();

        labelStyled(@src(), "clear", .{
            .color_text = .{ .color = Palette.muted },
            .font = metaFont(),
            .id_extra = 83,
        });
        self.hit_map.append(rectFrom(chip.data().rectScaleFromParent().r), .clear);
    }

    fn clearAll(self: *App) void {
        self.player.stopAll();
        self.preview_pending = null;
        self.transport.stopAll();
        self.transport.beginSync();
        self.transport.endSync();
        self.crate.clear();
        self.grid_dirty = true;
        if (self.selected_playlist) |id| {
            if (id.len > 0) self.allocator.free(id);
        }
        self.selected_playlist = null;
        self.group_start = 0;
        self.open_count = 0;
        self.selected.clearRetainingCapacity();
        self.query.clearRetainingCapacity();
        self.master_text.clearRetainingCapacity();
        self.master_bpm = 128;
        self.master_locked = true;
        self.bpm_pct = 5;
        self.refresh() catch {};
        dvui.refresh(null, @src(), null);
    }

    fn isSelected(self: *const App, index: usize) bool {
        for (self.selected.items) |value| {
            if (value == index) return true;
        }
        return false;
    }

    fn applyPull(self: *App, pull: hit.Drag.Pull) void {
        switch (pull.target) {
            .lane => |slot| {
                if (slot >= self.grid.items.len) return;
                const delta = self.hit_map.waveformDragBeats(slot, pull.dx, self.visibleBeats()) orelse return;
                if (self.transport.isPlaying(slot)) self.transport.jogPause(slot, .now);
                self.transport.dragBeats(slot, delta);
                dvui.refresh(null, @src(), null);
            },
            .nav => |slot| {
                if (slot >= self.grid.items.len) return;
                const total: f32 = @floatFromInt(totalBeats(&self.grid.items[slot]));
                const delta = self.hit_map.navDragBeats(slot, pull.dx, total) orelse return;
                if (self.transport.isPlaying(slot)) self.transport.jogPause(slot, .bar);
                self.transport.dragBar(slot, delta);
                dvui.refresh(null, @src(), null);
            },
            .group => {
                if (self.crate.len() <= 4 or self.lane_count == 0) return;
                for (0..self.lane_count) |index| {
                    const rect = self.lane_rects[index];
                    if (pull.p.y < rect.y or pull.p.y >= rect.y + rect.h) continue;
                    self.group_start = @min(index, self.crate.len() - 4);
                    dvui.refresh(null, @src(), null);
                    return;
                }
            },
            .eq_node => |at| {
                if (at.lane >= self.grid.items.len) return;
                const point = self.hit_map.eqPointAt(at.lane, pull.p) orelse return;
                self.transport.setEqNode(at.lane, at.band, point.gain_db, point.freq_hz);
                dvui.refresh(null, @src(), null);
            },
            .trim => |lane| {
                if (lane >= self.grid.items.len) return;
                const db = self.hit_map.trimValueAt(lane, pull.p.y) orelse return;
                self.transport.setTrim(lane, db);
                dvui.refresh(null, @src(), null);
            },
            else => {},
        }
    }

    /// The grid lane drawn beside a block, sharing the row's height.
    fn drawLane(self: *App, index: usize) void {
        if (index >= self.grid.items.len) return;
        const lane = &self.grid.items[index];

        var col = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .vertical,
            .min_size_content = .{ .w = 630, .h = 0 },
            .max_size_content = .{ .w = 630, .h = 100000 },
            .margin = .{ .x = 8, .y = 6 },
            .padding = .{ .x = 8, .y = 4 },
            .background = true,
            .color_fill = .{ .color = Palette.field },
            .id_extra = 9000 + index,
        });
        defer col.deinit();
        const col_rect = rectFrom(col.data().contentRectScale().r);

        {
            var wave_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .both,
                .id_extra = 9050 + index,
            });
            defer wave_row.deinit();

            if (index < self.crate.len()) {
                var buttons = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .min_size_content = .{ .w = 34, .h = 0 },
                    .id_extra = 9060 + index,
                });
                defer buttons.deinit();
                self.lanePlayButton(index);
                self.laneMuteButton(index);
            }

            {
                var wave_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .both,
                    .min_size_content = .{ .w = 0, .h = 0 },
                    .id_extra = 9100 + index,
                });
                defer wave_box.deinit();
                const full_rect = rectFrom(wave_box.data().contentRectScale().r).clipped(col_rect);
                // The expanding box can report the whole row before the fixed
                // EQ panel is placed; keep the drawing out from under it.
                const eq_reserved = (46 + 124 + 18 + 8) * self.scale_hint;
                const wave_rect = hit.Rect{
                    .x = full_rect.x,
                    .y = full_rect.y,
                    .w = @max(0, @min(full_rect.w, col_rect.x + col_rect.w - eq_reserved - full_rect.x)),
                    .h = full_rect.h,
                };

                const view = self.laneStart(index);
                if (lane.analysis) |*analysis| {
                    self.paintWave(analysis, wave_rect, view, analysis.downbeatOffset());
                } else {
                    labelStyled(@src(), "no analysis", .{
                        .color_text = .{ .color = Palette.muted },
                        .font = metaFont(),
                        .margin = .{ .x = 6, .y = 2 },
                        .id_extra = 9200 + index,
                    });
                }
                if (lane.analysis != null) {
                    fillRect(self.allocator, wave_rect.x + wave_rect.w / 2 - 1, wave_rect.y, 2.5, wave_rect.h, Palette.ink);
                }
                self.hit_map.append(wave_rect, .{ .lane = index });
            }

            {
                var presets = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .min_size_content = .{ .w = 46, .h = 0 },
                    .id_extra = 9400 + index,
                });
                defer presets.deinit();
                const order = [_]pl.mixer.EqPreset{ .hpf, .bpf, .lpf };
                for (order, 0..) |preset, choice| {
                    const active = self.transport.eqPreset(index) == preset;
                    var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .min_size_content = .{ .w = 40, .h = 20 },
                        .margin = .{ .x = 2, .y = 2 },
                        .background = true,
                        .color_fill = .{ .color = if (active) Palette.green else Palette.field },
                        .id_extra = 9410 + index * 4 + choice,
                    });
                    defer chip.deinit();
                    labelStyled(@src(), presetName(preset), .{
                        .color_text = .{ .color = if (active) Palette.background else Palette.secondary },
                        .font = metaFont(),
                        .gravity_x = 0.5,
                        .gravity_y = 0.5,
                        .id_extra = 9430 + index * 4 + choice,
                    });
                    self.hit_map.append(rectFrom(chip.data().contentRectScale().r), .{ .eq_preset = .{ .lane = index, .preset = preset } });
                }
            }

            {
                var plot = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .min_size_content = .{ .w = 124, .h = 0 },
                    .expand = .vertical,
                    .id_extra = 9500 + index,
                });
                defer plot.deinit();
                const plot_rect = rectFrom(plot.data().contentRectScale().r).clipped(col_rect);
                self.drawEqPlot(index, plot_rect);
            }

            {
                var trim = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .min_size_content = .{ .w = 18, .h = 0 },
                    .expand = .vertical,
                    .margin = .{ .x = 4, .y = 0 },
                    .id_extra = 9600 + index,
                });
                defer trim.deinit();
                const trim_rect = rectFrom(trim.data().contentRectScale().r).clipped(col_rect);
                self.drawTrim(index, trim_rect);
            }
        }

        {
            var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .min_size_content = .{ .w = 0, .h = 24 },
                .id_extra = 9300 + index,
            });
            defer bar.deinit();
            const bar_rect = rectFrom(bar.data().contentRectScale().r).clipped(col_rect);

            const total = totalBeats(lane);
            const visible: f32 = @min(self.visibleBeats(), @as(f32, @floatFromInt(total)));
            const window_start = @max(0, self.laneStart(index));
            const start = if (total > 0) window_start / @as(f32, @floatFromInt(total)) else 0;
            const span = if (total > 0)
                @min(visible, @max(1, @as(f32, @floatFromInt(total)) - window_start)) / @as(f32, @floatFromInt(total))
            else
                1;

            fillRect(self.allocator, bar_rect.x, bar_rect.y, bar_rect.w, bar_rect.h, Palette.field);
            if (lane.analysis) |*analysis| {
                paintOverview(self.allocator, analysis, bar_rect);
            }

            const window_x = bar_rect.x + bar_rect.w * start;
            const window_w = @max(18, bar_rect.w * span);
            fillRect(self.allocator, window_x, bar_rect.y, window_w, bar_rect.h, fade(Palette.ink, 26));
            fillRect(self.allocator, window_x, bar_rect.y, 1.5, bar_rect.h, Palette.ink);
            fillRect(self.allocator, window_x + window_w - 1.5, bar_rect.y, 1.5, bar_rect.h, Palette.ink);
            self.hit_map.append(bar_rect, .{ .nav = index });
        }

        self.noteLane(index, col_rect);
    }

    fn noteLane(self: *App, index: usize, rect: hit.Rect) void {
        if (index >= self.lane_rects.len) return;
        self.lane_rects[index] = rect;
        self.lane_drawn[index] = true;
        self.lane_count = @max(self.lane_count, index + 1);
        self.lane_right = @max(self.lane_right, rect.x + rect.w);
    }

    /// Draws the brace marking the group global play/stop acts on.
    fn groupStart(self: *const App) usize {
        const total = self.crate.len();
        if (total <= 4) return 0;
        return @min(self.group_start, total - 4);
    }

    fn drawGroupBrace(self: *App) void {
        const total = self.crate.len();
        if (total <= 4) return;
        const start = self.groupStart();
        if (start + 3 >= self.lane_count) return;
        if (!self.lane_drawn[start] or !self.lane_drawn[start + 3]) return;

        const top = self.lane_rects[start].y + 3;
        const bottom = self.lane_rects[start + 3].y + self.lane_rects[start + 3].h - 3;
        if (bottom - top < 12) return;

        var builder = dvui.Path.Builder.init(self.allocator);
        defer builder.deinit();
        // Clear of the trim bar, and thick enough to grab.
        const x = self.lane_right + 90;
        const mid = (top + bottom) / 2;
        const thickness: f32 = 11;
        const color: dvui.Color = .{ .r = 0xbd, .g = 0x93, .b = 0xf9, .a = 0xff };

        fillRectInto(&builder, x, top, thickness, mid - top - 8, color);
        fillRectInto(&builder, x, mid + 8, thickness, bottom - mid - 8, color);
        fillRectInto(&builder, x - 8, top, 8 + thickness, thickness, color);
        fillRectInto(&builder, x - 8, bottom - thickness, 8 + thickness, thickness, color);
        fillRectInto(&builder, x + thickness, mid - 8, 4, thickness, color);
        fillRectInto(&builder, x + thickness + 3, mid - 5, 4, thickness, color);
        fillRectInto(&builder, x + thickness + 5, mid - thickness / 2, 5, thickness, color);
        fillRectInto(&builder, x + thickness + 3, mid + 2, 4, thickness, color);
        fillRectInto(&builder, x + thickness, mid + 5, 4, thickness, color);

        self.hit_map.append(.{
            .x = x - 18,
            .y = top,
            .w = 48,
            .h = bottom - top,
        }, .group);
    }

    fn preview(self: *App, track: Track) void {
        const tempo: f32 = if (track.bpm > 0) self.masterBpm() / @as(f32, @floatCast(track.bpm)) else 1;
        if (self.player.holds(track.id)) {
            self.player.toggle(track, tempo);
            return;
        }
        if (self.transport.anyPlaying()) {
            // Spawn just before the bar: ffplay takes a moment to produce sound.
            const bar = self.transport.nextBarTime();
            const lead: i128 = 200_000_000;
            self.preview_pending = track;
            self.preview_at_ns = @max(self.transport.nowNs(), bar - lead);
            return;
        }
        self.preview_pending = null;
        self.player.toggle(track, tempo);
    }

    fn transportGroup(self: *App) []const usize {
        const total = self.crate.len();
        if (total <= 4) {
            for (0..@min(total, self.group.len)) |index| self.group[index] = index;
            return self.group[0..@min(total, self.group.len)];
        }
        const start = self.groupStart();
        for (0..4) |offset| self.group[offset] = start + offset;
        return self.group[0..4];
    }

    /// Spectrum bars under the EQ curve, with one draggable node per band.
    fn drawEqPlot(self: *App, index: usize, rect: hit.Rect) void {
        if (rect.w <= 2 or rect.h <= 2) return;
        var builder = dvui.Path.Builder.init(self.allocator);
        defer builder.deinit();

        fillRectInto(&builder, rect.x, rect.y, rect.w, rect.h, fade(Palette.background, 230));
        fillRectInto(&builder, rect.x, rect.y + rect.h / 2, rect.w, 1, fade(Palette.muted, 40));

        var spectrum: [pl.mixer.spectrum_bins]f32 = @splat(0);
        self.transport.spectrum(index, &spectrum);
        const bar_w = rect.w / pl.mixer.spectrum_bins;
        for (spectrum, 0..) |level, band| {
            if (level <= 0.01) continue;
            const height = level * (rect.h - 2);
            fillRectInto(&builder, rect.x + @as(f32, @floatFromInt(band)) * bar_w, rect.y + rect.h - height, @max(1, bar_w - 1), height, fade(Palette.secondary, 90));
        }

        const params = self.transport.eqParams(index);
        const ratio = pl.mixer.eq_max_hz / pl.mixer.eq_min_hz;
        const samples: usize = 64;
        var prev_y: f32 = rect.y + rect.h / 2;
        var step: usize = 0;
        while (step <= samples) : (step += 1) {
            const fraction = @as(f32, @floatFromInt(step)) / samples;
            const hz = pl.mixer.eq_min_hz * std.math.pow(f32, ratio, fraction);
            const db = pl.mixer.responseDb(params, hz);
            const y = rect.y + std.math.clamp(0.5 - db / (2 * pl.mixer.eq_max_gain_db), 0, 1) * rect.h;
            const top = @min(prev_y, y);
            const bottom = @max(prev_y, y);
            fillRectInto(&builder, rect.x + fraction * rect.w - 0.75, top, 1.5, @max(1, bottom - top), Palette.green);
            prev_y = y;
        }

        for (0..pl.mixer.band_count) |band| {
            const hz = std.math.clamp(params.freq_hz[band], pl.mixer.eq_min_hz, pl.mixer.eq_max_hz);
            const fx = @log(hz / pl.mixer.eq_min_hz) / @log(ratio);
            const fy = 0.5 - params.gain_db[band] / (2 * pl.mixer.eq_max_gain_db);
            const cx = rect.x + fx * rect.w;
            const cy = rect.y + fy * rect.h;
            const node = hit.Rect{ .x = cx - 9, .y = cy - 9, .w = 18, .h = 18 };
            fillRectInto(&builder, node.x, node.y, node.w, node.h, Palette.ink);
            fillRectInto(&builder, node.x + 3, node.y + 3, node.w - 6, node.h - 6, Palette.green);
            // The ball stays small; the grab area around it does not.
            const grab = hit.Rect{ .x = cx - 20, .y = cy - 20, .w = 40, .h = 40 };
            self.hit_map.append(grab, .{ .eq_node = .{ .lane = index, .band = band } });
        }
        // Appended last so a press on a ball wins over the plot behind it.
        self.hit_map.append(rect, .{ .eq_plot = index });
    }

    /// The lane's trim slider, filled from the bottom by its live level.
    fn drawTrim(self: *App, index: usize, rect: hit.Rect) void {
        if (rect.w <= 2 or rect.h <= 2) return;
        fillRect(self.allocator, rect.x, rect.y, rect.w, rect.h, fade(Palette.background, 230));

        const inner = hit.Rect{ .x = rect.x + 3, .y = rect.y + 2, .w = rect.w - 6, .h = rect.h - 4 };
        const level = std.math.clamp(self.transport.level(index), 0, 1);
        const meter_h = inner.h * level;
        fillRect(self.allocator, inner.x, inner.y + inner.h - meter_h, inner.w, meter_h, Palette.green);
        fillRect(self.allocator, rect.x, rect.y + rect.h / 2, rect.w, 1, fade(Palette.muted, 60));

        const fy = 0.5 - self.transport.trim(index) / (2 * pl.mixer.trim_max_db);
        const knob_y = rect.y + fy * rect.h;
        // The handle is what the pointer aims at, so it is wider than the track.
        fillRect(self.allocator, rect.x - 2, knob_y - 3.5, rect.w + 4, 7, Palette.ink);
        const grab = hit.Rect{ .x = rect.x - 2, .y = rect.y, .w = rect.w + 4, .h = rect.h };
        self.hit_map.append(grab, .{ .trim = index });
    }

    /// Beat count of the lane's track, from its grid.
    fn totalBeats(lane: *const Lane) usize {
        const analysis = lane.analysis orelse return 0;
        return analysis.beats.len;
    }

    /// Waveform and beat lines, drawn straight into the lane's rectangle.
    fn paintWave(self: *App, analysis: *const pl.analysis.Analysis, rect: hit.Rect, start_beat: f32, beat_offset: f32) void {
        if (rect.w <= 0 or rect.h <= 0) return;
        fillRect(self.allocator, rect.x, rect.y, rect.w, rect.h, Palette.field);

        const bpm = if (analysis.bpm() > 0) analysis.bpm() else 128;
        const scale: f32 = 255 / @as(f32, @floatFromInt(@max(1, analysis.peak)));
        const samples_per_beat: f32 = @as(f32, pl.analysis.Analysis.samples_per_second) * 60 / bpm;
        const start_sample = start_beat * samples_per_beat;
        const samples_per_px = samples_per_beat * self.visibleBeats() / rect.w;

        var builder = dvui.Path.Builder.init(self.allocator);
        defer builder.deinit();

        const has_bands = analysis.bands.len == analysis.waveform.len;

        // Buckets are anchored to the audio, not to the screen: a bar keeps the
        // same height as it scrolls. Smoothing looks both ways for the same
        // reason, instead of carrying state from the left edge.
        const step: f32 = 6;
        const bucket: usize = @max(1, @as(usize, @intFromFloat(@round(samples_per_px * step))));
        const origin_bucket: usize = if (start_sample <= 0) 0 else @as(usize, @intFromFloat(@floor(start_sample / @as(f32, @floatFromInt(bucket)))));
        const origin = origin_bucket * bucket;

        // The grid sits under the bars: over them its half-transparent lines
        // shimmered on the coloured waveform.
        self.paintBeats(rect, start_beat, beat_offset);

        var a: usize = origin;
        while (a < analysis.waveform.len) : (a += bucket) {
            const b = @min(analysis.waveform.len, a + bucket);
            const x = (@as(f32, @floatFromInt(a)) - start_sample) / samples_per_px;
            if (x >= rect.w) break;
            if (x + step > 0) {
                const current = spanLevel(analysis.waveform, a, b, scale);
                const before = if (a >= bucket) spanLevel(analysis.waveform, a - bucket, a, scale) else current;
                const after = if (b + bucket <= analysis.waveform.len) spanLevel(analysis.waveform, b, b + bucket, scale) else current;
                const smoothed = before * 0.25 + current * 0.5 + after * 0.25;
                // Cover up to the next bucket so sub-pixel scrolling cannot
                // leave seams that read as a flickering grid.
                const next_x = (@as(f32, @floatFromInt(a + bucket)) - start_sample) / samples_per_px;
                const width = @min(rect.w - x, @max(1, next_x - x));
                const height = rect.h * smoothed;
                const color = if (has_bands) waveColor(wave_colour.tintBands(smoothed, analysis.bands[a..b])) else bandColor(smoothed);
                fillRectInto(&builder, rect.x + x, rect.bottom() - height, width, height, color);

            }
        }
    }

    fn paintBeats(self: *App, rect: hit.Rect, start_beat: f32, beat_offset: f32) void {
        const visible = self.visibleBeats();
        var beat: f32 = @ceil(start_beat);
        while (beat < start_beat + visible) : (beat += 1) {
            const bx = (beat - start_beat) / visible * rect.w;
            const bar = @mod(@as(i32, @intFromFloat(beat + beat_offset)), 4) == 0;
            fillRect(self.allocator, rect.x + bx, rect.y, if (bar) 2 else 1, rect.h, fade(Palette.muted, if (bar) 90 else 45));
        }
    }

    /// The whole track at the lane's width, so the navigator reads as a
    /// waveform rather than a slider.
    fn paintOverview(allocator: std.mem.Allocator, analysis: *const pl.analysis.Analysis, rect: hit.Rect) void {
        if (rect.w <= 0 or rect.h <= 0 or analysis.waveform.len == 0) return;
        const len: f32 = @floatFromInt(analysis.waveform.len);
        const scale: f32 = 255 / @as(f32, @floatFromInt(@max(1, analysis.peak)));

        var builder = dvui.Path.Builder.init(allocator);
        defer builder.deinit();

        const has_bands = analysis.bands.len == analysis.waveform.len;

        var x: f32 = 0;
        var smoothed: f32 = 0.35;
        while (x < rect.w) : (x += 6) {
            const from: usize = @intFromFloat(@min(len - 1, x / rect.w * len));
            const to: usize = @min(analysis.waveform.len, @as(usize, @intFromFloat(@max(@as(f32, @floatFromInt(from + 1)), (x + 3) / rect.w * len))));

            var peak: u8 = 0;
            var sum: usize = 0;
            for (analysis.waveform[from..to]) |value| {
                peak = @max(peak, value);
                sum += value;
            }
            const average = @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(@max(1, to - from)));
            const level = @min(255, @max(average * 1.15, @as(f32, @floatFromInt(peak)) * 0.6) * scale * 0.55) / 255;
            smoothed = smoothed * 0.75 + level * 0.25;
            const height = rect.h * smoothed;
            const color = if (has_bands) waveColor(wave_colour.tintBands(smoothed, analysis.bands[from..to])) else bandColor(smoothed);
            fillRectInto(&builder, rect.x + x, rect.bottom() - height, 6, height, color);
        }
    }

    /// A line across the gap the drop would land in.
    fn dropLine(self: *App, index: usize, rect: hit.Rect) void {
        const gap = self.drag.gapIndex() orelse return;
        if (gap == index) {
            fillRect(self.allocator, rect.x - 20, rect.y - 4, 420, 3, Palette.purple);
        } else if (gap == index + 1) {
            fillRect(self.allocator, rect.x - 20, rect.bottom() + 4, 420, 3, Palette.purple);
        }
    }

    /// The dragged block, translucent under the pointer, so the thing in hand is
    /// visible rather than only implied by the drop line.
    fn drawGhost(self: *App) void {
        const track = self.drag.carriedTrack() orelse
            if (self.drag.carriedBlock()) |index|
                if (index < self.crate.len()) self.crate.at(index).?.* else return
            else
                return;

        // The window keeps the pointer up to date even when motion events are
        // taken by a scroll area.
        self.pointer = pointFrom(dvui.currentWindow().mouse_pt);
        const alpha = Ghost.alpha;
        const scale = self.scale_hint;
        const width = 380 * scale;
        const height = 112 * scale;
        const x = self.pointer.x - width / 2;
        const y = self.pointer.y - height / 2;

        fillRect(self.allocator, x - 2, y - 2, width + 4, height + 4, fade(Palette.purple, alpha));
        fillRect(self.allocator, x, y, width, height, fade(Palette.block, alpha));

        const is_seed = if (self.drag.carriedBlock()) |index| self.crate.seed == index else false;
        var block = dvui.box(@src(), .{ .dir = .vertical }, .{
            .rect = .{
                .x = x / scale + 14,
                .y = y / scale + 10,
                .w = width / scale - 28,
                .h = height / scale - 20,
            },
            .background = false,
            .id_extra = 4000,
        });
        defer block.deinit();

        var title_buffer: [34]u8 = undefined;
        labelStyled(@src(), clippedTitle(track.title, &title_buffer), .{
            .expand = .horizontal,
            .color_text = .{ .color = fade(if (is_seed) Palette.purple else Palette.ink, alpha) },
            .font = headingFont(),
            .id_extra = 4001,
        });

        labelStyled(@src(), track.artist, .{
            .expand = .horizontal,
            .color_text = .{ .color = fade(Palette.secondary, alpha) },
            .font = metaFont(),
            .margin = .{ .y = 4 },
            .id_extra = 4002,
        });

        var meta_buffer: [32]u8 = undefined;
        labelStyled(@src(), trackMeta(track, &meta_buffer, self.note_names), .{
            .expand = .horizontal,
            .color_text = .{ .color = fade(Palette.ink, alpha) },
            .font = metaFont(),
            .id_extra = 4003,
        });

        dvui.refresh(null, @src(), null);
    }

    const Action = union(enum) {
        none,
        remove: usize,
    };
};

const BlockAction = enum { none, remove };

fn blockColor(app: *const App, index: usize, is_seed: bool) dvui.Color {
    if (app.drag.carriedBlock()) |carried| {
        if (carried == index) return Palette.field;
    }
    if (is_seed) return Palette.selection;
    if (app.isSelected(index)) return Palette.hover;
    return Palette.block;
}

/// Pressing a row starts a drag carrying that track; the click itself adds
/// nothing, the drop does.
fn pickRow(app: *App, row_index: usize, track: Track, step: ?Transition) void {
    var meta_buffer: [32]u8 = undefined;
    const meta = trackMeta(track, &meta_buffer, app.note_names);

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 6 },
        .margin = .{ .y = 1 },
        .background = true,
        .color_fill = .{ .color = Palette.panel },
        .color_fill_hover = .{ .color = Palette.hover },
        .corners = square,
        .id_extra = row_index * 16,
    });
    defer outer.deinit();

    const title_color = if (step) |known| stepColor(known) else Palette.ink;

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = row_index * 16 + 1,
        });
        defer row.deinit();

        _ = transportButton(app, track, row_index * 16 + 7);

        labelStyled(@src(), directionGlyph(app, step), .{
            .min_size_content = .{ .w = 16 },
            .color_text = .{ .color = title_color },
            .font = metaFont(),
            .id_extra = row_index * 16 + 6,
        });

        {
            var text = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .id_extra = row_index * 16 + 2,
            });
            defer text.deinit();
            labelStyled(@src(), track.title, .{
                .expand = .horizontal,
                .color_text = .{ .color = title_color },
                .id_extra = row_index * 16 + 3,
            });
            var artist_buffer: [128]u8 = undefined;
            labelStyled(@src(), artistLine(track, &artist_buffer), .{
                .expand = .horizontal,
                .color_text = .{ .color = Palette.secondary },
                .font = metaFont(),
                .id_extra = row_index * 16 + 4,
            });

            labelStyled(@src(), meta, .{
                .color_text = .{ .color = Palette.secondary },
                .font = metaFont(),
                .id_extra = row_index * 16 + 5,
            });
        }
    }

    // The row carries a track; the play button on its left keeps its clicks.
    const row_rect = rectFrom(outer.data().contentRectScale().r)
        .clipped(app.list)
        .shiftedLeft(88 * app.scale_hint);
    app.hit_map.append(row_rect, .{ .row = track });

    progressBar(app, track, row_index * 16 + 9, 3);
}

const Block = struct { action: BlockAction, rect: hit.Rect };

fn drawBlock(app: *App, index: usize, track: Track) Block {
    const is_seed = app.crate.seed == index;

    var block = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = 380, .h = 112 },
        // Every card the same width, so the grid beside it starts at the same
        // x on every row and the playheads stack.
        .max_size_content = .{ .w = 380, .h = 100000 },
        .padding = .{ .x = 14, .y = 10 },
        .margin = .{ .x = 6, .y = 6 },
        .background = true,
        .color_fill = .{ .color = blockColor(app, index, is_seed) },
        .color_fill_hover = .{ .color = if (is_seed) Palette.selection else Palette.hover },
        .corners = square,
        .id_extra = index * 16,
    });
    defer block.deinit();

    const rect = rectFrom(block.data().rectScaleFromParent().r);
    if (index < app.block_rects.len) {
        app.block_rects[index] = rect;
        app.block_count = @max(app.block_count, index + 1);
    }
    app.hit_map.append(rect.clipped(app.canvas), .{ .block = index });

    var removed = false;
    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = index * 16 + 6,
        });
        defer top.deinit();

        var title_buffer: [34]u8 = undefined;
        labelStyled(@src(), clippedTitle(track.title, &title_buffer), .{
            .expand = .horizontal,
            .color_text = .{ .color = if (is_seed) Palette.purple else Palette.ink },
            .font = headingFont(),
            .id_extra = index * 16 + 1,
        });
        removed = dvui.button(@src(), "×", .{}, .{
            .min_size_content = .{ .w = 22, .h = 22 },
            .padding = .{ .x = 4, .y = 0 },
            .id_extra = index * 16 + 7,
            .color_text = .{ .color = Palette.secondary },
        });
    }

    labelStyled(@src(), track.artist, .{
        .expand = .horizontal,
        .color_text = .{ .color = Palette.secondary },
        .font = metaFont(),
        .margin = .{ .y = 4 },
        .id_extra = index * 16 + 2,
    });

    var meta_buffer: [32]u8 = undefined;
    labelStyled(@src(), trackMeta(track, &meta_buffer, app.note_names), .{
        .expand = .horizontal,
        .color_text = .{ .color = Palette.ink },
        .font = metaFont(),
        .id_extra = index * 16 + 3,
    });

    {
        var bottom = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = index * 16 + 10,
        });
        defer bottom.deinit();

        var spacer = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = index * 16 + 11,
        });
        spacer.deinit();

        if (track.genre.len > 0) {
            var genre_buffer: [34]u8 = undefined;
            labelStyled(@src(), clippedTitle(track.genre, &genre_buffer), .{
                .color_text = .{ .color = Palette.secondary },
                .font = metaFont(),
                .margin = .{ .x = 8 },
                .id_extra = index * 16 + 4,
            });
        }
    }

    return .{ .action = if (removed) .remove else .none, .rect = rect };
}

/// One connector per gap: three triangles pointing the way the energy moves,
/// or an equals sign when it holds, coloured by the size of the step.
fn connector(allocator: std.mem.Allocator, gap: usize, step: Transition) void {
    var area = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .min_size_content = .{ .w = 380, .h = 40 },
        .id_extra = gap,
    });
    defer area.deinit();

    const color = stepColor(step);
    const direction: pl.camelot.Direction = if (step.key_known) step.key.direction else .held;

    drawBpmDelta(area.data().contentRectScale(), step.bpm_delta);

    if (direction == .held) {
        labelStyled(@src(), "=", .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = .{ .color = color },
            .font = headingFont().withSize(22),
            .id_extra = gap * 8,
        });
        return;
    }

    const rect_scale = area.data().contentRectScale();
    const rect = rect_scale.r;
    const scale = rect_scale.s;
    const center_x = rect.x + rect.w / 2;
    const center_y = rect.y + rect.h / 2;
    const points_up = direction == .up;

    for (0..3) |index| {
        const offset = (@as(f32, @floatFromInt(index)) - 1) * 18 * scale;
        drawTriangle(allocator, center_x + offset, center_y, 6 * scale, points_up, color);
    }
}

/// The tempo movement across a gap, drawn beside its connector.
fn drawBpmDelta(rs: dvui.RectScale, delta: f64) void {
    var buffer: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{s}{d:.1}", .{
        if (delta < 0) "-" else "+",
        @abs(delta),
    }) catch return;

    const center_x = rs.r.x + rs.r.w / 2;
    const center_y = rs.r.y + rs.r.h / 2;
    dvui.renderText(.{
        .font = metaFont(),
        .text = text,
        .rs = rs,
        .p = .{ .x = center_x + 34 * rs.s, .y = center_y - 8 * rs.s },
        .color = Palette.muted,
    }) catch {};
}

fn drawTriangle(allocator: std.mem.Allocator, x: f32, y: f32, size: f32, points_up: bool, color: dvui.Color) void {
    const tip_y = if (points_up) y - size else y + size;

    var builder = dvui.Path.Builder.init(allocator);
    defer builder.deinit();

    builder.addPoint(.{ .x = x, .y = tip_y });
    builder.addPoint(.{ .x = x - size, .y = if (points_up) y + size else y - size });
    builder.addPoint(.{ .x = x + size, .y = if (points_up) y + size else y - size });

    dvui.Path.fillConvex(builder.build(), .{ .color = .{ .color = color } });
}

fn fillRect(allocator: std.mem.Allocator, x: f32, y: f32, w: f32, h: f32, color: dvui.Color) void {
    var builder = dvui.Path.Builder.init(allocator);
    defer builder.deinit();

    builder.addPoint(.{ .x = x, .y = y });
    builder.addPoint(.{ .x = x + w, .y = y });
    builder.addPoint(.{ .x = x + w, .y = y + h });
    builder.addPoint(.{ .x = x, .y = y + h });

    dvui.Path.fillConvex(builder.build(), .{ .color = .{ .color = color } });
}

/// The bar under a row or block: how far the snippet has run.
fn progressBar(app: *App, track: Track, id_extra: usize, height: f32) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = height },
        .margin = .{ .y = 6, .w = 6 },
        .background = true,
        .color_fill = .{ .color = Palette.field },
        .corners = square,
        .id_extra = id_extra,
    });
    defer bar.deinit();

    const rect = bar.data().contentRectScale().r;

    const progress = app.player.progress(track.id);
    if (progress > 0) {
        fillRect(app.allocator, rect.x, rect.y, rect.w * progress, rect.h, Palette.purple);
    }
}

/// Play and pause are drawn rather than typed: no font in reach has a pause
/// glyph that lines up with a play triangle.
fn transportButton(app: *App, track: Track, id_extra: usize) bool {
    var area = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .min_size_content = .{ .w = 26, .h = 26 },
        .margin = .{ .x = 4 },
        .background = true,
        .color_fill = .{ .color = Palette.background },
        .color_fill_hover = .{ .color = Palette.hover },
        .id_extra = id_extra,
    });
    defer area.deinit();

    const rect_scale = area.data().contentRectScale();
    const rect = rect_scale.r;
    const scale = rect_scale.s;
    const center_x = rect.x + rect.w / 2;
    const center_y = rect.y + rect.h / 2;

    if (app.player.isPlaying(track.id)) {
        drawPauseBars(app.allocator, center_x, center_y, 5 * scale);
    } else {
        drawPlayTriangle(app.allocator, center_x, center_y, 6 * scale);
    }

    if (!dvui.clicked(area.data(), .{})) return false;
    app.preview(track);
    return true;
}

fn drawPlayTriangle(allocator: std.mem.Allocator, cx: f32, cy: f32, size: f32) void {
    var builder = dvui.Path.Builder.init(allocator);
    defer builder.deinit();

    builder.addPoint(.{ .x = cx - size * 0.55, .y = cy - size });
    builder.addPoint(.{ .x = cx + size * 0.85, .y = cy });
    builder.addPoint(.{ .x = cx - size * 0.55, .y = cy + size });

    dvui.Path.fillConvex(builder.build(), .{ .color = .{ .color = Palette.ink } });
}

fn drawPauseBars(allocator: std.mem.Allocator, cx: f32, cy: f32, size: f32) void {
    const width = size * 0.45;
    const gap = size * 0.4;
    fillRect(allocator, cx - gap - width, cy - size, width, size * 2, Palette.ink);
    fillRect(allocator, cx + gap, cy - size, width, size * 2, Palette.ink);
}

/// Same colour at a given opacity, for the block being carried.
pub fn fade(color: dvui.Color, alpha: u8) dvui.Color {
    var dimmed = color;
    dimmed.a = alpha;
    return dimmed;
}

/// Pioneer's colour waveform in spirit: steady bass reads blue, transients push
/// the colour through orange towards white.
/// Heat map: quiet reads indigo, body red and orange, peaks yellow. The
/// waveform carries one amplitude byte, so loudness is the only information.
fn spanLevel(samples: []const u8, from: usize, to: usize, scale: f32) f32 {
    var peak: u8 = 0;
    var sum: usize = 0;
    for (samples[from..to]) |value| {
        peak = @max(peak, value);
        sum += value;
    }
    const average = @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(@max(1, to - from)));
    return @min(255, @max(average * 1.15, @as(f32, @floatFromInt(peak)) * 0.6) * scale * 0.55) / 255;
}

fn waveColor(color: wave_colour.Color) dvui.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
}

pub fn bandColor(level: f32) dvui.Color {
    return waveColor(wave_colour.heat(level));
}

pub fn mixColor(a: dvui.Color, b: dvui.Color, t: f32) dvui.Color {
    const f = std.math.clamp(t, 0, 1);
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(a.r)) + (@as(f32, @floatFromInt(b.r)) - @as(f32, @floatFromInt(a.r))) * f),
        .g = @intFromFloat(@as(f32, @floatFromInt(a.g)) + (@as(f32, @floatFromInt(b.g)) - @as(f32, @floatFromInt(a.g))) * f),
        .b = @intFromFloat(@as(f32, @floatFromInt(a.b)) + (@as(f32, @floatFromInt(b.b)) - @as(f32, @floatFromInt(a.b))) * f),
        .a = 0xff,
    };
}

/// Same as `fillRect`, but reuses the builder: a waveform is hundreds of
/// columns per frame and allocating a path for each one stalls the UI.
pub fn fillRectInto(builder: *dvui.Path.Builder, x: f32, y: f32, w: f32, h: f32, color: dvui.Color) void {
    builder.points.clearRetainingCapacity();
    builder.addPoint(.{ .x = x, .y = y });
    builder.addPoint(.{ .x = x + w, .y = y });
    builder.addPoint(.{ .x = x + w, .y = y + h });
    builder.addPoint(.{ .x = x, .y = y + h });
    dvui.Path.fillConvex(builder.build(), .{ .color = .{ .color = color } });
}

fn rectFrom(rect: dvui.Rect.Physical) hit.Rect {
    return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
}

fn pointFrom(point: dvui.Point.Physical) hit.Point {
    return .{ .x = point.x, .y = point.y };
}

/// Along the bottom: the direction filters on the left, the tempo window and
/// the colour key on the right.
/// The strip under the suggestion column: the direction filters centred in the
/// column's width, matching the list above.
fn frameSuggestFooter(app: *App) void {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = 420 },
        .max_size_content = .{ .w = 420, .h = 100000 },
        .expand = .vertical,
    });
    defer col.deinit();

    var bpm_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer bpm_row.deinit();
    app.frameBpmWindow();
    app.sortButton();

    var filters = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer filters.deinit();
    app.energyToggle("=", Palette.green, &app.filter_hold, .hold);
    app.energyToggle("↑", Palette.orange, &app.filter_up, .up);
    app.energyToggle("↓", Palette.orange, &app.filter_down, .down);
}

fn frameFooter(app: *App) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 40 },
        .padding = .{ .x = 0, .y = 6 },
        .background = true,
        .color_fill = .{ .color = Palette.panel },
    });
    defer bar.deinit();

    frameSuggestFooter(app);

    // Key and tempo sit past the suggestion column, not under it.
    app.notationToggle();

    var spacer = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    spacer.deinit();

    app.transportToggle();
    app.clearButton();

    var spacer2 = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    spacer2.deinit();

    app.frameWidthSelector();
    app.frameMaster();
}

/// The list shows exactly the directions enabled in the footer.
fn passesFilter(app: *const App, step: Transition) bool {
    if (!step.key_known) return app.filter_hold;
    return switch (step.key.direction) {
        .up => app.filter_up,
        .down => app.filter_down,
        .held => app.filter_hold,
    };
}

/// The suggestion list mirrors the canvas: colour is the size of the step, the
/// arrow is its direction.
fn directionGlyph(app: *const App, step: ?Transition) []const u8 {
    const known = step orelse return "";
    if (!known.key_known) return "";
    return switch (known.key.direction) {
        .up => if (app.arrow_font) "↑" else "+",
        .down => if (app.arrow_font) "↓" else "-",
        .held => "",
    };
}

fn artistLine(track: Track, buffer: []u8) []const u8 {
    if (track.genre.len == 0) return track.artist;
    return std.fmt.bufPrint(buffer, "{s} · {s}", .{ track.artist, track.genre }) catch track.artist;
}

/// Key then tempo, as rekordbox shows them.
fn trackMeta(track: Track, buffer: []u8, note_names: bool) []const u8 {
    const key = track.key orelse
        return std.fmt.bufPrint(buffer, "{d:.1} bpm", .{track.bpm}) catch "";
    var key_buffer: [8]u8 = undefined;
    const label = if (note_names)
        key.note()
    else
        std.fmt.bufPrint(&key_buffer, "{d}{c}", .{ key.number, key.side() }) catch "";
    return std.fmt.bufPrint(buffer, "{s} · {d:.1} bpm", .{ label, track.bpm }) catch "";
}

fn stepColor(step: Transition) dvui.Color {
    return rampColor(severity(step));
}

/// How far the transition moves the energy, 0 for a pair that holds and 1 for
/// one that clashes. Direction is not part of it.
fn severity(step: Transition) f32 {
    if (!step.key_known) return 0;
    if (!step.key.harmonic) return 1;
    return switch (step.key.strength) {
        .none => 0,
        .slight => 0.3,
        .strong => 0.6,
        .big => 0.85,
    };
}

/// Green through yellow and orange to red, so a glance at the colour ranks the
/// step without counting triangles.
fn rampColor(t: f32) dvui.Color {
    const stops = [_]struct { at: f32, color: dvui.Color }{
        .{ .at = 0.0, .color = Palette.green },
        .{ .at = 0.4, .color = Palette.yellow },
        .{ .at = 0.7, .color = Palette.orange },
        .{ .at = 1.0, .color = Palette.red },
    };

    const clamped = std.math.clamp(t, 0, 1);
    for (stops[0 .. stops.len - 1], stops[1..]) |from, to| {
        if (clamped > to.at) continue;
        const span = to.at - from.at;
        const mix = if (span == 0) 0 else (clamped - from.at) / span;
        return blend(from.color, to.color, mix);
    }
    return Palette.red;
}

fn blend(from: dvui.Color, to: dvui.Color, mix: f32) dvui.Color {
    return .{
        .r = mixChannel(from.r, to.r, mix),
        .g = mixChannel(from.g, to.g, mix),
        .b = mixChannel(from.b, to.b, mix),
        .a = 0xff,
    };
}

fn mixChannel(from: u8, to: u8, mix: f32) u8 {
    const start: f32 = @floatFromInt(from);
    const end: f32 = @floatFromInt(to);
    return @intFromFloat(@round(start + (end - start) * mix));
}

/// A block is 380 wide, so a long title has to be cut rather than run into the
/// close button beside it.
fn clippedTitle(title: []const u8, buffer: *[34]u8) []const u8 {
    const limit: usize = 30;
    if (title.len <= limit) return title;

    var end: usize = limit;
    while (end > 0 and (title[end] & 0xc0) == 0x80) end -= 1;

    @memcpy(buffer[0..end], title[0..end]);
    buffer[end] = 0xe2;
    buffer[end + 1] = 0x80;
    buffer[end + 2] = 0xa6;
    return buffer[0 .. end + 3];
}

/// `src` must come from the caller: a widget's id is derived from the source
/// location, so a shared one here would collide across every call site.
fn labelStyled(src: std.builtin.SourceLocation, text: []const u8, options: dvui.Options) void {
    dvui.labelNoFmt(src, text, .{}, options);
}

fn labelFmt(src: std.builtin.SourceLocation, comptime format: []const u8, arguments: anytype, options: dvui.Options) void {
    dvui.label(src, format, arguments, options);
}

fn bodyFont() dvui.Font {
    return dvui.themeGet().font_body;
}

fn metaFont() dvui.Font {
    return dvui.themeGet().font_body;
}

fn headingFont() dvui.Font {
    return dvui.themeGet().font_heading;
}

fn titleFont() dvui.Font {
    return dvui.themeGet().font_title;
}

/// Every surface in the app is rectangular; the theme rounds them by default.
const square = dvui.CornerRect{
    .tl = .{ .kind = .square },
    .tr = .{ .kind = .square },
    .bl = .{ .kind = .square },
    .br = .{ .kind = .square },
};

/// The block carried under the pointer is the drawn block at this opacity.
const Ghost = struct {
    const alpha: u8 = 0xaa;
};

pub const Palette = struct {
    /// One surface for the whole window: a second shade behind the canvas read
    /// as a box stretching to the edge.
    pub const background = dvui.Color{ .r = 0x1e, .g = 0x1f, .b = 0x27, .a = 0xff };
    pub const panel = dvui.Color{ .r = 0x1e, .g = 0x1f, .b = 0x27, .a = 0xff };
    pub const block = dvui.Color{ .r = 0x34, .g = 0x37, .b = 0x46, .a = 0xff };
    pub const selection = dvui.Color{ .r = 0x44, .g = 0x47, .b = 0x5a, .a = 0xff };
    pub const hover = dvui.Color{ .r = 0x3a, .g = 0x3d, .b = 0x4d, .a = 0xff };
    /// Heat ramp for loudness: deep indigo through red and orange to yellow.
    pub const heat0 = dvui.Color{ .r = 0x1a, .g = 0x1f, .b = 0x4b, .a = 0xff };
    pub const heat1 = dvui.Color{ .r = 0x6a, .g = 0x2c, .b = 0x8f, .a = 0xff };
    pub const heat2 = dvui.Color{ .r = 0xc0, .g = 0x3a, .b = 0x2b, .a = 0xff };
    pub const heat3 = dvui.Color{ .r = 0xf2, .g = 0x8f, .b = 0x24, .a = 0xff };
    pub const heat4 = dvui.Color{ .r = 0xff, .g = 0xd7, .b = 0x5e, .a = 0xff };
    pub const field = dvui.Color{ .r = 0x21, .g = 0x22, .b = 0x2c, .a = 0xff };
    pub const ink = dvui.Color{ .r = 0xf8, .g = 0xf8, .b = 0xf2, .a = 0xff };
    /// Dracula's own comment blue is about 3:1 on this background, which is too
    /// faint for anything but decoration. These two carry text.
    pub const secondary = dvui.Color{ .r = 0xc3, .g = 0xc7, .b = 0xd9, .a = 0xff };
    pub const muted = dvui.Color{ .r = 0x92, .g = 0x99, .b = 0xb8, .a = 0xff };
    pub const green = dvui.Color{ .r = 0x50, .g = 0xfa, .b = 0x7b, .a = 0xff };
    pub const yellow = dvui.Color{ .r = 0xf1, .g = 0xfa, .b = 0x8c, .a = 0xff };
    pub const orange = dvui.Color{ .r = 0xff, .g = 0xb8, .b = 0x6c, .a = 0xff };
    pub const purple = dvui.Color{ .r = 0xbd, .g = 0x93, .b = 0xf9, .a = 0xff };
    pub const red = dvui.Color{ .r = 0xff, .g = 0x55, .b = 0x55, .a = 0xff };

};
