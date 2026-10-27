//! The block canvas, the suggestion column, and the bottom bar.
//!
//! Layout follows one scale, so the eye reads the same rhythm everywhere:
//!   space  4 8 12 16 24
//!   type   meta 11 · body 13 · title 15
//! Colour is Dracula, one flat window surface, and the intensity ramp from
//! green (holds) through yellow and orange to red (clash).

const std = @import("std");
const dvui = @import("dvui");
const pl = @import("alchimix");
const dmt = @import("dmt.zig");
const geom = @import("geom.zig");
const hit = @import("hit.zig");
const lsd = @import("lsd.zig");
const mushroom = @import("mushroom.zig");
const playlists = @import("playlists.zig");
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
    if (a.rank != b.rank) return a.rank < b.rank;
    return a.total < b.total;
}

pub fn shortName(name: []const u8, buffer: *[32]u8) []const u8 {
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

/// The drift look. One at a time: both warp the whole frame from the same
/// capture, so the second would paint over the first.
pub const Look = enum { none, drift, mushroom };

/// What the frame is drawn through. A look and a fold can run at once; DMT then
/// folds the frame the look has already bent.
pub const Effect = struct {
    look: Look = .none,
    dmt: Dmt = .off,

    pub fn any(self: Effect) bool {
        return self.look != .none or self.dmt != .off;
    }

};

pub const Dmt = enum { off, plain };

/// Lane indices for remembered tracks the crate still holds, oldest first.
pub fn rememberedLanes(remembered: []const u64, lanes: []const u64, out: *[Played.limit]usize) usize {
    var count: usize = 0;
    for (remembered) |track_id| {
        out[count] = std.mem.indexOfScalar(u64, lanes, track_id) orelse continue;
        count += 1;
    }
    return count;
}

/// The last few tracks that started, oldest first. Global play replays them.
pub const Played = struct {
    pub const limit = 4;

    ids: [limit]u64 = @splat(0),
    count: usize = 0,

    /// Moves `id` to the newest slot, dropping the oldest track when full.
    pub fn remember(self: *Played, id: u64) void {
        var kept: usize = 0;
        for (self.ids[0..self.count]) |seen| {
            if (seen == id) continue;
            self.ids[kept] = seen;
            kept += 1;
        }
        self.count = kept;

        if (self.count == limit) {
            std.mem.copyForwards(u64, self.ids[0 .. limit - 1], self.ids[1..limit]);
            self.count = limit - 1;
        }

        self.ids[self.count] = id;
        self.count += 1;
    }

    pub fn items(self: *const Played) []const u64 {
        return self.ids[0..self.count];
    }
};

/// Pressing a mode's chip runs it; pressing the one already running stops it,
/// and pressing the other swaps instead of stopping.
fn pressed(current: Dmt, choice: Dmt) Dmt {
    return if (current == choice) .off else choice;
}

pub const EffectMode = enum { lsd, mushroom, dmt };

/// The bundled emoji family, loaded at startup.
pub const emoji_family = "noto emoji";
/// Loaded from the system at startup; Courier is what the art was drawn for.
pub const garden_family = "garden";

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    library: pl.library.Library,
    player: pl.player.Player,
    mixer: *pl.mixer.Mixer,
    transport: pl.transport.Transport,
    crate: pl.crate.Crate,

    /// The playlist column: the library's playlists and this crate's saves.
    playlist_column: playlists.Panel = .{},
    /// Lanes inside the canvas viewport this frame; global transport uses them
    /// once more than four tracks are loaded.
    lane_rects: [64]hit.Rect = undefined,
    lane_drawn: [64]bool = @splat(false),
    lane_count: usize = 0,
    /// Full row rectangles from the last frame, unclipped, for drop gaps.
    block_rects: [256]hit.Rect = undefined,
    block_count: usize = 0,
    lane_right: f32 = 0,
    /// Tracks that started lately; the transport button replays them.
    played: Played = .{},
    /// Crate autoplay: the lane it is pulling through, the track it left there
    /// so a restart resumes it, and whether the next frame should scroll to it.
    autoplay_on: bool = false,
    autoplay_index: usize = 0,
    autoplay_track: u64 = 0,
    autoplay_show: bool = false,
    /// The mushroom undergrowth: plants, rain and rings.
    mushroom: mushroom.State = .{},
    /// A text field held the keyboard last frame, so space is a space.
    typing: bool = false,
    /// The bundled emoji font loaded, so the garden can draw real glyphs.
    emoji_font: bool = false,
    /// A terminal mono loaded, so the ASCII art keeps its grid.
    garden_font: bool = false,
    /// A preview waiting for the next master bar so it lands in sync.
    preview_pending: ?Track = null,
    preview_at_ns: i128 = 0,

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
    beats_visible: u8 = 32,
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

    /// Which effects the frame is drawn through. The copy lives in
    /// `effect_target`; the chips' rects are the patches every effect leaves
    /// alone.
    effect: Effect = .{},
    effect_target: ?dvui.Texture.Target = null,
    /// LSD's output while DMT folds it. Only allocated when both run.
    lsd_target: ?dvui.Texture.Target = null,
    /// The frame's coloured fills, kept while DMT runs.
    colour_target: ?dvui.Texture.Target = null,
    /// What DMT paints back through the fold: each lane's wash first, then its
    /// waveform fills, in the order they were drawn.
    colours: std.ArrayListUnmanaged(geom.Quad) = .empty,
    /// Effect seconds: wall seconds scaled by tempo and the speed slider. LSD
    /// reads it straight; DMT integrates it through its mood.
    effect_time: f64 = 0,
    effect_last_ns: i128 = 0,
    effect_clock: dmt.Clock = .{},
    /// The pinned look's own clock: tempo only, so the speed slider leaves it
    /// exactly as it was.
    /// Shared effect speed multiplier, under both mode chips.
    effect_speed: f32 = 1,
    /// Rings per e-fold of radius: how many lanes the tunnel shows.
    lane_rings: f32 = dmt.rings_default,
    /// The lane count wanders on its own: a goal drawn every few seconds and
    /// eased towards, so the tunnel thickens and thins without a jump.
    lane_wander: f32 = 0,
    lane_goal: f32 = 0,
    lane_wait: f32 = 0,
    lane_rng: std.Random.DefaultPrng = .init(0x1a4e_5eed),
    /// The same wander for the virtual window: it breathes in and out on its
    /// own, as a fraction of the scale the slider set.
    window_wander: f32 = 0,
    window_goal: f32 = 0,
    window_wait: f32 = 0,
    window_rng: std.Random.DefaultPrng = .init(0x7a11_0eed),
    /// Gaussian-ish blur on the window, 0 to 1. The bottom of the slider is no
    /// blur at all.
    blur: f32 = 0,
    blur_target: ?dvui.Texture.Target = null,
    /// How far the window may wander from the scale the slider set: the same
    /// role `lane_wander_limit` plays for the ring count, but adjustable.
    window_wander_limit: f32 = 0.45,
    /// How far the fold leans on colour rather than the frame: the shade it
    /// dims to, the wash under the lanes, the share of the fills painted back
    /// and the chroma they are pushed to all follow it.
    lane_colour: f32 = 0.6,
    /// How many kaleidoscope facets the tunnel is folded into.
    lane_mirrors: f32 = 4,
    /// Scale of the virtual window the tunnel is laid out on: one is the
    /// window DMT was switched on in. A later resize leaves the effect alone.
    virtual_scale: f32 = 1,
    /// The real window's size when DMT was switched on, before the slider
    /// scales it.
    virtual_base: dvui.Size.Physical = .{ .w = 1180, .h = 720 },

    /// The kick driving the lane pulse, and the follower that shapes it.
    heartbeat: bool = true,
    beat_power: f32 = 0,
    /// Sound stops on the beat each lane reached and the effect clock holds.
    paused: bool = false,
    // Six effect chips, the speed slider, the garden panel and its chrome all
    // want a slot, so the list is sized for the panel too.
    stills: [24]dvui.Rect.Physical = @splat(.{}),
    still_count: usize = 0,

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
    /// Toolbar, the speed row under the chips, and the footer. Measured once and
    /// fixed: reading them back made a resize lag a frame and flicker.
    const chrome_height: f32 = 236;

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
        app.playlist_column.rows = library.playlists() catch &.{};
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
        self.playlist_column.deinit(self.allocator);
        self.crate.deinit();
    }

    /// Re-run the search, then rank what could follow the selection, or the
    /// seed when nothing is selected.
    pub fn refresh(self: *App) !void {
        self.found = self.library.search(self.query.items) catch &.{};

        self.allocator.free(self.ranked);
        self.ranked = &.{};

        var seeds: [3]Track = undefined;
        var count: usize = 0;
        for (self.selected.items) |index| {
            const track = self.crate.at(index) orelse continue;
            seeds[count] = track.*;
            count += 1;
            if (count == seeds.len) break;
        }
        if (count == 0) {
            if (self.crate.seedTrack()) |seed| {
                seeds[0] = seed.*;
                count = 1;
            }
        }
        if (count == 0) return;

        const tolerance_percent: f64 = @floatCast(self.bpm_pct);
        self.ranked = try pl.suggest.rankFor(self.allocator, seeds[0..count], self.found, .{
            .tolerance_percent = tolerance_percent,
        });
        self.in_range = self.ranked.len;
        if (self.sort_by_bpm) std.mem.sort(Candidate, self.ranked, {}, byBpmDesc);

        // A track already in the crate is not a suggestion.
        if (self.ranked.len > 0 and self.crate.len() > 0) {
            var kept: std.ArrayListUnmanaged(Candidate) = .empty;
            for (self.ranked) |candidate| {
                if (self.inCrate(candidate.track.id)) continue;
                kept.append(self.allocator, candidate) catch break;
            }
            self.allocator.free(self.ranked);
            self.ranked = kept.toOwnedSlice(self.allocator) catch &.{};
            self.in_range = self.ranked.len;
        }
    }

    fn inCrate(self: *const App, id: u64) bool {
        for (0..self.crate.len()) |index| {
            const track = self.crate.at(index) orelse continue;
            if (track.id == id) return true;
        }
        return false;
    }

    pub fn frame(self: *App) bool {
        // The whole frame has to exist before it can be warped, so while the
        // mode runs it is drawn into an offscreen copy and blitted back.
        self.colours.clearRetainingCapacity();
        if (!self.paused) {
            self.driftLanes();
            self.driftWindow();
            self.pulseKick();
        }
        const previous = self.capture();

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
        self.advanceAutoplay();
        self.advanceEffects();

        if (self.preview_pending) |track| {
            if (self.transport.nowNs() >= self.preview_at_ns) {
                self.preview_pending = null;
                const tempo: f32 = if (track.bpm > 0) self.masterBpm() / @as(f32, @floatCast(track.bpm)) else 1;
                self.player.play(track, tempo);
            }
        }

        // The pointer pass reads the map the previous frame drew, then the map
        // is rebuilt from this frame's layout.
        self.handleEvents();
        self.typing = false;
        self.syncGrid();

        self.hit_map.reset();

        frameToolbar(self);
        self.frameBody();
        frameFooter(self);
        self.drawGhost();

        if (self.pending_select) |index| {
            self.pending_select = null;
            self.crate.setSeed(index);
            self.selected.clearRetainingCapacity();
            self.query.clearRetainingCapacity();
            self.refresh() catch {};
            dvui.refresh(null, @src(), null);
        }

        self.paint(previous);
        return true;
    }

    /// Offscreen copy for this frame, or null when the mode is off. The target
    /// outlives the frame so the mode does not allocate one per frame.
    fn capture(self: *App) ?dvui.RenderTarget {
        if (!self.effect.any()) return null;

        const rect = dvui.currentWindow().rect_pixels;
        const width: u32 = @intFromFloat(@max(1, @floor(rect.w)));
        const height: u32 = @intFromFloat(@max(1, @floor(rect.h)));

        if (self.effect_target) |target| {
            if (target.width != width or target.height != height) {
                target.destroyLater();
                self.effect_target = null;
            }
        }
        if (self.effect_target == null) {
            // A backend without drawable textures leaves the mode off rather
            // than failing the frame.
            self.effect_target = dvui.Texture.Target.create(.{ .width = width, .height = height }) catch {
                self.dropEffects();
                return null;
            };
        }

        // A texture target starts its render pass with a clear, so nothing is
        // painted over the previous frame in the copy.
        const target = self.effect_target.?;
        return dvui.RenderTarget.setAsCurrent(.{ .texture = target, .offset = .{} });
    }

    /// Puts the frame back on screen through the effects, then gives rendering
    /// back to the screen so anything drawn later is not captured.
    fn paint(self: *App, previous: ?dvui.RenderTarget) void {
        // The screen is the target again before anything else: leaving the
        // drawable set to a texture that is about to be destroyed freezes the
        // window on the last frame that reached it.
        const restored = previous orelse return;
        _ = dvui.RenderTarget.setAsCurrent(restored);

        const target = self.effect_target orelse return;
        self.blit(target, restored) catch {
            // The frame is already in the copy, so a blit that fails leaves the
            // window frozen unless the modes give way to plain rendering.
            self.dropEffects();
        };
    }

    /// Copies the frame into a smaller target. Reading that copy back over the
    /// whole window is what softens it: one bilinear step for each pixel of the
    /// downsample, so the slider's bottom is untouched and the top is a smear.
    fn blurred(self: *App, arena: std.mem.Allocator, texture: dvui.Texture, size: dvui.Size.Physical, screen: dvui.RenderTarget) !dvui.Texture {
        const factor = 1 + self.blur * (blur_max - 1);
        const small = dvui.Size.Physical{
            .w = @max(1, @round(size.w / factor)),
            .h = @max(1, @round(size.h / factor)),
        };
        const target = try sizedTarget(&self.blur_target, small);
        _ = dvui.RenderTarget.setAsCurrent(.{ .texture = target, .offset = .{} });
        // The clip is still the window's, and the target is smaller; drawing
        // with the larger scissor trips SDL's assertion.
        dvui.clipSet(.{ .x = 0, .y = 0, .w = small.w, .h = small.h });
        errdefer _ = dvui.RenderTarget.setAsCurrent(screen);
        const mesh = try geom.quadMesh(arena, .{ .x = 0, .y = 0, .w = small.w, .h = small.h }, small);
        try dvui.renderTriangles(.{
            .vertexes = mesh.vertexes,
            .indices = mesh.indices,
            .bounds = .{ .x = 0, .y = 0, .w = small.w, .h = small.h },
        }, texture);
        _ = dvui.RenderTarget.setAsCurrent(screen);
        dvui.clipSet(dvui.currentWindow().rect_pixels);
        return dvui.textureFromTarget(target);
    }

    fn blit(self: *App, target: dvui.Texture.Target, screen: dvui.RenderTarget) !void {
        const texture = try dvui.textureFromTarget(target);
        const rect = dvui.currentWindow().rect_pixels;
        const arena = dvui.currentWindow().arena();
        const size = dvui.Size.Physical{ .w = rect.w, .h = rect.h };
        const stills = self.stillRects();
        dvui.clipSet(rect);

        // Both modes: LSD lands in its own copy, and DMT folds that copy, so
        // the drift stays underneath the tunnel instead of being painted over.
        var source = texture;
        if (self.effect.look != .none and self.effect.dmt != .off) {
            const under = try self.driftTarget(size);
            _ = dvui.RenderTarget.setAsCurrent(.{ .texture = under, .offset = .{} });
            // A failed drift draw must not leave the window drawing into the
            // throwaway copy, or the screen stays frozen when the modes drop.
            errdefer _ = dvui.RenderTarget.setAsCurrent(screen);
            try self.drawLook(texture, arena, size, stills);
            _ = dvui.RenderTarget.setAsCurrent(screen);
            source = try dvui.textureFromTarget(under);
        } else if (self.effect.look != .none) {
            try self.drawLook(texture, arena, size, stills);
        }

        if (self.blur > 0) source = try self.blurred(arena, source, size, screen);

        if (self.effect.dmt != .off) {
            try dmt.draw(source, arena, self.effect_clock, size, self.foldCanvas(), stills, self.foldShade(), 0, self.foldShape());
            try self.paintColours(arena, screen, size);
            // The colour pass folds the whole layer, so the controls come back
            // over it rather than being painted with lane colour.
            try geom.repaint(arena, stills, size, texture);

        }
    }

    fn drawLook(self: *App, texture: dvui.Texture, arena: std.mem.Allocator, size: dvui.Size.Physical, stills: []const dvui.Rect.Physical) !void {
        switch (self.effect.look) {
            // Only the fold pins the controls; the drift carries them with the
            // rest of the frame.
            .drift => try lsd.draw(texture, arena, self.effect_time, size, if (self.effect.dmt == .off) &.{} else stills),
            .mushroom => try mushroom.draw(texture, arena, &self.mushroom, self.effect_time, size, stills, self.masterBpm(), self.gardenType()),
            .none => {},
        }
    }

    /// The coloured fills, folded through the same map and laid over the
    /// dimmed frame. They are kept apart from the source so the drift, when it
    /// runs underneath, cannot chew them up on its own coarser grid.
    fn paintColours(self: *App, arena: std.mem.Allocator, screen: dvui.RenderTarget, size: dvui.Size.Physical) !void {
        if (self.colours.items.len == 0) return;

        const layer = try sizedTarget(&self.colour_target, size);
        _ = dvui.RenderTarget.setAsCurrent(.{ .texture = layer, .offset = .{} });
        errdefer _ = dvui.RenderTarget.setAsCurrent(screen);

        const quads = try geom.solidQuads(arena, self.colours.items);
        try dvui.renderTriangles(.{
            .vertexes = quads.vertexes,
            .indices = quads.indices,
            .bounds = .{ .x = 0, .y = 0, .w = size.w, .h = size.h },
        }, null);

        _ = dvui.RenderTarget.setAsCurrent(screen);
        const layer_texture = try dvui.textureFromTarget(layer);
        try dmt.draw(layer_texture, arena, self.effect_clock, size, self.foldCanvas(), &.{}, 1, 0, self.foldShape());
    }

    /// LSD's output copy, kept for as long as both modes run.
    fn driftTarget(self: *App, size: dvui.Size.Physical) !dvui.Texture.Target {
        return sizedTarget(&self.lsd_target, size);
    }

    /// What the DMT sliders and shape chips set.
    fn foldShape(self: *const App) dmt.FoldShape {
        return .{
            .ring_count = self.drawnRings(),
            .heart = self.beat_power,
            .mirrors = self.lane_mirrors,
        };
    }

    /// The virtual window the tunnel's geometry is laid out on.
    fn foldCanvas(self: *const App) dvui.Size.Physical {
        const swell = @max(0.2, 1 + self.window_wander + self.beat_power * dmt.window_pump);
        return dmt.virtualSize(self.virtual_base, self.virtual_scale * swell);
    }

    /// The window's size in physical pixels, for the effects.
    fn currentSize() dvui.Size.Physical {
        const rect = dvui.currentWindow().rect_pixels;
        return .{ .w = rect.w, .h = rect.h };
    }

    fn dropEffects(self: *App) void {
        self.effect = .{};
        // The copies are only worth their memory while a mode runs.
        if (self.effect_target) |target| target.destroyLater();
        self.effect_target = null;
        if (self.colour_target) |target| target.destroyLater();
        self.colour_target = null;
        if (self.lsd_target) |target| target.destroyLater();
        self.lsd_target = null;
        if (self.blur_target) |target| target.destroyLater();
        self.blur_target = null;
        dvui.refresh(null, @src(), null);
    }

    fn toggleEffect(self: *App, which: EffectMode) void {
        switch (which) {
            .lsd => self.effect.look = if (self.effect.look == .drift) .none else .drift,
            .mushroom => self.effect.look = if (self.effect.look == .mushroom) .none else .mushroom,
            .dmt => {
                self.effect.dmt = pressed(self.effect.dmt, .plain);
                // The window that DMT starts in is the virtual window at
                // scale one: the fold it drew before the slider existed.
                if (self.effect.dmt != .off) self.virtual_base = currentSize();
            },
        }
        if (!self.effect.any()) {
            self.dropEffects();
            return;
        }
        dvui.refresh(null, @src(), null);
    }

    /// Escape in LSD, mushroom or DMT: back to the plain view, transport
    /// untouched.
    fn clearEffects(self: *App) void {
        self.effect.look = .none;
        self.effect.dmt = .off;
        self.dropEffects();
    }

    /// The patches the effects leave alone: the mode chips, in physical pixels,
    /// with a pixel of margin so their borders are not pulled either.
    fn stillRects(self: *const App) []const dvui.Rect.Physical {
        return self.stills[0..self.still_count];
    }

    /// Keeps a rect out of the effect, with a pixel of margin so its border is
    /// not pulled either.
    fn still(self: *App, rect: hit.Rect) void {
        if (self.still_count >= self.stills.len) return;
        self.stills[self.still_count] = .{
            .x = rect.x - 1,
            .y = rect.y - 1,
            .w = rect.w + 2,
            .h = rect.h + 2,
        };
        self.still_count += 1;
    }

    fn frameToolbar(self: *App) void {
        {
            var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .padding = .{ .x = 16, .y = 8 },
                .background = true,
                .color_fill = .{ .color = Palette.background },
            });
            defer bar.deinit();

            labelStyled(@src(), "alchimix", .{
                .font = titleFont(),
                .color_text = .{ .color = Palette.purple },
                .margin = .{ .x = 4 },
            });

            var modes = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1, .gravity_y = 0.5 });
            defer modes.deinit();

            self.still_count = 0;
            self.effectChip("LSD", .lsd, .lsd, 7120);
            self.effectChip(if (self.emoji_font) "🍄" else ".-.", .mushroom, .mushroom, 7122);
            self.effectChip("DMT", .dmt, .dmt, 7125);
            if (self.effect.look == .mushroom) self.growChip();
        }

        self.effectSpeed();
    }

    /// One press grows the plant a stage, so the growth halos can be watched
    /// without waiting out a season.
    fn growChip(self: *App) void {
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_y = 0.5,
            .margin = .{ .x = 3 },
            .padding = .{ .x = 8, .y = 0 },
            .min_size_content = .{ .h = 24 },
            .background = true,
            .color_fill = .{ .color = Palette.field },
            .corners = square,
            .id_extra = 7160,
        });
        defer chip.deinit();

        labelStyled(@src(), "grow", .{
            .gravity_y = 0.5,
            .color_text = .{ .color = Palette.heat4 },
            .font = metaFont(),
            .id_extra = 7161,
        });

        const rect = rectFrom(chip.data().contentRectScale().r);
        self.still(rect);
        self.hit_map.append(rect, .grow_plant);
    }

    /// Speed for both effects on its own row under the chips, and the lane
    /// count on the row below while the fold runs. The block is held out of the
    /// fold, so neither slider ever moves under the pointer.
    fn effectSpeed(self: *App) void {
        var column = dvui.box(@src(), .{ .dir = .vertical }, .{
            .gravity_x = 1,
            .padding = .{ .x = 16, .y = 0 },
            .id_extra = 7230,
        });
        defer column.deinit();

        if (self.effect.any()) {
            if (self.sliderRow("speed", dmt.speedFraction(self.effect_speed), 7240)) |fraction| {
                self.effect_speed = dmt.speedAt(fraction);
                dvui.refresh(null, @src(), null);
            }
        }

        if (self.effect.dmt != .off) {
            if (self.sliderRow("wander", dmt.wanderFraction(self.window_wander_limit), 7247)) |fraction| {
                self.window_wander_limit = dmt.wanderAt(fraction);
                dvui.refresh(null, @src(), null);
            }

            if (self.sliderRow("window", dmt.virtualFraction(self.virtual_scale), 7270)) |fraction| {
                self.virtual_scale = dmt.virtualAt(fraction);
                dvui.refresh(null, @src(), null);
            }

            if (self.sliderRow("lanes", dmt.ringsFraction(self.lane_rings), 7250)) |fraction| {
                self.lane_rings = dmt.ringsAt(fraction);
                dvui.refresh(null, @src(), null);
            }

            if (self.sliderRow("colour", self.lane_colour, 7260)) |fraction| {
                self.lane_colour = fraction;
                dvui.refresh(null, @src(), null);
            }

            if (self.sliderRow("blur", self.blur, 7248)) |fraction| {
                self.blur = fraction;
                dvui.refresh(null, @src(), null);
            }

            if (self.sliderRow("mirror", dmt.mirrorsFraction(self.lane_mirrors), 7280)) |fraction| {
                self.lane_mirrors = dmt.mirrorsAt(fraction);
                dvui.refresh(null, @src(), null);
            }

            self.effectChips();
        }

        self.still(rectFrom(column.data().borderRectScale().r));
    }

    /// The kick pulse and the pause switch, side by side under the colour
    /// slider.
    fn effectChips(self: *App) void {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_x = 1,
            .margin = .{ .y = 2 },
            .id_extra = 7290,
        });
        defer row.deinit();

        self.heartbeatChip();
        self.pauseChip();
    }

    /// The kick pulse switch, left of the pause chip.
    fn heartbeatChip(self: *App) void {
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_y = 0.5,
            .margin = .{ .x = 2 },
            .padding = .{ .x = 8, .y = 2 },
            .background = true,
            .color_fill = .{ .color = if (self.heartbeat) Palette.selection else Palette.field },
            .corners = square,
            .id_extra = 7270,
        });
        defer chip.deinit();

        labelStyled(@src(), "heartbeat", .{
            .gravity_y = 0.5,
            .color_text = .{ .color = if (self.heartbeat) Palette.heat4 else Palette.muted },
            .font = metaFont(),
            .id_extra = 7271,
        });

        self.hit_map.append(rectFrom(chip.data().contentRectScale().r), .heartbeat);
    }

    /// Silences every lane and holds the effect, or lets both run again.
    fn pauseChip(self: *App) void {
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_y = 0.5,
            .margin = .{ .x = 2 },
            .padding = .{ .x = 8, .y = 2 },
            .background = true,
            .color_fill = .{ .color = if (self.paused) Palette.selection else Palette.field },
            .corners = square,
            .id_extra = 7272,
        });
        defer chip.deinit();

        labelStyled(@src(), "pause", .{
            .gravity_y = 0.5,
            .color_text = .{ .color = if (self.paused) Palette.heat4 else Palette.muted },
            .font = metaFont(),
            .id_extra = 7273,
        });

        self.hit_map.append(rectFrom(chip.data().contentRectScale().r), .pause);
    }

    /// Eases the lane count towards a fresh goal every few seconds. The wander
    /// is folded into the slider's value rather than replacing it, so the knob
    /// still says where the tunnel sits.
    fn driftLanes(self: *App) void {
        const delta = std.math.clamp(dvui.currentWindow().secs_since_last_frame, 0, 0.25);
        self.lane_wait -= delta;
        if (self.lane_wait <= 0) {
            self.lane_goal = (self.lane_rng.random().float(f32) - 0.5) * 2 * lane_wander_limit;
            self.lane_wait = 5 + self.lane_rng.random().float(f32) * 6;
        }
        const ease = 1 - @exp(-delta / lane_wander_ease);
        self.lane_wander += (self.lane_goal - self.lane_wander) * ease;
    }

    /// The same wander as the lane count, applied to the virtual window: a
    /// goal every few seconds, eased towards, so the tunnel breathes.
    fn driftWindow(self: *App) void {
        const delta = std.math.clamp(dvui.currentWindow().secs_since_last_frame, 0, 0.25);
        self.window_wait -= delta;
        if (self.window_wait <= 0) {
            self.window_goal = (self.window_rng.random().float(f32) - 0.5) * 2 * self.window_wander_limit;
            self.window_wait = 5 + self.window_rng.random().float(f32) * 6;
        }
        const ease = 1 - @exp(-delta / lane_wander_ease);
        self.window_wander += (self.window_goal - self.window_wander) * ease;
    }

    /// The lane count the fold is actually drawn at.
    fn drawnRings(self: *const App) f32 {
        return drawnRingsFor(self.lane_rings, self.lane_wander);
    }

    /// Turns the mix's bass into one pulse: instant attack, a decay of about a
    /// fifth of a second, and the loudest low band across the lanes.
    fn pulseKick(self: *App) void {
        const delta = std.math.clamp(dvui.currentWindow().secs_since_last_frame, 0, 0.25);
        if (!self.heartbeat) {
            self.beat_power = 0;
            return;
        }

        var spectrum: [pl.mixer.spectrum_bins]f32 = @splat(0);
        var bass: f32 = 0;
        for (0..self.lane_count) |index| {
            self.transport.spectrum(index, &spectrum);
            for (spectrum[0..kick_bins]) |band| bass = @max(bass, band);
        }
        self.beat_power = beatFollow(self.beat_power, bass, delta);
    }

    /// A label with a slider hard against the right edge. Returns the new
    /// position only when it moved.
    fn sliderRow(self: *App, text: []const u8, start: f32, id: u32) ?f32 {
        _ = self;
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1, .id_extra = id });
        defer row.deinit();

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        labelStyled(@src(), text, .{
            .font = metaFont(),
            .color_text = .{ .color = Palette.muted },
            .gravity_y = 0.5,
            .margin = .{ .x = 4 },
            .id_extra = id + 1,
        });

        var fraction = start;
        const moved = dvui.slider(@src(), .{ .fraction = &fraction }, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 120, .h = 8 },
            .max_size_content = .{ .w = 120, .h = 8 },
            .id_extra = id + 2,
        });
        return if (moved) fraction else null;
    }

    /// A mode switch. `paint` reads the chip's rect back and keeps that patch of
    /// window untouched, so the chip never moves out from under the cursor.
    fn effectChip(self: *App, text: []const u8, which: EffectMode, target: hit.Target, id: u32) void {
        const on = switch (which) {
            .lsd => self.effect.look == .drift,
            .mushroom => self.effect.look == .mushroom,
            .dmt => self.effect.dmt == .plain,
        };
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_y = 0.5,
            .margin = .{ .x = 3 },
            .padding = .{ .x = 8, .y = 0 },
            .min_size_content = .{ .h = 24 },
            .background = true,
            .color_fill = .{ .color = if (on) Palette.purple else Palette.field },
            .corners = square,
            .id_extra = id,
        });
        defer chip.deinit();

        labelStyled(@src(), text, .{
            .gravity_y = 0.5,
            .color_text = .{ .color = if (on) Palette.background else Palette.muted },
            .font = if (self.emoji_font and which == .mushroom) self.emojiType(metaFont().size) else metaFont(),
            .id_extra = id + 1,
        });

        const rect = rectFrom(chip.data().rectScaleFromParent().r);
        self.still(rect);
        self.hit_map.append(rect, target);
    }

    /// Orders the suggestions by BPM. Dim and inert until there are any.
    fn sortButton(self: *App) void {
        const enabled = self.ranked.len > 0;
        const active = enabled and self.sort_by_bpm;
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .min_size_content = .{ .w = 56, .h = 24 },
            .gravity_y = 0.5,
            .margin = .{ .x = 4, .y = 0 },
            .padding = .{ .x = 5, .y = 0 },
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
            .margin = .{ .x = 12, .y = 0 },
            .padding = .{ .x = 2, .y = 0 },
            .gravity_y = 0.5,
            .background = true,
            .color_fill = .{ .color = Palette.field },
            .id_extra = 95,
        });
        defer group.deinit();

        for (hit.widths, 0..) |beats, slot| {
            const active = self.beats_visible == beats;
            var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .min_size_content = .{ .w = 34, .h = 24 },
                .margin = .{ .x = 1, .y = 0 },
                .background = true,
                .color_fill = .{ .color = if (active) Palette.green else Palette.field },
                .id_extra = 96 + slot,
            });
            defer cell.deinit();

            var buffer: [4]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "{d}", .{beats}) catch "";
            labelStyled(@src(), text, .{
                .expand = .both,
                .color_text = .{ .color = if (active) Palette.background else Palette.secondary },
                .font = metaFont(),
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .id_extra = 100 + slot,
            });
            self.hit_map.append(rectFrom(cell.data().contentRectScale().r), .{ .width = beats });
        }
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
        self.playlist_column.frame(self);
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
        if (self.crate.seedTrack() != null or self.selected.items.len > 0) return .suggest;
        return .browse;
    }

    fn framePickerHeading(self: *App) void {
        var text_buffer: [128]u8 = undefined;
        var text: []const u8 = "";
        if (self.mode() != .suggest) {
            text = switch (self.mode()) {
                .search => "Search results",
                .browse => "Pick a seed",
                .suggest => "",
            };
        } else if (self.selected.items.len > 0) {
            if (self.selected.items.len == 1) {
                if (self.crate.at(self.selected.items[0])) |track| {
                    var title_buffer: [34]u8 = undefined;
                    text = std.fmt.bufPrint(&text_buffer, "Next to {s}", .{clippedTitle(track.title, &title_buffer)}) catch "Next to";
                } else {
                    text = "Next to";
                }
            } else {
                text = std.fmt.bufPrint(&text_buffer, "Next to {d} tracks", .{self.selected.items.len}) catch "Next to";
            }
        } else if (self.crate.seedTrack()) |seed| {
            var title_buffer: [34]u8 = undefined;
            text = std.fmt.bufPrint(&text_buffer, "Next to {s}", .{clippedTitle(seed.title, &title_buffer)}) catch "Next to";
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
        self.noteTyping(entry.data().id);
        const typed = entry.text_changed;
        entry.deinit();
        if (typed) self.refresh() catch {};
    }

    /// Tempo window in percent: the list keeps tracks within this much of each
    /// seed's BPM.
    pub fn frameBpmWindow(self: *App) void {
        if (self.bpm_text.items.len == 0) {
            self.bpm_text.append(self.allocator, '5') catch {};
        }

        labelStyled(@src(), "bpm ±", .{
            .gravity_y = 0.5,
            .color_text = .{ .color = Palette.muted },
            .font = metaFont(),
            .margin = .{ .x = 4, .y = 0 },
            .id_extra = 7100,
        });

        var entry = dvui.textEntry(@src(), .{
            .text = .{ .array_list = .{ .backing = &self.bpm_text, .allocator = self.allocator } },
        }, .{
            .min_size_content = .{ .w = 40, .h = 18 },
            .padding = .{ .x = 5, .y = 3 },
            .margin = .{ .x = 2, .y = 0 },
            .gravity_y = 0.5,
            .corners = square,
            .background = true,
            .color_fill = .{ .color = Palette.field },
            .color_text = .{ .color = Palette.ink },
            .font = metaFont(),
            .id_extra = 7101,
        });
        self.noteTyping(entry.data().id);
        const changed = entry.text_changed;
        entry.deinit();

        var count_buffer: [24]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buffer, "{d} in range", .{self.in_range}) catch "";
        labelStyled(@src(), count, .{
            .gravity_y = 0.5,
            .color_text = .{ .color = Palette.muted },
            .font = metaFont(),
            .margin = .{ .x = 6, .y = 0 },
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
            .min_size_content = .{ .w = 30, .h = 24 },
            .gravity_y = 0.5,
            .margin = .{ .x = 3, .y = 0 },
            .padding = .{ .x = 4, .y = 0 },
            .data_out = &widget,
            .id_extra = @backingInt(toggle) + 1,
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
            .margin = .{ .x = 12, .y = 0 },
            .padding = .{ .x = 8, .y = 0 },
            .min_size_content = .{ .h = 24 },
            .gravity_y = 0.5,
            .background = true,
            .color_fill = .{ .color = Palette.field },
            .id_extra = 90,
        });
        defer chip.deinit();

        var buffer: [16]u8 = undefined;
        const sample = if (self.note_names) "Am" else "8A";
        const text = std.fmt.bufPrint(&buffer, "key {s}", .{sample}) catch "key";

        labelStyled(@src(), text, .{
            .gravity_y = 0.5,
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
        // The plant stands at the canvas's right edge, clear of the playlists.
        const canvas_rect = rectFrom(canvas.data().borderRectScale().r);
        const frame_width: f32 = @max(1, dvui.currentWindow().rect_pixels.w);
        mushroom.placePlant((canvas_rect.x + canvas_rect.w * 0.88) / frame_width);
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
        // Rows scroll under the footer; their rects stop at the canvas so a
        // press on the bar is not taken by a lane behind it.
        self.hit_map.clip = self.canvas;

        for (0..self.crate.len()) |index| {
            const track = self.crate.at(index).?;
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .id_extra = 8000 + index,
                });
                defer row.deinit();

                if (self.autoplay_show and index == self.autoplay_index) {
                    dvui.scrollTo(.{ .screen_rect = row.data().borderRectScale().r });
                    self.autoplay_show = false;
                }
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
        self.hit_map.clip = null;

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

    /// Effect time runs on the master tempo: one second per second at 120 BPM,
    /// so a faster track drives the drift and the tunnel faster.
    fn advanceEffects(self: *App) void {
        const now = dvui.currentWindow().backend.nanoTime();
        const last = self.effect_last_ns;
        self.effect_last_ns = now;
        if (self.paused or !self.effect.any() or last == 0 or now <= last) return;

        const elapsed = @as(f64, @floatFromInt(now - last)) * 1e-9;
        const step = dmt.tempoStep(elapsed, self.masterBpm()) * self.effect_speed;
        self.effect_time += step;
        self.effect_clock.advance(step, dmt.mood(self.effect_time));
        if (self.transport.anyPlaying()) self.mushroom.grow(step, self.effect_time, self.masterBpm());
        self.mushroom.tick(self.effect_time);
        self.mushroom.fall(step, self.effect_time);
    }

    /// An effect changes which texel sits under the cursor, so the pointer runs
    /// the same map the mesh does: a press lands on what the eye sees.
    fn pointed(self: *const App, p: hit.Point) hit.Point {
        if (!self.effect.any()) return p;
        const rect = dvui.currentWindow().rect_pixels;
        const size = dvui.Size.Physical{ .w = rect.w, .h = rect.h };
        const stills = self.stillRects();

        // DMT runs on top of LSD, so a press follows the tunnel first and the
        // drift underneath it second.
        var shown = dvui.Point.Physical{ .x = p.x, .y = p.y };
        if (self.effect.dmt != .off) shown = dmt.fold(shown, self.effect_clock, size, self.foldCanvas(), stills, 0, self.foldShape());
        switch (self.effect.look) {
            .drift => shown = lsd.sample(shown, self.effect_time, size, stills, 1),
            .mushroom => shown = lsd.sample(shown, self.effect_time, size, stills, mushroom.reach),
            .none => {},
        }
        return .{ .x = shown.x, .y = shown.y };
    }

    /// One pass over the frame's events, before any widget can take them.
    /// One pass over the frame's events, before any widget can take them.
    fn handleEvents(self: *App) void {
        for (dvui.events()) |*event| {
            switch (event.evt) {
                .mouse => self.handleMouse(event),
                .key => |key| {
                    if (key.action != .down) continue;
                    if (self.playlist_column.delete_playlist != null and key.code != .escape) self.playlist_column.cancelDelete(self);
                    if (key.code == .escape) {
                        if (self.playlist_column.renaming != null) {
                            self.playlist_column.cancelRename(self);
                            event.handled = true;
                            continue;
                        }
                        if (self.playlist_column.naming_save) {
                            self.playlist_column.cancelNamedSave();
                            event.handled = true;
                            continue;
                        }
                        if (self.playlist_column.delete_playlist != null) {
                            self.playlist_column.cancelDelete(self);
                            event.handled = true;
                            continue;
                        }
                        if (self.effect.any()) {
                            self.clearEffects();
                            event.handled = true;
                            continue;
                        }
                    }
                    if (key.code != .space) continue;
                    // A text field owns the keyboard: space types there.
                    if (self.typing) continue;
                    self.apply(.toggle_transport);
                    event.handled = true;
                },
                else => {},
            }
        }
    }

    fn gardenType(self: *const App) dvui.Font {
        const body = dvui.themeGet().font_body;
        return if (self.garden_font) body.withFamily(garden_family) else dvui.themeGet().font_mono;
    }

    /// The bundled emoji family at a size, or the body font when it did not load.
    fn emojiType(self: *const App, px: f32) dvui.Font {
        const body = dvui.themeGet().font_body;
        return if (self.emoji_font) body.withFamily(emoji_family).withSize(px) else body.withSize(px);
    }

    fn onPlant(at: dvui.Point.Physical) bool {
        const screen = dvui.currentWindow().rect_pixels;
        const plant = mushroom.plantRect(.{ .w = screen.w, .h = screen.h });
        return at.x >= plant.x and at.x <= plant.x + plant.w and
            at.y >= plant.y and at.y <= plant.y + plant.h;
    }

    /// A text field owns the keyboard this frame, so the next frame's keys are
    /// typing, not shortcuts.
    pub fn noteTyping(self: *App, id: dvui.Id) void {
        if (dvui.focusedWidgetIdInCurrentSubwindow() == id) self.typing = true;
    }

    fn handleMouse(self: *App, event: *dvui.Event) void {
        const mouse = event.evt.mouse;
        const p = self.pointed(pointFrom(mouse.p));

        switch (mouse.action) {
            .press => {
                if (mouse.button == .right) {
                    // Shift on a playlist row arms the chip to delete that row.
                    const target = self.hit_map.hit(p);
                    if (mouse.mod.shift() and target != null and target.? == .playlist) {
                        self.playlist_column.armDelete(self, target.?.playlist);
                    } else {
                        self.playlist_column.cancelDelete(self);
                    }
                    return;
                }
                if (!mouse.button.pointer()) return;
                // The plant is painted after the layout, so it is hit in screen
                // space rather than through the widget map.
                if (self.effect.look == .mushroom and onPlant(mouse.p)) {
                    self.mushroom.poke(self.effect_time);
                    dvui.refresh(null, @src(), null);
                    return;
                }

                // The field owns clicks inside its own row; a click anywhere
                // else ends the rename.
                if (self.playlist_column.renaming != null) {
                    if (self.playlist_column.renamingRow(self, p)) return;
                    self.playlist_column.cancelRename(self);
                }

                // A press outside the name field closes it, as it does for a
                // rename; a press on the chip then opens it again.
                if (self.playlist_column.naming_save) {
                    if (self.playlist_column.save_field.contains(p)) return;
                    self.playlist_column.cancelNamedSave();
                }

                // A press on the armed chip deletes; any other press reverts it
                // to the save chip.
                if (self.playlist_column.delete_playlist != null) {
                    const target = self.hit_map.hit(p);
                    if (target != null and target.? == .save_playlist) self.playlist_column.commitDelete(self) else self.playlist_column.cancelDelete(self);
                    return;
                }

                const target = self.hit_map.hit(p) orelse return;
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
                if (!mouse.button.pointer()) return;
                self.apply(self.drag.release());
                self.transport.jogResume();
            },
            else => {},
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
            .toggle_autoplay => {
                self.toggleAutoplay();
                dvui.refresh(null, @src(), null);
            },
            .toggle_transport => {
                if (self.paused) {
                    // Stop rather than resume: the lanes were running when the
                    // pause took them, so a transport press ends them.
                    self.paused = false;
                    self.pauseAutoplay();
                    self.transport.stopAll();
                } else if (self.autoplay_on) {
                    self.pauseAutoplay();
                    self.transport.stopAll();
                } else if (self.transport.anyPlaying()) {
                    self.transport.stopAll();
                } else {
                    self.replayPlayed();
                }
                dvui.refresh(null, @src(), null);
            },
            .toggle_pause => self.setPaused(!self.paused),
            .clear_all => {
                self.paused = false;
                self.pauseAutoplay();
                self.finishAutoplay();
                self.clearAll();
            },
            .toggle_sort_bpm => {
                self.sort_by_bpm = !self.sort_by_bpm;
                self.refresh() catch {};
                dvui.refresh(null, @src(), null);
            },
            .toggle_lsd => self.toggleEffect(.lsd),
            .toggle_mushroom => self.toggleEffect(.mushroom),
            .toggle_dmt => self.toggleEffect(.dmt),
            .heartbeat => {
                self.heartbeat = !self.heartbeat;
                dvui.refresh(null, @src(), null);
            },

            .select_playlist => |index| {
                if (index >= self.playlist_column.rows.len) return;
                self.playlist_column.selectPlaylist(self, index);
            },
            .rename_playlist => |index| self.playlist_column.startRename(self, index),
            .toggle_playlist => |index| {
                if (index >= self.playlist_column.rows.len) return;
                self.playlist_column.toggleFolder(self.playlist_column.rows[index].id);
            },
            .save_playlist => self.playlist_column.save(self),
            .save_named_playlist => self.playlist_column.startNamedSave(self),
            .grow_plant => {
                self.mushroom.stepGrowth(self.effect_time, self.masterBpm());
                dvui.refresh(null, @src(), null);
            },
            .toggle_lane_play => |index| {
                if (index >= self.grid.items.len) return;
                self.setPaused(false);
                self.pauseAutoplay();
                if (self.transport.isPlaying(index)) {
                    self.transport.stop(index);
                    self.played.remember(self.grid.items[index].track_id);
                } else {
                    self.transport.start(index, .next_bar);
                    self.played.remember(self.grid.items[index].track_id);

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
                self.refresh() catch {};
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
        // Autoplay hands the tempo to the track it is playing.
        if (self.autoplay_on) {
            if (self.autoplayLane()) |index| {
                if (index < self.grid.items.len) {
                    if (self.grid.items[index].analysis) |*analysis| {
                        if (analysis.bpm() > 0) return analysis.bpm();
                    }
                }
                if (self.crate.at(index)) |track| {
                    if (track.bpm > 0) return @floatCast(track.bpm);
                }
            }
        }
        if (!self.master_locked) return self.master_bpm;
        // The grid is the tempo the audio actually follows, so the clock must
        // use it: a tag that disagrees would make every bar drift.
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
        // A caret needs frames to blink.
        return self.transport.anyPlaying() or self.effect.any() or self.playlist_column.editing();
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
            .gravity_y = 0.5,
            .color_text = .{ .color = Palette.muted },
            .font = metaFont(),
            .margin = .{ .x = 8, .y = 0 },
        });

        if (self.master_locked or self.autoplay_on) {
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
            .min_size_content = .{ .w = 40, .h = 18 },
            .padding = .{ .x = 5, .y = 3 },
            .margin = .{ .x = 2, .y = 0 },
            .gravity_y = 0.5,
            .corners = square,
            .background = true,
            .color_fill = .{ .color = Palette.field },
            .color_text = .{ .color = Palette.ink },
            .font = metaFont(),
            .id_extra = 70,
        });
        self.noteTyping(entry.data().id);
        const enter = entry.enter_pressed;
        const focused = dvui.focusedWidgetId() == entry.data().id;
        entry.deinit();

        const left_box = self.master_focus and !focused;
        self.master_focus = focused;

        if (enter or left_box) self.commitMaster();

        {
            var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .margin = .{ .x = 3, .y = 0 },
                .padding = .{ .x = 5, .y = 0 },
                .min_size_content = .{ .h = 24 },
                .gravity_y = 0.5,
                .background = true,
                .color_fill = .{ .color = Palette.field },
                .id_extra = 72,
            });
            defer chip.deinit();
            labelStyled(@src(), if (self.master_locked) "locked" else "free", .{
                .gravity_y = 0.5,
                .color_text = .{ .color = if (self.master_locked) Palette.green else Palette.secondary },
                .font = metaFont(),
                .id_extra = 73,
            });
            self.hit_map.append(rectFrom(chip.data().rectScaleFromParent().r), .master_lock);
        }

        {
            var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .margin = .{ .x = 4, .y = 0 },
                .padding = .{ .x = 8, .y = 0 },
                .min_size_content = .{ .h = 24 },
                .gravity_y = 0.5,
                .background = true,
                .color_fill = .{ .color = Palette.field },
                .id_extra = 74,
            });
            defer chip.deinit();
            labelStyled(@src(), if (self.transport.keylocked()) "pitch" else "vinyl", .{
                .gravity_y = 0.5,
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

    /// The crate autoplay switch, between play and clear.
    fn autoButton(self: *App) void {
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .margin = .{ .x = 8, .y = 0 },
            .padding = .{ .x = 10, .y = 0 },
            .min_size_content = .{ .h = 24 },
            .gravity_y = 0.5,
            .background = true,
            .color_fill = .{ .color = if (self.autoplay_on) Palette.selection else Palette.field },
            .id_extra = 84,
        });
        defer chip.deinit();

        labelStyled(@src(), "auto", .{
            .gravity_y = 0.5,
            .color_text = .{ .color = if (self.autoplay_on) Palette.green else Palette.secondary },
            .font = metaFont(),
            .id_extra = 85,
        });
        self.hit_map.append(rectFrom(chip.data().rectScaleFromParent().r), .autoplay);
    }

    /// Where autoplay's track sits now. A crate edit moves lanes, so the index
    /// is only trusted while it still holds the track autoplay started.
    fn autoplayLane(self: *const App) ?usize {
        if (self.autoplay_index < self.crate.len()) {
            const track = self.crate.at(self.autoplay_index) orelse return null;
            if (self.autoplay_track == 0 or track.id == self.autoplay_track) return self.autoplay_index;
        }
        if (self.autoplay_track == 0) return null;
        for (0..self.crate.len()) |index| {
            const track = self.crate.at(index) orelse break;
            if (track.id == self.autoplay_track) return index;
        }
        return null;
    }

    /// Starts the lane autoplay sits on, walking past tracks the decoder cannot
    /// load rather than stalling on them.
    fn startAutoplayLane(self: *App) void {
        while (self.autoplay_index < self.crate.len()) {
            const track = self.crate.at(self.autoplay_index) orelse break;
            self.autoplay_track = track.id;
            self.transport.start(self.autoplay_index, .now);
            if (self.transport.isPlaying(self.autoplay_index)) {
                self.played.remember(track.id);
                return;
            }
            self.autoplay_index += 1;
        }
        self.finishAutoplay();
    }

    fn finishAutoplay(self: *App) void {
        self.autoplay_on = false;
        self.autoplay_index = 0;
        self.autoplay_track = 0;
    }

    /// Turns autoplay off but leaves its lane where it stopped, so pressing it
    /// again resumes the same track from the same beat.
    fn pauseAutoplay(self: *App) void {
        if (!self.autoplay_on) return;
        self.autoplay_on = false;
        if (self.transport.isPlaying(self.autoplay_index)) self.transport.stop(self.autoplay_index);
    }

    fn setPaused(self: *App, on: bool) void {
        if (on == self.paused) return;
        self.paused = on;
        if (on) self.transport.pauseAll() else self.transport.resumeAll();
        dvui.refresh(null, @src(), null);
    }

    /// Pulls the next crate track once the lane autoplay was running stops.
    fn advanceAutoplay(self: *App) void {
        if (self.paused) return;
        if (!self.autoplay_on) return;
        if (self.autoplayLane()) |index| self.autoplay_index = index;
        if (self.transport.isPlaying(self.autoplay_index)) return;
        self.autoplay_index += 1;
        self.autoplay_show = true;
        self.startAutoplayLane();
    }

    fn toggleAutoplay(self: *App) void {
        self.setPaused(false);
        if (self.autoplay_on) {
            self.pauseAutoplay();
            return;
        }
        if (self.crate.len() == 0) return;
        self.autoplay_on = true;
        self.autoplay_index = self.autoplayLane() orelse 0;
        self.autoplay_show = true;
        self.startAutoplayLane();
    }

    fn transportToggle(self: *App) void {
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .margin = .{ .x = 8, .y = 0 },
            .padding = .{ .x = 10, .y = 0 },
            .min_size_content = .{ .h = 24 },
            .gravity_y = 0.5,
            .background = true,
            .color_fill = .{ .color = Palette.field },
            .id_extra = 80,
        });
        defer chip.deinit();

        labelStyled(@src(), if (self.transport.anyPlaying()) "stop" else "play", .{
            .gravity_y = 0.5,
            .color_text = .{ .color = if (self.transport.anyPlaying()) Palette.green else Palette.secondary },
            .font = metaFont(),
            .id_extra = 81,
        });
        self.hit_map.append(rectFrom(chip.data().rectScaleFromParent().r), .transport);
    }

    /// Empties the crate and returns every control to its starting value.
    fn clearButton(self: *App) void {
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .margin = .{ .x = 18, .y = 0 },
            .padding = .{ .x = 10, .y = 0 },
            .min_size_content = .{ .h = 24 },
            .gravity_y = 0.5,
            .background = true,
            .color_fill = .{ .color = Palette.field },
            .id_extra = 82,
        });
        defer chip.deinit();

        labelStyled(@src(), "clear", .{
            .gravity_y = 0.5,
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
        self.playlist_column.clear(self);
        self.played = .{};
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
                    self.paintWave(analysis, wave_rect, view, analysis.downbeatOffset(), index);
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
                self.paintOverview(analysis, bar_rect);
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

    fn preview(self: *App, track: Track) void {
        const tempo: f32 = if (track.bpm > 0) self.masterBpm() / @as(f32, @floatCast(track.bpm)) else 1;
        if (self.player.holds(track.id)) {
            self.player.toggle(track, tempo);
            return;
        }
        if (self.transport.anyPlaying()) {
            // Spawn just before the bar: ffplay takes a moment to produce sound.
            // A bar too close for that lead is skipped, never started early.
            const lead: i128 = 200_000_000;
            const now = self.transport.nowNs();
            var bar = self.transport.nextBarTime();
            if (bar != 0 and bar - lead <= now) bar = self.transport.nextBarAfter(bar);
            self.preview_pending = track;
            self.preview_at_ns = if (bar == 0) now else bar - lead;
            return;
        }
        self.preview_pending = null;
        self.player.toggle(track, tempo);
    }

    /// The pinned look runs on tempo alone, at its own constant turn; the other
    /// variants use the mood-driven clock.


    /// Play: start the remembered tracks together. With nothing playable
    /// remembered, start every lane and remember what started.
    fn replayPlayed(self: *App) void {
        var indices: [Played.limit]usize = undefined;
        var count: usize = 0;

        if (self.grid.items.len >= Played.limit) {
            // A full crate already names the four: play them in crate order.
            for (0..Played.limit) |index| {
                indices[index] = index;
                count += 1;
            }
        } else {
            var lanes: [256]u64 = undefined;
            const lane_count = @min(self.grid.items.len, lanes.len);
            for (self.grid.items[0..lane_count], 0..) |lane, at| lanes[at] = lane.track_id;
            count = rememberedLanes(self.played.items(), lanes[0..lane_count], &indices);
        }

        if (count > 0 and self.transport.startGroup(indices[0..count])) return;

        self.transport.startAll();
        self.rememberPlaying();
    }

    /// Every lane now running joins the history, in crate order.
    fn rememberPlaying(self: *App) void {
        for (self.grid.items, 0..) |lane, index| {
            if (self.transport.isPlaying(index)) self.played.remember(lane.track_id);
        }
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

    /// The lane sitting on this crate position, when the source analysed it.
    fn laneAnalysis(self: *App, index: usize) ?*const pl.analysis.Analysis {
        if (index >= self.grid.items.len) return null;
        return if (self.grid.items[index].analysis) |*analysis| analysis else null;
    }

    /// Playhead of the lane on this crate position, zero while it is stopped.
    fn laneElapsedMs(self: *App, index: usize, analysis: *const pl.analysis.Analysis, total_ms: u32) u32 {
        if (!self.transport.isPlaying(index)) return 0;
        const elapsed = analysis.beatTimeMs(self.transport.beat(index));
        const total: f64 = @floatFromInt(total_ms);
        return @intFromFloat(@min(total, @max(0, elapsed)));
    }

    /// Beat count of the lane's track, from its grid.
    fn totalBeats(lane: *const Lane) usize {
        const analysis = lane.analysis orelse return 0;
        return analysis.beats.len;
    }

    /// Waveform and beat lines, drawn straight into the lane's rectangle.
    fn paintWave(self: *App, analysis: *const pl.analysis.Analysis, rect: hit.Rect, start_beat: f32, beat_offset: f32, slot: usize) void {
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
        const wash = if (has_bands) waveColor(wave_colour.tintBands(0.7, analysis.bands)) else bandColor(0.45);
        self.waveWash(rect, wash, slot);

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
                self.waveFill(&builder, rect.x + x, rect.bottom() - height, width, height, color);
            }
        }
    }

    /// The lane's own colour, laid under its waveform, so the empty stretch of
    /// a lane carries colour instead of reading as flat grey in the fold.
    fn waveWash(self: *App, rect: hit.Rect, colour: dvui.Color, slot: usize) void {
        if (self.effect.dmt == .off) return;

        const wash = saturated(opposite(colour, slot, self.effect_time), self.chromaAmount());
        const tick: u64 = @intFromFloat(@floor(self.effect_time * 1.5));
        const cell_w = rect.w / @as(f32, @floatFromInt(wash_columns));
        const cell_h = rect.h / @as(f32, @floatFromInt(wash_rows));

        var row: usize = 0;
        while (row < wash_rows) : (row += 1) {
            // The bars sit at the bottom of the lane, so the wash is deepest
            // there and thins out towards the top.
            const depth = @as(f32, @floatFromInt(wash_rows - row)) / @as(f32, @floatFromInt(wash_rows));
            var column: usize = 0;
            while (column < wash_columns) : (column += 1) {
                const cell = grain(tick *% 131 +% column *% 17 +% row *% 7);
                const alpha = self.washStrength() * (0.08 + 2.1 * cell) * (0.25 + 1.05 * depth);
                const patch = dvui.Rect.Physical{
                    .x = rect.x + cell_w * @as(f32, @floatFromInt(column)),
                    .y = rect.y + cell_h * @as(f32, @floatFromInt(row)),
                    .w = cell_w + 1,
                    .h = cell_h + 1,
                };
                const split = 0.4 + 1.6 * cell;
                self.shiftWash(patch, -split, 0, faded(aberration_red, alpha * 0.16));
                self.shiftWash(patch, split, 0, faded(aberration_blue, alpha * 0.16));
                self.colours.append(self.allocator, .{
                    .rect = patch,
                    .colour = faded(wash, alpha),
                }) catch return;
            }
        }
    }

    fn shiftWash(self: *App, patch: dvui.Rect.Physical, dx: f32, dy: f32, colour: dvui.Color) void {
        self.colours.append(self.allocator, .{
            .rect = .{ .x = patch.x + dx, .y = patch.y + dy, .w = patch.w, .h = patch.h },
            .colour = colour,
        }) catch return;
    }

    /// What the colour slider means: the fold dims further, the wash and the
    /// fills come back stronger, and the chroma opens up as it rises.
    fn foldShade(self: *const App) f32 {
        return 1 - 0.6 * self.lane_colour;
    }

    fn colourShare(self: *const App) f32 {
        return @min(1, 1.2 * self.lane_colour);
    }

    fn washStrength(self: *const App) f32 {
        return washFor(self.lane_colour, self.beat_power);
    }

    fn chromaAmount(self: *const App) f32 {
        return chromaFor(self.lane_colour, self.beat_power);
    }

    /// A waveform column: drawn now, and kept while DMT runs, which paints the
    /// coloured fills again through the fold.
    fn waveFill(self: *App, builder: *dvui.Path.Builder, x: f32, y: f32, w: f32, h: f32, colour: dvui.Color) void {
        fillRectInto(builder, x, y, w, h, colour);
        if (self.effect.dmt == .off) return;
        self.colours.append(self.allocator, .{
            .rect = .{ .x = x, .y = y, .w = w, .h = h },
            .colour = faded(saturated(colour, self.chromaAmount()), self.colourShare()),
        }) catch return;
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
    fn paintOverview(self: *App, analysis: *const pl.analysis.Analysis, rect: hit.Rect) void {
        if (rect.w <= 0 or rect.h <= 0 or analysis.waveform.len == 0) return;
        const len: f32 = @floatFromInt(analysis.waveform.len);
        const scale: f32 = 255 / @as(f32, @floatFromInt(@max(1, analysis.peak)));

        var builder = dvui.Path.Builder.init(self.allocator);
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
            self.waveFill(&builder, rect.x + x, rect.bottom() - height, 6, height, color);
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
        .min_size_content = .{ .w = 380, .h = 0 },
        // Every card the same width, so the grid beside it starts at the same
        // x on every row and the playheads stack.
        .max_size_content = .{ .w = 380, .h = 100000 },
        .padding = .{ .x = 14, .y = 6 },
        .margin = .{ .x = 6, .y = 2 },
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
        .margin = .{ .y = 2 },
        .id_extra = index * 16 + 2,
    });

    var meta_buffer: [96]u8 = undefined;
    var meta_text = trackMeta(track, &meta_buffer, app.note_names);
    if (app.laneAnalysis(index)) |analysis| {
        const total_ms = analysis.durationMs();
        var elapsed_buffer: [24]u8 = undefined;
        var total_buffer: [24]u8 = undefined;
        var pair_buffer: [24]u8 = undefined;
        const pair = std.fmt.bufPrint(&pair_buffer, "{s}/{s}", .{
            clockText(app.laneElapsedMs(index, analysis, total_ms), &elapsed_buffer),
            clockText(total_ms, &total_buffer),
        }) catch "";
        if (pair.len > 0) {
            // trackMeta wrote the prefix here, so the pair continues it.
            const tail = std.fmt.bufPrint(meta_buffer[meta_text.len..], " · {s}", .{pair}) catch "";
            meta_text = meta_buffer[0 .. meta_text.len + tail.len];
        }
    }
    labelStyled(@src(), meta_text, .{
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
        .min_size_content = .{ .w = 380, .h = 30 },
        .id_extra = gap,
    });
    defer area.deinit();

    const color = stepColor(step);
    const direction: pl.camelot.Direction = if (step.key_known) step.key.direction else .held;

    drawBpmDelta(area.data().contentRectScale(), step.bpm_delta);

    if (direction == .held) {
        // Two bars rather than a glyph: a label's line height made this row
        // taller than the triangle rows, so the gaps came out uneven.
        const rs = area.data().contentRectScale();
        const center_x = rs.r.x + rs.r.w / 2;
        const center_y = rs.r.y + rs.r.h / 2;
        for (0..2) |index| {
            const y = center_y + (@as(f32, @floatFromInt(index)) - 0.5) * 7 * rs.s;
            const bar = dvui.Rect.Physical{ .x = center_x - 8 * rs.s, .y = y - 1.5 * rs.s, .w = 16 * rs.s, .h = 3 * rs.s };
            bar.fill(.{}, .{ .color = .{ .color = color }, .fade = 1.0 });
        }
        return;
    }

    const rect_scale = area.data().contentRectScale();
    const rect = rect_scale.r;
    const scale = rect_scale.s;
    const center_x = rect.x + rect.w / 2;
    const center_y = rect.y + rect.h / 2;
    const points_up = direction == .up;

    for (0..3) |index| {
        const offset = (@as(f32, @floatFromInt(index)) - 1) * 12 * scale;
        drawTriangle(allocator, center_x + offset, center_y, 4 * scale, points_up, color);
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
        .p = .{ .x = center_x + 26 * rs.s, .y = center_y - 6 * rs.s },
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

pub fn fillRect(allocator: std.mem.Allocator, x: f32, y: f32, w: f32, h: f32, color: dvui.Color) void {
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
/// Waveform colour held against the fold's dampening: the grey chrome dims,
/// the heat map keeps its weight.

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

/// A window-sized texture for an effect layer, reused until the window resizes.
fn sizedTarget(slot: *?dvui.Texture.Target, size: dvui.Size.Physical) !dvui.Texture.Target {
    const width: u32 = @intFromFloat(@max(1, @floor(size.w)));
    const height: u32 = @intFromFloat(@max(1, @floor(size.h)));
    if (slot.*) |target| {
        if (target.width == width and target.height == height) return target;
        target.destroyLater();
        slot.* = null;
    }
    const target = try dvui.Texture.Target.create(.{ .width = width, .height = height });
    slot.* = target;
    return target;
}

pub fn rectFrom(rect: dvui.Rect.Physical) hit.Rect {
    return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
}

/// How much one kick opens the colour up, on top of the colour slider.
const kick_saturation: f32 = 1.2;

fn drawnRingsFor(base: f32, wander: f32) f32 {
    return std.math.clamp(base + wander, dmt.min_rings, dmt.max_rings);
}

fn chromaFor(colour: f32, beat: f32) f32 {
    return 1 + 0.5 * colour + kick_saturation * beat;
}

fn washFor(colour: f32, beat: f32) f32 {
    return 0.85 * colour * (1 + 0.45 * beat);
}

/// How far the lane count wanders from the slider, in ring widths, and how
/// slowly it gets there.
const lane_wander_limit: f32 = 1.1;
const lane_wander_ease: f32 = 3.4;

/// The kick: the loudest of the lowest bands, once past the floor.
/// Downsample factor the blur slider reaches at full travel.
const blur_max: f32 = 6;

const kick_bins: usize = 3;
const kick_floor: f32 = 0.34;
const kick_fall: f32 = 0.18;
const kick_rise: f32 = 0.05;

/// One step of the kick follower: a rise of a few tens of milliseconds so the
/// jump is not a step, and a tail short enough that the next kick lands on a
/// settled frame.
fn beatFollow(previous: f32, bass: f32, delta: f32) f32 {
    const target = std.math.clamp((bass - kick_floor) / (1 - kick_floor), 0, 1);
    const span = @max(delta, 0);
    const rate = if (target > previous) kick_rise else kick_fall;
    return previous + (target - previous) * (1 - @exp(-span / rate));
}

/// The grid the wash is broken into, so it moves and carries its own
/// aberrations.
const wash_columns: usize = 16;

/// How far one lane's wash turns from the next, and how fast the row drifts
/// through the wheel.
const wash_step: f32 = 0.13;
const wash_turn: f32 = 0.018;
const wash_rows: usize = 3;

/// The two channels the wash splits into, so its grain reads as colour fringing.
const aberration_red = dvui.Color{ .r = 0xff, .g = 0x2a, .b = 0x38, .a = 0xff };
const aberration_blue = dvui.Color{ .r = 0x2e, .g = 0x6a, .b = 0xff, .a = 0xff };

/// White noise in `[0, 1)`, from a counter, so a wash can be redrawn each frame
/// without carrying state.
fn grain(seed: u64) f32 {
    var hash = seed *% 0x9e37_79b9_7f4a_7c15;
    hash ^= hash >> 31;
    hash *%= 0xbf58_476d_1ce4_e5b9;
    hash ^= hash >> 27;
    return @as(f32, @floatFromInt(hash >> 40)) / @as(f32, @floatFromInt(@as(u64, 1) << 24));
}

/// The hue turned away from `colour` by the lane's place in the row plus a
/// slow turn of the clock. The step is small, so neighbouring lanes shade into
/// each other rather than jumping, and the whole row walks through the primaries
/// over about a minute.
fn opposite(colour: dvui.Color, slot: usize, now: f64) dvui.Color {
    const red: f32 = @floatFromInt(colour.r);
    const green: f32 = @floatFromInt(colour.g);
    const blue: f32 = @floatFromInt(colour.b);

    const high = @max(red, @max(green, blue));
    const low = @min(red, @min(green, blue));
    const spread = high - low;

    var hue: f32 = 0;
    if (spread > 0) {
        if (high == red) {
            hue = @mod((green - blue) / spread, 6);
        } else if (high == green) {
            hue = (blue - red) / spread + 2;
        } else {
            hue = (red - green) / spread + 4;
        }
        hue /= 6;
    }
    const walk = 0.5 + @as(f32, @floatFromInt(slot)) * wash_step + @as(f32, @floatCast(now)) * wash_turn;
    hue = @mod(hue + walk, 1);

    const saturation: f32 = if (high > 0) spread / high else 0;
    const strong = @max(saturation, 0.8);
    const bright = std.math.clamp(high / 255, 0.55, 0.85);

    const sat = bright * strong;
    const second = sat * (1 - @abs(@mod(hue * 6, 2) - 1));
    const base = bright - sat;
    const rgb = switch (@as(u8, @intFromFloat(hue * 6)) % 6) {
        0 => [3]f32{ sat, second, 0 },
        1 => [3]f32{ second, sat, 0 },
        2 => [3]f32{ 0, sat, second },
        3 => [3]f32{ 0, second, sat },
        4 => [3]f32{ second, 0, sat },
        else => [3]f32{ sat, 0, second },
    };
    return .{
        .r = @intFromFloat(std.math.clamp(rgb[0] + base, 0, 1) * 255),
        .g = @intFromFloat(std.math.clamp(rgb[1] + base, 0, 1) * 255),
        .b = @intFromFloat(std.math.clamp(rgb[2] + base, 0, 1) * 255),
        .a = 0xff,
    };
}

/// Pushes a colour away from its own grey, so the coloured fills keep their
/// chroma while the rest of the folded frame goes dark.
fn saturated(colour: dvui.Color, amount: f32) dvui.Color {
    const red: f32 = @floatFromInt(colour.r);
    const green: f32 = @floatFromInt(colour.g);
    const blue: f32 = @floatFromInt(colour.b);
    const grey = 0.29 * red + 0.59 * green + 0.11 * blue;
    return .{
        .r = chroma(red, grey, amount),
        .g = chroma(green, grey, amount),
        .b = chroma(blue, grey, amount),
        .a = colour.a,
    };
}

fn chroma(value: f32, grey: f32, amount: f32) u8 {
    const wide = grey + (value - grey) * amount;
    return @intFromFloat(std.math.clamp(wide, 0, 255));
}

fn faded(colour: dvui.Color, amount: f32) dvui.Color {
    const share = std.math.clamp(amount, 0, 1);
    return .{
        .r = fadeChannel(colour.r, share),
        .g = fadeChannel(colour.g, share),
        .b = fadeChannel(colour.b, share),
        .a = fadeChannel(colour.a, share),
    };
}

fn fadeChannel(value: u8, share: f32) u8 {
    return @intFromFloat(@as(f32, @floatFromInt(value)) * share);
}

fn pointFrom(point: dvui.Point.Physical) hit.Point {
    return .{ .x = point.x, .y = point.y };
}

/// Seconds on the backend clock, for the drift's phase.
pub fn secondsNow() f64 {
    return @as(f64, @floatFromInt(dvui.currentWindow().backend.nanoTime())) * 1e-9;
}

/// Along the bottom: the BPM window and direction filters on the left, the
/// transport, span and master on the right, all on one centreline.
fn frameFooter(app: *App) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 40 },
        .padding = .{ .x = 0, .y = 6 },
        .background = true,
        .color_fill = .{ .color = Palette.panel },
    });
    defer bar.deinit();

    app.frameBpmWindow();
    app.sortButton();
    app.energyToggle("=", Palette.green, &app.filter_hold, .hold);
    app.energyToggle("↑", Palette.orange, &app.filter_up, .up);
    app.energyToggle("↓", Palette.orange, &app.filter_down, .down);

    app.notationToggle();

    var spacer = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    spacer.deinit();

    app.transportToggle();
    app.autoButton();
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

