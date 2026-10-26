# Sound-design screen (`ui :sound`)

The tiled screen for designing sounds (sound-design-ui-1, 2026-10-26): the maintainer's first priority for the sound-design UI, "Do 4 and 1" of the options offered: (4) a design pass first, a mock-up of the screen as static captures to react to, then (1) a patch inspector pane: pick a track or node, see its parameters as knobs (live values, ranges, units, curves from Param records), with the filter/shaper preview, turned with arrow keys or MIDI (journaled, undoable), the code updating beside it.  First version turns only what is already a knob; live rebuilds of literals come later.  The library index and its picker are being built in parallel (library-core-1): this screen shows where the picker goes, and the inspector doesn't need it.

Design inputs: the library design draft (workbench `research/library-design/design-draft.md` and STATE.md: picker with find-as-you-type, Enter doing the likely action named on the status line, a shortcut per action, auditions on CUE only, a side panel, save key flow, A/B, dirty state, favourites; morph/randomize later), terminal_ui.md (tiles, panes as Ruby kinds, layouts as data, pane modes, the command bus), params.md (the Param record), racks.md (the inspection protocol: `param_info`, `param_snapshot`, `Plot::Panels.preview`).

Mock-up captures (with a real patch: `preset :dnb_reese` on a track with its cutoff on a knob, and a pad reading the same knob) at 120x40 and 236x80, with a value prompt and a second track: `/app/tmp/sound_design_mockup/` (made by its `make_captures.rb`, which also lists the open questions in its README).

## Using it

```ruby
knob :cut, 2400.hz, range: 150.hz..8000.hz
track(:bass) { |clip| preset :dnb_reese, midi: clip, cutoff: :cut }
bg :bass, riff
ui :sound            # then NAV d (or Ctrl-W d): into the inspector
```

In the inspector: Up/Down pick a knob, Left/Right turn it (Shift or H/L fine; a held key is a live sweep you hear and one `turn :cut, 0 => ..., 1.n8 => ...` line when you let go), Enter types a value (`turn :cut, ` on the prompt line: `3000.hz`, `0.3`), 0 the default, m learns a MIDI controller (`learn :cut`: turn one), t/T the next/previous track, n/N (or ] [) the next/previous node (its preview and params).  Every change is a console line through `UI.run_line`, printed in the REPL pane: journaled, undoable, in the take.  NAV c goes into the code pane (arrows scroll, y copies).

## Layout

```
transport | form                                          (1 row)
tracks (7)      | inspector (weight 3)  | code              (the main area, weight 5)
                |                       | render (weight 2, min 8)
library picker  | preview (weight 2)    | keys (9)
audition: the CUE line                                    (1 row)
console (weight 2, at least 8 rows), full width
status line: the mode, the focused pane, "Enter: type cut's value", hints
```

The console runs along the bottom at full width: the tiles keep it at least half the terminal wide (40-60 columns, `Tiles.repl_min_cols`), which a third column at 120 columns can't give.  Panes:

