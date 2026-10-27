# alchimix

A block-style playlist builder for a rekordbox collection. Pick a seed track, see
what can follow it by Camelot key and tempo, and place tracks left or right of a
neighbour.

## Requirements

- Zig 0.17
- SQLCipher (`brew install sqlcipher`) — the rekordbox collection is encrypted
- ffmpeg (`brew install ffmpeg`) — preview playback

SDL3, dvui, FreeType and the rest come in as packages; `zig-pkg/` is ignored by git.

## Run

```sh
zig build && ./zig-out/bin/alchimix
```

```sh
zig build test        # domain, transport and pointer tests
```

| Command | What it prints |
|---|---|
| `alchimix` | the block canvas |
| `alchimix library` | track count and how many carry a key |
| `alchimix suggest <text>` | what could follow the first match, ranked |

## Preview

`▶` on a row or a block plays fifteen seconds from the middle of the track, through
`ffplay`. While the grid is playing, a preview waits for the next master bar and
matches the master tempo. Pause stops the process and remembers the offset, so play resumes from
there; a stopped process would keep the audio device open. Starting another track stops the first.

Each block carries a bar along its bottom that fills as the snippet runs.

Lane playback uses one mixer clock. The playhead waits for decoded audio; up to
eight lanes can play together. Drag the waveform to jog, or the overview to seek
by bars; releasing a jog lands on the nearest beat. Every other start lands on a
bar, so two lanes never sit half a bar apart. Each lane ends in a live spectrum
with three draggable EQ nodes (low shelf, bell, high shelf); HPF, BPF and LPF
presets load a shape, and clicking the active preset clears the EQ. A trim slider
at the far right doubles as a level meter;
`M` under a lane's play button mutes it while the clock keeps running. The footer
sets the waveform span (16, 32 or 64 beats), next to the master BPM. The
waveform is tinted by rekordbox's three bands: kick red, mid green, high blue.

`🍄` runs the same drift field at 0.45 strength with the same colour fringe and
no flare, over an ASCII undergrowth: small mushrooms pop and grow, tall ones arrive in
tight clusters of seven to twelve, wide ones stand alone, pale rain falls and
rings where it lands, insects crawl, and a snail crosses slowly. A shamrock
grows, leaf by leaf, into a small flowering tree while music plays; pressing it
floats hearts up to pop.

The `garden` column lists eight switches. Clicking a row turns that behaviour on
or off; the arrow in front of each title drops its description.

The undergrowth is drawn in Courier New (falling back to Andale Mono, then the
theme mono): the art is a character grid, and a proportional or round face pulls
the rows apart.

The emoji glyphs come from `assets/NotoEmoji.ttf` (SIL OFL, licence beside it).
The system emoji font is a colour bitmap, which the text rasteriser cannot read,
so the app loads this one at startup and falls back to ASCII art without it.

`space`, or the footer's `play`, starts the last four tracks that played,
together; `stop` stops every lane. The history holds the four most recent
tracks to start, so a lane begun from its own `▶` joins it too. With nothing
remembered yet, play starts every lane and remembers what started.

The right column lists rekordbox playlists and folders. Picking a playlist
loads its tracks into the crate in playlist order, ready to rearrange; `save`
writes the crate back into that playlist, or into a new one named after the seed
when the crate came from nowhere. Shift-press `save` to type the name instead; a
name the library already holds is refused and nothing is written. Shift-click a
row to rename it. Shift-right-click a row to delete it: the chip turns into
`Delete ?`, and one more press removes the playlist and its track rows. The
tracks stay in the collection. A folder that still holds playlists is not offered
for deletion. Intelligent playlists and rekordbox's own `CUE Analysis Playlist`
entries are not shown.

## Editing a crate

Drag a row from the left column into the canvas to insert it; a click alone adds
nothing. Drag a block by its body and drop it on a gap line to move it. Pressing a
block selects it, and the suggestions follow that selection. `×` removes a block.

## Effects

`LSD` drifts the window. The frame is drawn into an offscreen copy and laid back
through a slowly moving displacement field, one colour channel at a time, under
a drifting wash and a lens flare. Red rides a few pixels out of blue at every
hard edge.

`DMT` repeats the window in a funnel. Every ring is a whole copy of the frame,
0.55 of the ring outside it and turned slightly against it, so the UI itself is
the fractal and the funnel is its scale. Rings advance with the effect clock.

The effect clock runs at the master tempo over 128, so a 140 BPM track moves the
drift and the funnel faster than a 90 BPM one. 128 is the default when no track
has set the tempo.

