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

const Track = pl.track.Track;
const Transition = pl.crate.Transition;
const Candidate = pl.suggest.Candidate;

const Lane = struct {
    track_id: u64 = 0,
    analysis: ?pl.analysis.Analysis = null,
    /// Beat under the playhead: what playback starts on and what the window
    /// is centred around.
    beat: f32 = 0,
    /// Stable mixer slot, so reordering blocks does not touch the audio.
    slot: usize = 0,
    /// This lane's own process is running.
    playing: bool = false,
    /// Master beat when this lane started.
    started_master: f32 = 0,
    /// Wall clock when the audio should end.
    end_ns: i128 = 0,
    /// Filter moved while playing; restart on release.
    filter_dirty: bool = false,
    /// Unrounded drag position, so sub-beat movements are not lost to snapping.
    beat_raw: f32 = 0,
    /// Band filter, 0 closed to 1 open.
    filter: f32 = 1,
    /// Height of the filter strip, in physical pixels.
    filter_h: f32 = 1,
    /// Left edge and width of the scrub bar, for click-to-seek.
    nav_x: f32 = 0,
    /// Top edge of the filter strip, for click-to-set.
    filter_y: f32 = 0,
    /// The waveform was moved by hand, so this lane carries an offset.
    manual: bool = false,
    /// Full width of the whole-track navigator, in physical pixels.
    nav_w: f32 = 1,
    /// Set when the source has no analysis for this track.
    missing: bool = false,
    /// Width of the waveform, in physical pixels, for drag arithmetic.
    wave_w: f32 = 1,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    library: pl.library.Library,
    player: pl.player.Player,
    mixer: pl.mixer.Mixer,
    crate: pl.crate.Crate,

    query: std.ArrayList(u8) = .empty,
    found: []const Track = &.{},
    ranked: []Candidate = &.{},

    /// Energy filters: the list shows exactly the directions enabled here.
    filter_up: bool = true,
    filter_down: bool = true,
    filter_hold: bool = true,
    /// Key display: wheel numbers by default, note names on request.
    note_names: bool = false,
    /// Candidates the tempo window admits, so the field shows its effect even
    /// when the top of the list looks the same.
    in_range: usize = 0,
    /// Blocks picked for the previewer, by crate index. Empty means none.
    selected: std.ArrayListUnmanaged(usize) = .empty,
    /// One grid lane per block, in crate order.
    grid: std.ArrayListUnmanaged(Lane) = .empty,
    
    /// Bars or polygon fills, for A/B comparison.
    poly: bool = false,
    /// Smoothed frame cost, shown next to the renderer switch.
    draw_ms: f32 = 0,
    /// Master clock every playing lane is derived from.
    clock_running: bool = false,
    clock_started_ns: i128 = 0,
    clock_beat: f32 = 0,
    /// Next mixer slot to hand out.
    next_slot: usize = 0,
    /// Lane held down with the pointer: jog pause, resume on release.
    jog_lane: ?usize = null,
    /// Master tempo: follows the seed while locked, manual otherwise.
    master_bpm: f32 = 128,
    master_text: std.ArrayList(u8) = .empty,
    master_locked: bool = true,
    /// Keep the pitch while the tempo changes.
    pitch_lock: bool = true,

    /// Where the last press landed, for controls that act on absolute position.
    last_point: hit.Point = .{},

    /// Tempo window for suggestions, as a percentage of the seed's BPM.
    bpm_pct: f32 = 5,
    bpm_text: std.ArrayList(u8) = .empty,

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
    /// Beats shown across a preview lane.
    const beats_visible: f32 = 16;
    const lane_panel_width: f32 = 380;
    /// Toolbar plus footer, measured once and fixed: reading them back made a
    /// resize lag a frame and flicker.
    const chrome_height: f32 = 104;

    pub fn init(allocator: std.mem.Allocator, library: pl.library.Library, io: std.Io) App {
        return .{
            .allocator = allocator,
            .io = io,
            .library = library,
            .player = pl.player.Player.init(io, allocator),
            .mixer = pl.mixer.Mixer.init(allocator, io),
            .crate = pl.crate.Crate.init(allocator),
            .hit_map = hit.HitMap.init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        self.mixer.deinit();
        for (self.grid.items) |*lane| {
            if (lane.analysis) |*a| a.deinit(self.allocator);
        }
        self.grid.deinit(self.allocator);
        self.selected.deinit(self.allocator);
        self.master_text.deinit(self.allocator);
        self.hit_map.deinit();
        self.player.deinit();
        self.bpm_text.deinit(self.allocator);
        self.allocator.free(self.ranked);
        self.query.deinit(self.allocator);
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
    }

    pub fn frame(self: *App) bool {
        const frame_started = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
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
        for (self.grid.items, 0..) |*lane, index| {
            if (lane.playing and self.nowNs() >= lane.end_ns) self.stopLane(index);
        }
        self.mixer.reap(self.nowNs());

        // The pointer pass reads the map the previous frame drew, then the map
        // is rebuilt from this frame's layout.
        self.handlePointer();
        self.syncGrid();

        self.hit_map.reset();

        frameToolbar();
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

        const frame_ended = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        const frame_ms: f32 = @floatCast(@as(f64, @floatFromInt(frame_ended - frame_started)) / 1_000_000);
        self.draw_ms = self.draw_ms * 0.85 + frame_ms * 0.15;
        return true;
    }

    fn frameToolbar() void {
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
        if (self.mode() != .suggest or heading == null) {
            const text = switch (self.mode()) {
                .search => "Search results",
                .browse => "Pick a seed",
                .suggest => "",
            };
            labelStyled(@src(), text, headingOptions());
            return;
        }

        var buffer: [34]u8 = undefined;
        labelFmt(@src(), "Next to {s}", .{clippedTitle(heading.?.title, &buffer)}, headingOptions());
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
        });
        const changed = entry.text_changed;
        entry.deinit();

        var count_buffer: [24]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buffer, "{d} in range", .{self.in_range}) catch "";
        labelStyled(@src(), count, .{
            .color_text = .{ .color = Palette.muted },
            .font = metaFont(),
            .margin = .{ .x = 6, .y = 6 },
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
                self.drawLane(index);
            }

            if (self.crate.transition(index)) |step| connector(self.allocator, index, step);
        }

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
                self.crate.remove(index) catch {};
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
                            if (index < self.grid.items.len and self.grid.items[index].playing) {
                                self.jogPause(index);
                            }
                        },
                        else => {},
                    }
                },
                .motion => {
                    if (self.drag.motion(p, 6 * self.scale_hint, self.canvas, &self.hit_map)) {
                        dvui.refresh(null, @src(), null);
                    }
                    if (self.drag.pull(p)) |pull| self.applyPull(pull);
                },
                .release => {
                    if (!mouse.button.pointer()) continue;
                    self.apply(self.drag.release());
                    self.jogResume();
                    self.restartDirty();
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
            .set_filter => |index| {
                if (index >= self.grid.items.len) return;
                const lane = &self.grid.items[index];
                const from_top = std.math.clamp((self.last_point.y - lane.filter_y) / @max(1, lane.filter_h), 0, 1);
                lane.filter = 1 - from_top;
                if (lane.playing) lane.filter_dirty = true;
                dvui.refresh(null, @src(), null);
            },
            .seek_nav => |index| {
                if (index >= self.grid.items.len) return;
                const total: f32 = @floatFromInt(totalBeats(&self.grid.items[index]));
                const fraction = std.math.clamp((self.last_point.x - self.grid.items[index].nav_x) / @max(1, self.grid.items[index].nav_w), 0, 1);
                // Only this lane moves; it lands on a bar.
                self.seekLane(index, fraction * total);
                dvui.refresh(null, @src(), null);
            },
            .toggle_master_lock => {
                self.master_locked = !self.master_locked;
                if (!self.master_locked) self.master_bpm = self.masterBpm();
                self.stopAllLanes();
                dvui.refresh(null, @src(), null);
            },
            .toggle_pitch => {
                self.pitch_lock = !self.pitch_lock;
                for (self.grid.items, 0..) |*lane, index| {
                    if (lane.playing) self.restartLane(index);
                }
                dvui.refresh(null, @src(), null);
            },
            .toggle_wave_mode => {
                self.poly = !self.poly;
                dvui.refresh(null, @src(), null);
            },
            .toggle_transport => {
                if (self.anyPlaying()) {
                    self.stopAllLanes();
                } else {
                    for (self.grid.items, 0..) |*lane, index| {
                        if (!lane.playing) self.startLane(index);
                    }
                }
                dvui.refresh(null, @src(), null);
            },
            .toggle_lane_play => |index| {
                if (index >= self.grid.items.len) return;
                if (self.grid.items[index].playing) {
                    self.stopLane(index);
                } else {
                    self.startLane(index);
                }
                dvui.refresh(null, @src(), null);
            },
            .select_block => |index| self.pending_select = index,
            .toggle_block => |index| {
                self.toggleSelected(index);
                dvui.refresh(null, @src(), null);
            },
            .drop_track => |drop| {
                _ = self.crate.insertAt(drop.gap, drop.track) catch {};
                self.selected.clearRetainingCapacity();
                self.refresh() catch {};
                dvui.refresh(null, @src(), null);
            },
            .move_block => |move| {
                if (self.crate.at(move.from)) |track| self.player.stopPreview(track.id);
                self.crate.moveTo(move.from, move.gap) catch {};
                self.selected.clearRetainingCapacity();
                self.refresh() catch {};
                dvui.refresh(null, @src(), null);
            },
        }
    }

    fn masterBpm(self: *const App) f32 {
        if (!self.master_locked) return self.master_bpm;
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

    fn nowNs(self: *const App) i128 {
        return std.Io.Timestamp.now(self.io, .awake).nanoseconds;
    }

    /// Master beat: the one grid every playing lane follows.
    fn masterBeat(self: *const App) f32 {
        if (!self.clock_running) return self.clock_beat;
        const now = self.nowNs();
        const elapsed_ns: f64 = @floatFromInt(@max(0, now - self.clock_started_ns));
        return self.clock_beat + @as(f32, @floatCast(elapsed_ns / 1_000_000_000 * self.masterBpm() / 60));
    }

    fn startClock(self: *App) void {
        if (self.clock_running) return;
        // The clock starts on a bar of its own grid.
        self.clock_beat = @round(self.clock_beat / 4) * 4;
        self.clock_started_ns = self.nowNs();
        self.clock_running = true;
    }

    fn stopClock(self: *App) void {
        if (!self.clock_running) return;
        self.clock_beat = self.masterBeat();
        self.clock_running = false;
    }

    /// Beat under the playhead: the lane's base plus whatever the master clock
    /// has advanced since the lane started.
    fn laneBeat(self: *const App, lane: *const Lane) f32 {
        if (!lane.playing) return lane.beat;
        const master = self.masterBeat();
        if (master < lane.started_master) return lane.beat;
        return lane.beat + (master - lane.started_master);
    }

    /// Beat at the left edge of a lane's window. Negative at the start of a
    /// track, before the first bar.
    fn laneStart(self: *const App, lane: *const Lane) f32 {
        return self.laneBeat(lane) - beats_visible / 2;
    }

    /// Folds elapsed time without rounding: jog and filter changes must not
    /// move the playhead.
    fn foldLane(self: *App, lane: *Lane) void {
        if (!lane.playing) return;
        lane.beat = self.laneBeat(lane);
        lane.beat_raw = lane.beat;
    }

    /// Stopping lands on a bar so lanes stay phase-aligned.
    fn snapBar(lane: *Lane) void {
        lane.beat = @round(lane.beat / 4) * 4;
        lane.beat_raw = lane.beat;
    }

    fn snapLane(lane: *Lane) void {
        const total: f32 = @floatFromInt(totalBeats(lane));
        lane.beat_raw = std.math.clamp(lane.beat_raw, 0, total);
        // Bars: four beats per step.
        lane.beat = @round(lane.beat_raw / 4) * 4;
    }

    fn snapBeat(lane: *Lane) void {
        const total: f32 = @floatFromInt(totalBeats(lane));
        lane.beat_raw = std.math.clamp(lane.beat_raw, 0, total);
        lane.beat = @round(lane.beat_raw);
    }

    fn laneSpec(self: *App, index: usize, delay_ms: u32) pl.mixer.Lane {
        const track = self.crate.at(index).?.*;
        const bpm: f32 = if (track.bpm > 0) @floatCast(track.bpm) else 128;
        return .{
            .track = track,
            .start_s = self.laneBeat(&self.grid.items[index]) * 60 / bpm,
            .tempo = self.masterBpm() / bpm,
            .filter = self.grid.items[index].filter,
            .keylock = self.pitch_lock,
            .delay_ms = delay_ms,
        };
    }

    fn startLane(self: *App, index: usize) void {
        if (index >= self.grid.items.len or index >= self.crate.len()) return;
        const lane = &self.grid.items[index];
        if (lane.analysis == null) return;
        // Untouched lanes always launch on a bar.
        if (!lane.manual) snapBar(lane);
        const was_running = self.clock_running;
        self.startClock();

        // Mid-bar starts are delayed to the next master bar, so every lane's
        // downbeats line up in time.
        const phase = @mod(self.masterBeat(), 4);
        const wait: f32 = if (was_running and phase > 0.01) 4 - phase else 0;
        lane.started_master = self.masterBeat() + wait;

        const remaining: f32 = @as(f32, @floatFromInt(totalBeats(lane))) - lane.beat;
        lane.end_ns = self.nowNs() + @as(i128, @intFromFloat((wait + @max(0, remaining)) * 60 / self.masterBpm() * 1_000_000_000));
        lane.playing = true;
        const delay_ms: u32 = @intFromFloat(wait * 60 / self.masterBpm() * 1000);
        self.mixer.play(lane.slot, self.laneSpec(index, delay_ms));
    }

    fn stopLane(self: *App, index: usize) void {
        if (index >= self.grid.items.len) return;
        const lane = &self.grid.items[index];
        self.mixer.stop(lane.slot);
        self.foldLane(lane);
        snapBar(lane);
        lane.playing = false;
        if (!self.anyPlaying()) self.stopClock();
    }

    fn stopAllLanes(self: *App) void {
        for (self.grid.items) |*lane| {
            if (lane.playing) {
                self.mixer.stop(lane.slot);
                self.foldLane(lane);
                snapBar(lane);
                lane.playing = false;
            }
        }
        self.mixer.stopAll();
        self.stopClock();
    }

    fn anyPlaying(self: *const App) bool {
        for (self.grid.items) |*lane| {
            if (lane.playing) return true;
        }
        return false;
    }

    /// Restarts a lane at its playhead, picking up tempo or filter changes.
    fn restartLane(self: *App, index: usize) void {
        if (index >= self.grid.items.len) return;
        const lane = &self.grid.items[index];
        if (!lane.playing) return;
        // Resume from where the audio has reached, not from the last start.
        self.foldLane(lane);
        self.mixer.stop(lane.slot);
        self.startLane(index);
    }

    /// Seek: the lane stops, moves, and resumes if it was running.
    fn seekLane(self: *App, index: usize, beat: f32) void {
        if (index >= self.grid.items.len) return;
        const was_playing = self.grid.items[index].playing;
        self.mixer.stop(self.grid.items[index].slot);
        self.foldLane(&self.grid.items[index]);
        self.grid.items[index].playing = false;
        self.grid.items[index].beat_raw = beat;
        snapLane(&self.grid.items[index]);
        self.grid.items[index].manual = false;
        if (was_playing) self.startLane(index);
    }

    pub fn animating(self: *const App) bool {
        return self.anyPlaying();
    }

    /// After a filter drag, put the new cutoff into the audio.
    /// Holding a playing lane pauses it; releasing resumes from the same beat.
    fn jogPause(self: *App, index: usize) void {
        const lane = &self.grid.items[index];
        self.mixer.stop(lane.slot);
        self.foldLane(lane);
        lane.playing = false;
        if (!self.anyPlaying()) self.stopClock();
        self.jog_lane = index;
    }

    fn jogResume(self: *App) void {
        const index = self.jog_lane orelse return;
        self.jog_lane = null;
        if (index < self.grid.items.len) self.startLane(index);
    }

    fn restartDirty(self: *App) void {
        for (self.grid.items, 0..) |*lane, index| {
            if (!lane.filter_dirty) continue;
            lane.filter_dirty = false;
            if (!lane.playing) continue;
            // Swap the audio only: the playhead keeps running.
            self.mixer.swap(lane.slot, self.laneSpec(index, 0));
        }
    }

    fn takeSlot(self: *App) usize {
        const slot = self.next_slot % pl.mixer.max_lanes;
        self.next_slot += 1;
        return slot;
    }

    /// Loads a grid lane for every block. Lanes survive edits: a lane matched
    /// by track keeps its audio, position and analysis, and a new block starts
    /// paused.
    fn syncGrid(self: *App) void {
        if (self.grid.items.len == self.crate.len()) {
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
                lane.slot = self.takeSlot();
                lane.analysis = self.library.analysis(self.allocator, track.id) catch null;
                lane.missing = lane.analysis == null;
            }

            next.append(self.allocator, lane) catch {};
        }

        for (self.grid.items, 0..) |*old, old_index| {
            if (consumed[old_index]) continue;
            if (old.playing) self.mixer.stop(old.slot);
            if (old.analysis) |*a| a.deinit(self.allocator);
        }

        self.grid.deinit(self.allocator);
        self.grid = next;
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
        const changed = entry.text_changed;
        entry.deinit();

        if (changed) {
            const parsed = std.fmt.parseFloat(f32, self.master_text.items) catch null;
            if (parsed) |value| self.master_bpm = std.math.clamp(value, 40, 220);
            self.master_locked = false;
            // Running lanes were tuned to the old tempo.
            self.stopAllLanes();
        }

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
            labelStyled(@src(), if (self.pitch_lock) "pitch" else "vinyl", .{
                .color_text = .{ .color = if (self.pitch_lock) Palette.green else Palette.secondary },
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

        const playing = index < self.grid.items.len and self.grid.items[index].playing;
        if (playing) {
            drawPauseBars(self.allocator, center_x, center_y, 5 * scale);
        } else {
            drawPlayTriangle(self.allocator, center_x, center_y, 6 * scale);
        }

        self.hit_map.append(rectFrom(rect), .{ .lane_play = index });
    }

    fn waveModeChip(self: *App) void {
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .margin = .{ .x = 8, .y = 4 },
            .padding = .{ .x = 10, .y = 2 },
            .background = true,
            .color_fill = .{ .color = Palette.field },
            .id_extra = 82,
        });
        defer chip.deinit();

        var buffer: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{s} {d:.0}ms", .{
            if (self.poly) "poly" else "bars",
            self.draw_ms,
        }) catch "mode";

        labelStyled(@src(), text, .{
            .color_text = .{ .color = Palette.secondary },
            .font = metaFont(),
            .id_extra = 83,
        });
        self.hit_map.append(rectFrom(chip.data().rectScaleFromParent().r), .wave_mode);
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

        labelStyled(@src(), if (self.anyPlaying()) "stop" else "play", .{
            .color_text = .{ .color = if (self.anyPlaying()) Palette.green else Palette.secondary },
            .font = metaFont(),
            .id_extra = 81,
        });
        self.hit_map.append(rectFrom(chip.data().rectScaleFromParent().r), .transport);
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
                const lane = &self.grid.items[slot];
                if (lane.playing) self.stopLane(slot);
                // Grab the wave: dragging right shows earlier audio.
                lane.beat_raw -= pull.dx * beats_visible / @max(1, lane.wave_w);
                snapBeat(lane);
                lane.manual = true;
                dvui.refresh(null, @src(), null);
            },
            .nav => |slot| {
                if (slot >= self.grid.items.len) return;
                const lane = &self.grid.items[slot];
                if (lane.playing) self.stopLane(slot);
                const total: f32 = @floatFromInt(totalBeats(lane));
                lane.beat_raw += pull.dx / @max(1, lane.nav_w) * total;
                snapLane(lane);
                lane.manual = false;
                dvui.refresh(null, @src(), null);
            },
            .filter => |slot| {
                if (slot >= self.grid.items.len) return;
                const lane = &self.grid.items[slot];
                lane.filter = std.math.clamp(lane.filter - pull.dy / @max(1, lane.filter_h), 0, 1);
                if (lane.playing) lane.filter_dirty = true;
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
                self.lanePlayButton(index);
            }

            {
                var wave = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .both,
                    .min_size_content = .{ .w = 0, .h = 0 },
                    .id_extra = 9100 + index,
                });
                defer wave.deinit();
                const full_rect = rectFrom(wave.data().contentRectScale().r).clipped(col_rect);
                const wave_rect = hit.Rect{
                    .x = full_rect.x,
                    .y = full_rect.y,
                    .w = @max(0, full_rect.w - 20),
                    .h = full_rect.h,
                };
                lane.wave_w = wave_rect.w;

                const view = self.laneStart(lane);
                if (lane.analysis) |*analysis| {
                    if (self.poly) {
                        self.paintWavePoly(analysis, wave_rect, view);
                    } else {
                        self.paintWave(analysis, wave_rect, view);
                    }
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

        }

        {
            const strip_rect = hit.Rect{
                .x = col_rect.x + col_rect.w - 18,
                .y = col_rect.y,
                .w = 18,
                .h = @max(0, col_rect.h - 24),
            };
            lane.filter_h = strip_rect.h;
            lane.filter_y = strip_rect.y;
            fillRect(self.allocator, strip_rect.x + 6, strip_rect.y, 6, strip_rect.h, fade(Palette.muted, 55));
            const knob_y = strip_rect.y + (1 - lane.filter) * @max(0, strip_rect.h - 12);
            fillRect(self.allocator, strip_rect.x + 2, knob_y, 14, 12, Palette.green);
            self.hit_map.append(strip_rect, .{ .filter = index });
        }

        {
            var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .min_size_content = .{ .w = 0, .h = 16 },
                .id_extra = 9300 + index,
            });
            defer bar.deinit();
            const bar_rect = rectFrom(bar.data().contentRectScale().r).clipped(col_rect);
            lane.nav_w = bar_rect.w;
            lane.nav_x = bar_rect.x;

            const total = totalBeats(lane);
            const visible: f32 = @min(beats_visible, @as(f32, @floatFromInt(total)));
            const window_start = @max(0, self.laneStart(lane));
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
    }

    /// Beat count of the lane's track, from its grid.
    fn totalBeats(lane: *const Lane) usize {
        const analysis = lane.analysis orelse return 0;
        return analysis.beats.len;
    }

    /// Waveform and beat lines, drawn straight into the lane's rectangle.
    fn paintWave(self: *App, analysis: *const pl.analysis.Analysis, rect: hit.Rect, start_beat: f32) void {
        if (rect.w <= 0 or rect.h <= 0) return;
        fillRect(self.allocator, rect.x, rect.y, rect.w, rect.h, Palette.field);

        const bpm = if (analysis.bpm() > 0) analysis.bpm() else 128;
        const scale: f32 = 255 / @as(f32, @floatFromInt(@max(1, analysis.peak)));
        const samples_per_beat: f32 = @as(f32, pl.analysis.Analysis.samples_per_second) * 60 / bpm;
        const start_sample = start_beat * samples_per_beat;
        const samples_per_px = samples_per_beat * beats_visible / rect.w;

        var builder = dvui.Path.Builder.init(self.allocator);
        defer builder.deinit();

        var x: f32 = 0;
        var smoothed: f32 = 0.35;
        while (x < rect.w) : (x += 6) {
            const from: usize = @intFromFloat(@max(0, start_sample + x * samples_per_px));
            if (from >= analysis.waveform.len) break;
            const to: usize = @min(analysis.waveform.len, @as(usize, @intFromFloat(@max(0, start_sample + (x + 3) * samples_per_px))));

            var peak: u8 = 0;
            var sum: usize = 0;
            for (analysis.waveform[from..to]) |value| {
                peak = @max(peak, value);
                sum += value;
            }
            const average = @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(@max(1, to - from)));
            const level = @min(255, @max(average * 1.15, @as(f32, @floatFromInt(peak)) * 0.6) * scale * 0.55) / 255;
            // Heavy smoothing along x turns per-column spikes into hills.
            smoothed = smoothed * 0.75 + level * 0.25;
            const height = rect.h * smoothed;
            fillRectInto(&builder, rect.x + x, rect.bottom() - height, 6, height, bandColor(smoothed));
        }

        self.paintBeats(rect, start_beat);
    }

    /// The same waveform as filled heat bands: five concave polygons per lane
    /// instead of hundreds of rectangles.
    fn paintWavePoly(self: *App, analysis: *const pl.analysis.Analysis, rect: hit.Rect, start_beat: f32) void {
        if (rect.w <= 0 or rect.h <= 0) return;
        fillRect(self.allocator, rect.x, rect.y, rect.w, rect.h, Palette.field);

        const bpm = if (analysis.bpm() > 0) analysis.bpm() else 128;
        const scale: f32 = 255 / @as(f32, @floatFromInt(@max(1, analysis.peak)));
        const samples_per_beat: f32 = @as(f32, pl.analysis.Analysis.samples_per_second) * 60 / bpm;
        const start_sample = start_beat * samples_per_beat;
        const step: f32 = 6;
        const samples_per_px = samples_per_beat * beats_visible / rect.w;

        var levels: [600]f32 = undefined;
        var count: usize = 0;
        var smoothed: f32 = 0.35;
        var x: f32 = 0;
        while (x < rect.w and count < levels.len) : (x += step) {
            const from: usize = @intFromFloat(@max(0, start_sample + x * samples_per_px));
            if (from >= analysis.waveform.len) break;
            const to: usize = @min(analysis.waveform.len, @as(usize, @intFromFloat(@max(0, start_sample + (x + step) * samples_per_px))));

            var peak: u8 = 0;
            var sum: usize = 0;
            for (analysis.waveform[from..to]) |value| {
                peak = @max(peak, value);
                sum += value;
            }
            const average = @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(@max(1, to - from)));
            const level = @min(255, @max(average * 1.15, @as(f32, @floatFromInt(peak)) * 0.6) * scale * 0.55) / 255;
            smoothed = smoothed * 0.75 + level * 0.25;
            levels[count] = smoothed;
            count += 1;
        }

        const bands: u8 = 5;
        var band: u8 = 0;
        while (band < bands) : (band += 1) {
            const lo = @as(f32, @floatFromInt(band)) / @as(f32, @floatFromInt(bands));
            const hi = @as(f32, @floatFromInt(band + 1)) / @as(f32, @floatFromInt(bands));

            var builder = dvui.Path.Builder.init(self.allocator);
            defer builder.deinit();

            const base_y = rect.bottom() - rect.h * lo;
            builder.addPoint(.{ .x = rect.x, .y = base_y });
            for (levels[0..count], 0..) |level, index| {
                const clamped = std.math.clamp(level, lo, hi);
                builder.addPoint(.{
                    .x = rect.x + @as(f32, @floatFromInt(index)) * step,
                    .y = rect.bottom() - rect.h * clamped,
                });
            }
            builder.addPoint(.{ .x = rect.x + @as(f32, @floatFromInt(count)) * step, .y = base_y });

            dvui.Path.fill(&.{builder.build()}, .{
                .color = .{ .color = bandColor((lo + hi) / 2) },
            });
        }

        self.paintBeats(rect, start_beat);
    }

    fn paintBeats(self: *App, rect: hit.Rect, start_beat: f32) void {
        var beat: f32 = @ceil(start_beat);
        while (beat < start_beat + beats_visible) : (beat += 1) {
            const bx = (beat - start_beat) / beats_visible * rect.w;
            const bar = @mod(@as(i32, @intFromFloat(beat)), 4) == 0;
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
            fillRectInto(&builder, rect.x + x, rect.bottom() - height, 6, height, bandColor(smoothed));
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
    app.player.toggle(track);
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
fn fade(color: dvui.Color, alpha: u8) dvui.Color {
    var dimmed = color;
    dimmed.a = alpha;
    return dimmed;
}

/// Pioneer's colour waveform in spirit: steady bass reads blue, transients push
/// the colour through orange towards white.
/// Heat map: quiet reads indigo, body red and orange, peaks yellow. The
/// waveform carries one amplitude byte, so loudness is the only information.
fn bandColor(level: f32) dvui.Color {
    const t = std.math.clamp(level, 0, 1);
    if (t < 0.25) return mixColor(Palette.heat0, Palette.heat1, t / 0.25);
    if (t < 0.5) return mixColor(Palette.heat1, Palette.heat2, (t - 0.25) / 0.25);
    if (t < 0.75) return mixColor(Palette.heat2, Palette.heat3, (t - 0.5) / 0.25);
    return mixColor(Palette.heat3, Palette.heat4, (t - 0.75) / 0.25);
}

fn mixColor(a: dvui.Color, b: dvui.Color, t: f32) dvui.Color {
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
fn fillRectInto(builder: *dvui.Path.Builder, x: f32, y: f32, w: f32, h: f32, color: dvui.Color) void {
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
fn frameLegend() void {
    const entries = [_]struct { severity: f32, text: []const u8 }{
        .{ .severity = 0, .text = "=" },
        .{ .severity = 0.3, .text = "+1" },
        .{ .severity = 0.6, .text = "+2" },
        .{ .severity = 0.85, .text = "+5" },
        .{ .severity = 1, .text = "x" },
    };

    for (entries, 0..) |entry, index| {
        var swatch = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .min_size_content = .{ .w = 10, .h = 10 },
            .margin = .{ .x = 6, .y = 8 },
            .background = true,
            .color_fill = .{ .color = rampColor(entry.severity) },
            .id_extra = 200 + index,
        });
        swatch.deinit();

        labelStyled(@src(), entry.text, .{
            .color_text = .{ .color = Palette.secondary },
            .font = metaFont(),
            .margin = .{ .y = 6 },
            .id_extra = 300 + index,
        });
    }
}

fn frameFooter(app: *App) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 40 },
        .padding = .{ .x = 20, .y = 6 },
        .background = true,
        .color_fill = .{ .color = Palette.panel },
    });
    defer bar.deinit();

    frameLegend();

    labelStyled(@src(), "energy", .{
        .color_text = .{ .color = Palette.muted },
        .font = metaFont(),
        .margin = .{ .x = 12, .y = 6 },
    });

    app.energyToggle("=", Palette.green, &app.filter_hold, .hold);
    app.energyToggle("↑", Palette.orange, &app.filter_up, .up);
    app.energyToggle("↓", Palette.orange, &app.filter_down, .down);
    app.notationToggle();
    app.frameBpmWindow();

    var spacer = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    spacer.deinit();

    app.transportToggle();

    var spacer2 = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    spacer2.deinit();

    app.waveModeChip();
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