| pane | kind | what it shows | keys |
|---|---|---|---|
| `inspector` (jump d) | `Panes::Inspector` | the track (which of the players: 1/2), the knobs its graph reads as knob rows (name, a meter along the knob's curve, value with unit, range and curve, the Param's description under the picked one), the nodes as chips (deduped: synth lanes and unison copies as ×n; knob readers first, then nodes with previews), the selected node's class and params (values with units; knob-driven ones as `→ knob cut 2400 Hz`, node-driven ones name the node) | mode keys above |
| `preview` | `Panes::Preview` (plot) | the selected node's `Plot::Panels.preview` (a filter's response, a shaper's curve) through `Plot::Live#draw` into the grid; rebuilt only when the node's Params change (a turned knob moves a filter's curve) | (view mode) |
| `code` (jump c) | `Panes::Code` | the knob lines the graph reads at their values now (`knob :cut, (150.hz..8000.hz).at(3100.hz)`), then the graph's `to_ruby`, wrapped with a hanging indent; recomputed only when the code or a knob value changes | arrows, PgUp/PgDn, y |
| `picker` | `Panes::Picker` | placeholder: the library picker (find-as-you-type, Enter's likely action, a key per action, auditions on CUE) | |
| `audition` | `Panes::Audition` | one line: parts on CUE (`:"x/cue"` players), the `:phones` and `:cue_mix` knobs, where the picker's audition plays | |
| `render` (jump w) | `Panes::Render` (plot) | one note through the track's patch, offline: waveform above spectrum, LUFS, peak, RMS, the previous render faintly behind; renders again 0.1 s after the knobs it reads stop moving (see The render pane) | s views, o overlay, p guessed note, + - length, r again |
| `sound_keys` | `Panes::SoundKeys` | the inspector's keys (from its keymap, so they can't drift) and the planned ones, dim, marked later (/ find, a audition, Enter the picker's action, S save, b A/B, * favourite) | |

The status line names Enter's action while a pane's mode is on (`Tiles#enter_hint`: a pane's `enter_hint(state)`, the design's "Enter's guessed action is named in the status line before it is pressed"), first, before the usual pane hints.

## How it works

- **Data** (`UI::Inspect`, `lib/mb/sound/ui/inspect.rb`): `Poll#call(needs)` gathers an `InspectInfo` into `Slow#inspector` only while a visible pane needs `:inspect` (`Follow` passes the feed's needs).  Graphs come from `Session#ui_graphs` (each current player's GraphNodeInput, under the players' mutex only, never the render lock); roots climb through Tees and from a multi-output node's outputs to the node with the recipe (a Synth's outputs to the Synth, whose `to_ruby` prints the whole synth).  Nodes are read with `Traversable#param_info`/`#param_snapshot` (settings only, never sampling; nodes with their own parameter API, like ChannelMixer's Unison, get a Params from `param_info`).  The node list, the knob names the graph reads (Knob readers in its graph, in order), and the code are cached per graph (by the roots' identity); each poll takes only the selected node's snapshot again, so its preview follows turns.  A node's knobs include those read through a few nodes of arithmetic (`lp4(knob(:cut) * lfo)` reads :cut).  Plumbing (Constants, Knobs and readers, Tees, Multipliers, Mixers, ProcNodes, note frequencies, synth outputs) is never listed.  `Inspect.target` (`{ track:, node: }`, set by the inspector's keys) is what the panes ask for; without one the inspector follows the clip matrix's track (`Clips.selected`), else the first player.  Measured on the Mac container (dnb_reese, 173 nodes): the first gather of a graph ~6-12 ms, cached polls ~0.4 ms.
- **Knob values** are the snapshot's (`Snapshot#knobs`, per buffer), so meters move with turns, follows, and MIDI.
- **Turning**: `UI::KnobTurns` (`ui/knob_turns.rb`), the racks pane's turning moved into a module both panes include: PaneKeys::Preview steps through `Session#preview_turn` while a key is held, one PaneKeys::Commit (`Session#gesture_line`) when it stops (TurnGesture), PaneKeys::Run `turn` lines for set values; a turn moves by 2% (0.2% fine) of the knob's position along its curve (`Spec#position`/`#value`: a cutoff moves evenly in pitch), stepped knobs (Integer ranges) by one step.
- **Typed values**: a key may return `PaneKeys::Ask[prompt, text, answer]`: the tiles open a prompt line (the palette's line editor, Router `:line`, returning to the pane's mode), and Enter hands the text to the pane's `key_<answer>(state, text)`, whose result is handled like a key's (the inspector's is a `turn :cut, <text>` line); Esc cancels.

## The render pane (sound-design-ui-2)

The maintainer, after the mock-up captures (2026-10-26): "a one-shot render of the processed waveform updated periodically when parameters change".  Round 1 rendered 3 s of the track's clip in a sandbox on a worker thread and was held: the live render thread's lag behind the clock went from p99 0.7 ms to ~10 ms during a held sweep (the GVL; dropout prevention is the goal).  Round 2 follows his answers ("render just the first few hundred ms, render at a lower sample rate closer to display resolution, render subset per display frame with rolling update"; "Single note trigger, based on either first note on clip or a guessed default based on target usage"; "Either next to or above the spectrogram").

`Panes::Render` (`render`, jump w; the right column between the code and the keys, weight 2, at least 8 rows) draws one note through a fresh instance of the inspected track's patch for 0.5 s (`PatchRender.seconds`, 0.1-20): the waveform's min/max envelope (two `area` marks from 0: C fills; a `band` mark's fill is Ruby) above its spectrum (a Welch average, 256 log-spaced points), side by side in a wide, short pane, the waveform alone below 10 rows and 90 columns (s cycles both, waveform, spectrum); the previous render of the same track faint behind both; on the first row the track, integrated LUFS, peak and RMS (dBFS, pre-master: master gain 1, like a stem), what played ("first note E1", "bass guess A1"), the length, and the render's time; ` …` while a newer render waits or runs.  Keys: s views, o overlay, p the role's guess instead of the clip's first note, + and - length, r again.

- **What renders**: the track's patch block called again in a sandbox Session like `Arrangement#warm_up`'s (the session's tempo, meter, key, tuning, copies of every knob), so the same code and sound as the live graph.  Considered: the recipe through `to_ruby` + `GraphIO.load` (not every graph round-trips) and preset documents with params (only presets).  Graph tracks say why they can't render.
- **Input** (`PatchRender.input`): one note.  The clip's first note (value, length, velocity, accent/slide/pitch marks), moved to the start; a Kit plays as it is (its first hits); without a clip (or with p) a note guessed from the track's role, matched on the track's name and its graph's code (so `preset :dnb_reese` reads as a bass): `ROLES` (an open question) kick C2 25% of the render, drums D2 25%, bass A1 60%, pad C4 90%, pluck/keys C4 30%, lead G4 60%, else C3 60%.
- **Cost** (`PatchRender::Server`, the default where `Process.fork` exists): his three ideas combined with the measurement that builds (~100 ms of Ruby each) were most of round 1's GVL waits.  One server process per patch and note, forked once (1-5 ms of GVL by the heap's size), builds the instance there and, with YJIT, builds and renders a throwaway second one so the render's code is compiled in the server (forked copies compiling it again took 480 ms instead of 145 ms a render).  Each render is a request on a pipe: the server forks a copy of the never-sampled instance, which sets the knobs (exact jumps before frame 0), renders, and pipes the figures back.  So knob turns never rebuild, every render starts from the same fresh state, and this process only writes the request and reads ~12 KB of figures.  The choice for fresh state per render, among those the brief listed: `plan_snapshot`/`plan_restore` covers only plan-describable nodes (14 classes; no Synth allocators, MIDI sources, Tees, delays), so it is not correct for every graph; a pool of instances built ahead pays a build per render; re-triggering a note on one instance carries phases and filter states over, so an unchanged knob would draw a different waveform.  A forked copy is exact (its samples equal an in-process render's, spec) and costs this process nothing per render.  Children leave with `exit!` (no ExitClose, no SimpleCov), with stdout/stderr to /dev/null, nice 10, GC off in the per-render copies; a copy taking 10 s is killed; a server's errors come back as the result line.  `PatchRender.fork = false` (`MB_SOUND_RENDER_FORK=0`), platforms without fork, and the UI specs' `inline` mode render in-process instead: a new instance per render, checked once per patch and note that a second build shares no node with the first (a patch reaching outside nodes would advance them; in a forked copy they advance only there), seeds from `Internal.with_private_rng`, live mode off on the thread (`Internal.strictly`), GCs held off, and the worker sleeping to keep to `PatchRender.duty` (0.5).
- **Lower sample rates** (his second idea): measured and not adopted.  Graphs reading knobs refuse other rates (`SampleRateSupportError` from dnb_reese's lp4), and on a knob-free 16-voice unison saw through lp4(1200 Hz) the envelope at 24 kHz differs from 48 kHz by up to 2.8% of the peak at 88 columns and 12% at 472 (a Braille dot of 8 rows is 6.2%); 16 kHz 5.8%/19%, 12 kHz 13%/37%.  So the display would not match the sound at a 236-column terminal's resolution, and with renders in another process the saving buys nothing here.
- **Rolling updates** (his third idea): not built.  It was for spreading an in-process render over display frames; a forked render reaches the pane whole in 70-150 ms (0.5 s of dnb_reese or the 16-voice synth), within a few frames, and costs this process nothing meanwhile.
- **When** (`PatchRender::Debounce`, a state machine with a transition table: idle, waiting, busy, dirty): 0.1 s after the last change of what decides a render (the track, its patch by identity, the input, the length, the values of the knobs the graph reads), at most every 0.2 s while changes keep coming, at once when nothing is shown for the track.  One render at a time; a change during one makes the next.  `Driver#tick` runs in the pane's draw (painter thread, ~10/s); a render of a track no longer inspected is dropped, and the overlay is only ever the same track's.
- **Where**: `PatchRender::Worker`, one thread per pane placement at priority -3 that talks to the server (or renders in-process), ending after 10 s idle and closing its server.

### Measurements (Mac container, 2026-10-26, YJIT as in bin/sound.rb)

| what | round 1 (3 s of the clip, in-process) | round 2 (one note, 0.5 s, forked) |
|---|---|---|
| dnb_reese per update | median 128 ms, max 240 | median 145 ms wall (in-process: 46), none of it on this process's GVL |
| 16-voice unison saw synth, 4 voices (worst case tried) | median 415 ms, max 424 | median 102 ms wall (in-process: 147) |
| build per knob turn | every render (~100 ms GVL) | none (once per patch and note, in the server) |
| painter, wave view cached (44x8 / 100x24) | 0.44 / 0.46 ms | same (both views: two cached draws) |
| live lag behind the clock, 512 frames (default profile), held sweep re-rendering the worst case, 4 x 6 s (the first round's start-up left out) | no renders: p99 0.7 ms, max 0.7-3.7; renders (duty 0.5): p99 9-12 ms | renders: p99 0.7 ms, max 0.7-0.9 (9.1 in the first round, the server's start), 22-23 renders shown per 6 s |
| same at 256 frames (`latency :low`) | renders: p99 9-12 ms, max 11-12 | no renders: p99 0.7, max 0.7-1.5; renders: p99 0.7-0.8, max 1.9-5.9 |

The residual max (a few ms at 256 frames, about once per round) is this process's part: the server's fork when the instance changes and reading each answer.

## Open questions (2026-10-26, for the maintainer)

Render pane (sound-design-ui-2, round 2): the ROLES table (notes and holds per role); the pane's place once tried (right column; at 120x40 it has room for the waveform only); forks on the native Mac (a forked child of a process that loaded CoreAudio must not call into it: ours only run Ruby and our C, and a crash there is only a failed render); effects' demo sources once the picker's auditions exist.


In the mock-up's README, numbered; the ones that change direction: whether `:sound` is the name, the console along the bottom, turning document params that aren't knobs (dnb_reese's `param :cutoff` when not bound to a knob: a rebuild, the "live literals" step), which track the inspector follows, the code panel as the graph's `to_ruby` versus the track's patch block, and which nodes get previews next (lp4/diode responses, envelopes, compander curves).

## Not built yet

The library picker and its side panel (library-core-1's index), auditions on CUE from the picker, the save key flow, A/B, dirty state and `diff`, favourites, morph/randomize; previews beyond filters and shapers; turning literals and document params (rebuilds); MIDI encoders beyond `learn` (an encoder bound to "the picked knob" would need a relative-CC knob mode).