`DMT` speed wanders on seeded sines and the turn flips direction every 6.5
seconds, so the motion never settles into a loop. A speed slider under the mode
chips scales both effects.

The fold carries its own sliders: `window` scales the small virtual window the
tunnel is laid out on, `wander` sets how far that window breathes by itself
(every five to eleven seconds), `lanes` sets how many rings it repeats, `colour`
how much of the picture the colour pass carries, `mirror` how many mirrored
sectors it turns through, and `blur` softens the frame before it is folded — the
bottom of the slider is no blur at all. A kick swells both the window and the
ring count with the beat.

`OG DMT` is the pinned look: full brightness, constant turn, and the window
border held still so nothing samples past the frame. It runs on tempo alone, so
the speed slider leaves it alone.

`DMT` folds at full brightness, the frame as it is. `DMT A` and `DMT B` fold at
0.55: the frame is mostly grey chrome, and the coloured content should carry the
picture. `DMT A` dims the whole fold and lifts the waveform; `DMT B` also paints
the waveform fills back at full strength through the same map, so colour
survives the fold undimmed. All three are one choice: pressing a chip runs that
fold, and pressing the active one stops it.

Both effects can run at once. `DMT` folds the frame `LSD` has already drifted,
and both chips stay live.

Each mode runs the same map for drawing and for the pointer, so a click lands on
the control the eye sees under the cursor. With both on, the pointer follows the
tunnel first and the drift underneath it. The chips are painted back from the
copy last, so they never move and always respond.

The shapes follow reported phenomenology rather than a shader: fractal and
geometric patterns with vivid colour are the most common visual content
(Sci. Rep. 2022, n = 3,778), entities appear in 45.5% of accounts, and tunnels,
spirals and lattices are Klüver's form constants.

## Where the tracks come from

`~/Library/Pioneer/rekordbox/master.db`, opened with SQLCipher. Writes stay
inside playlists: creating one, replacing its tracks, renaming it, deleting it.
Tracks, cue points and analysis are never written. Each write holds the
database's write lock for one transaction and waits up to five seconds for
rekordbox to let go of it.

The database key comes from `ALCHIMIX_REKORDBOX_KEY` when set, otherwise from the
cache pyrekordbox keeps at `~/Library/Application Support/pyrekordbox/rb.cache`.
Without either, the app opens with three demo tracks.

To read the collection from another source, implement the port in `src/ports/library.zig`.

## Layout

| Path | Holds |
|---|---|
| `src/domain/camelot.zig` | key parsing, wheel distance, relation between two keys |
| `src/domain/bpm.zig` | tempo match, including half and double time |
| `src/domain/crate.zig` | the crate: ordered tracks, seed, transitions |
| `src/domain/suggest.zig` | ranking of what can follow a seed |
| `src/ports/library.zig` | the track-source port |
| `src/adapters/rekordbox.zig` | SQLCipher reader and playlist writer for rekordbox 6 |
| `src/adapters/memory.zig` | in-memory source for tests and the demo |
| `src/ui/app.zig` | block canvas, picker, toolbar |
| `src/ui/playlists.zig` | the playlist column: rows, rename, delete, save |
| `src/ui/hit.zig` | hit rectangles, pointer-to-beat conversion and drag rules |
| `src/ui/lsd.zig` | the drift field, the colour passes and the flare |
| `src/ui/dmt.zig` | the fold, the tunnel haze and the beings |
| `src/ui/geom.zig` | triangle buffers shared by both effects |
| `src/ui/run.zig` | window and frame loop |
| `src/audio/transport.zig` | playback positions, bar joins, jog and retune transitions |
| `src/audio/mixer.zig` | decoder buffers, shared output clock and lane start times |

## Arrows

Blocks stack down the canvas, and the arrow between two of them is a `↓` glyph.
Its colour runs from green to red
with the size of the harmonic step, the same ramp in both directions. Triangles
to the right of the arrow say which way the energy moves: one for ±1, two
for ±2, three for ±5.

| Colour | Step | Triangles |
|---|---|---|
| green | 0, relative | none |
| olive | ±1 | 1 |
| yellow | ±2 | 2 |
| orange | ±5 | 3 |
| red | ±3, ±4, ±6 | none, not harmonic |

The arrow needs a font with `→`, so the app loads CaskaydiaCove Nerd Font from
`~/Library/Fonts` at startup and falls back to `»` without it.