/// h:mm:ss, the shape of the rekordbox time column.
/// h:mm:ss only from an hour up; m:ss from a minute; bare seconds below that.
fn clockText(ms: u32, buffer: []u8) []const u8 {
    const seconds = ms / 1000;
    const text = if (seconds >= 3600)
        std.fmt.bufPrint(buffer, "{d}:{d:0>2}:{d:0>2}", .{ seconds / 3600, (seconds / 60) % 60, seconds % 60 })
    else
        std.fmt.bufPrint(buffer, "{d}", .{seconds});
    return text catch "";
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
pub fn labelStyled(src: std.builtin.SourceLocation, text: []const u8, options: dvui.Options) void {
    dvui.labelNoFmt(src, text, .{}, options);
}

fn labelFmt(src: std.builtin.SourceLocation, comptime format: []const u8, arguments: anytype, options: dvui.Options) void {
    dvui.label(src, format, arguments, options);
}

pub fn bodyFont() dvui.Font {
    return dvui.themeGet().font_body;
}

pub fn metaFont() dvui.Font {
    return dvui.themeGet().font_body;
}

pub fn headingFont() dvui.Font {
    return dvui.themeGet().font_heading;
}

fn titleFont() dvui.Font {
    return dvui.themeGet().font_title;
}

/// Every surface in the app is rectangular; the theme rounds them by default.
pub const square = dvui.CornerRect{
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

test "the wash grain stays in range and moves with the counter" {
    var low: f32 = 1;
    var high: f32 = 0;
    for (0..512) |step| {
        const value = grain(step);
        try std.testing.expect(value >= 0 and value < 1);
        low = @min(low, value);
        high = @max(high, value);
    }
    // The band is spread across the whole range, not clustered.
    try std.testing.expect(low < 0.1);
    try std.testing.expect(high > 0.9);
    try std.testing.expect(grain(7) != grain(8));
}

test "the lane wander stays inside the slider's range" {
    try std.testing.expectEqual(dmt.max_rings, drawnRingsFor(dmt.max_rings - 0.2, 3));
    try std.testing.expectEqual(dmt.min_rings, drawnRingsFor(dmt.min_rings + 0.2, -3));
    try std.testing.expectApproxEqAbs(@as(f32, 2.4), drawnRingsFor(2, 0.4), 0.001);
}

test "a kick opens the colour and thickens the wash" {
    try std.testing.expect(chromaFor(0.6, 1) > chromaFor(0.6, 0));
    try std.testing.expect(washFor(0.6, 1) > washFor(0.6, 0));
    try std.testing.expectApproxEqAbs(washFor(0.6, 0) * 1.45, washFor(0.6, 1), 0.001);
}

test "a kick swells over a few frames and is gone within a beat" {
    var level: f32 = 0;
    for (0..8) |_| level = beatFollow(level, 0.9, @as(f32, 1) / 120);
    try std.testing.expect(level > 0.55);
    try std.testing.expect(level < 0.95);

    const within_a_beat = beatFollow(level, 0, 0.2);
    try std.testing.expect(within_a_beat < level * 0.4);
    try std.testing.expect(beatFollow(within_a_beat, 0, kick_fall) < within_a_beat);

    // Rumble below the floor never starts a pulse.
    try std.testing.expectEqual(@as(f32, 0), beatFollow(0, 0.3, 0.016));
}

test "the wash takes the hue opposite the lane" {
    const blue = dvui.Color{ .r = 0x20, .g = 0x60, .b = 0xf0, .a = 0xff };
    try std.testing.expect(opposite(blue, 0, 0).r > opposite(blue, 0, 0).b);

    const red = dvui.Color{ .r = 0xf0, .g = 0x30, .b = 0x30, .a = 0xff };
    try std.testing.expect(opposite(red, 0, 0).g > opposite(red, 0, 0).r);

    // Grey has no hue to turn, so the wash keeps a lit channel rather than
    // collapsing to black.
    const flat = opposite(dvui.Color{ .r = 0x40, .g = 0x40, .b = 0x40, .a = 0xff }, 0, 0);
    try std.testing.expect(@max(flat.r, @max(flat.g, flat.b)) > 0x60);
}

test "the fold keeps its colours and leaves grey grey" {
    const grey = dvui.Color{ .r = 0x40, .g = 0x40, .b = 0x40, .a = 0xff };
    const kept = saturated(grey, 1.3);
    try std.testing.expectEqual(grey.r, kept.r);
    try std.testing.expectEqual(grey.g, kept.g);
    try std.testing.expectEqual(grey.b, kept.b);

    const purple = dvui.Color{ .r = 0xbd, .g = 0x93, .b = 0xf9, .a = 0xff };
    const wide = saturated(purple, 1.3);
    try std.testing.expect(wide.b > purple.b);
    try std.testing.expect(wide.g < wide.b);

    const full = dvui.Color{ .r = 0xff, .g = 0x00, .b = 0x00, .a = 0xff };
    try std.testing.expectEqual(@as(u8, 0xff), saturated(full, 1.3).r);
    try std.testing.expectEqual(@as(u8, 0x00), saturated(full, 1.3).g);

    try std.testing.expectEqual(purple, faded(purple, 1));
}

test "a mode chip runs itself and stops only itself" {
    try std.testing.expectEqual(Dmt.plain, pressed(.off, .plain));
    try std.testing.expectEqual(Dmt.off, pressed(.plain, .plain));

}

test "the play history keeps four tracks, newest last" {
    var played: Played = .{};
    for ([_]u64{ 1, 2, 3, 4 }) |id| played.remember(id);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4 }, played.items());

    // A fifth track pushes the oldest out.
    played.remember(5);
    try std.testing.expectEqualSlices(u64, &.{ 2, 3, 4, 5 }, played.items());

    // Replaying a remembered track moves it to the newest slot.
    played.remember(3);
    try std.testing.expectEqualSlices(u64, &.{ 2, 4, 5, 3 }, played.items());
}

test "replay skips tracks the crate no longer holds" {
    const lanes = [_]u64{ 7, 9, 11 };
    var out: [Played.limit]usize = undefined;

    try std.testing.expectEqual(@as(usize, 3), rememberedLanes(&.{ 9, 7, 11 }, &lanes, &out));
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 2 }, out[0..3]);

    // Removed tracks drop out, the rest keep their order.
    try std.testing.expectEqual(@as(usize, 1), rememberedLanes(&.{ 5, 7, 6 }, &lanes, &out));
    try std.testing.expectEqualSlices(usize, &.{0}, out[0..1]);
}