const Palette = struct {
    /// One surface for the whole window: a second shade behind the canvas read
    /// as a box stretching to the edge.
    const background = dvui.Color{ .r = 0x1e, .g = 0x1f, .b = 0x27, .a = 0xff };
    const panel = dvui.Color{ .r = 0x1e, .g = 0x1f, .b = 0x27, .a = 0xff };
    const block = dvui.Color{ .r = 0x34, .g = 0x37, .b = 0x46, .a = 0xff };
    const selection = dvui.Color{ .r = 0x44, .g = 0x47, .b = 0x5a, .a = 0xff };
    const hover = dvui.Color{ .r = 0x3a, .g = 0x3d, .b = 0x4d, .a = 0xff };
    /// Heat ramp for loudness: deep indigo through red and orange to yellow.
    const heat0 = dvui.Color{ .r = 0x1a, .g = 0x1f, .b = 0x4b, .a = 0xff };
    const heat1 = dvui.Color{ .r = 0x6a, .g = 0x2c, .b = 0x8f, .a = 0xff };
    const heat2 = dvui.Color{ .r = 0xc0, .g = 0x3a, .b = 0x2b, .a = 0xff };
    const heat3 = dvui.Color{ .r = 0xf2, .g = 0x8f, .b = 0x24, .a = 0xff };
    const heat4 = dvui.Color{ .r = 0xff, .g = 0xd7, .b = 0x5e, .a = 0xff };
    const field = dvui.Color{ .r = 0x21, .g = 0x22, .b = 0x2c, .a = 0xff };
    const ink = dvui.Color{ .r = 0xf8, .g = 0xf8, .b = 0xf2, .a = 0xff };
    /// Dracula's own comment blue is about 3:1 on this background, which is too
    /// faint for anything but decoration. These two carry text.
    const secondary = dvui.Color{ .r = 0xc3, .g = 0xc7, .b = 0xd9, .a = 0xff };
    const muted = dvui.Color{ .r = 0x92, .g = 0x99, .b = 0xb8, .a = 0xff };
    const green = dvui.Color{ .r = 0x50, .g = 0xfa, .b = 0x7b, .a = 0xff };
    const yellow = dvui.Color{ .r = 0xf1, .g = 0xfa, .b = 0x8c, .a = 0xff };
    const orange = dvui.Color{ .r = 0xff, .g = 0xb8, .b = 0x6c, .a = 0xff };
    const purple = dvui.Color{ .r = 0xbd, .g = 0x93, .b = 0xf9, .a = 0xff };
    const red = dvui.Color{ .r = 0xff, .g = 0x55, .b = 0x55, .a = 0xff };

};
