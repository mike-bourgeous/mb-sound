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
                |                       | render (min 6)
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
| `render` (jump w) | `Panes::Render` (plot) | an offline render of the track's patch: waveform (min/max envelope) or spectrum, LUFS, peak, RMS, the previous render faintly behind; renders again 0.25 s after the knobs it reads stop moving (see The render pane) | s spectrum, o overlay, p demo phrase, + - length, r again |
| `sound_keys` | `Panes::SoundKeys` | the inspector's keys (from its keymap, so they can't drift) and the planned ones, dim, marked later (/ find, a audition, Enter the picker's action, S save, b A/B, * favourite) | |

The status line names Enter's action while a pane's mode is on (`Tiles#enter_hint`: a pane's `enter_hint(state)`, the design's "Enter's guessed action is named in the status line before it is pressed"), first, before the usual pane hints.

## How it works

- **Data** (`UI::Inspect`, `lib/mb/sound/ui/inspect.rb`): `Poll#call(needs)` gathers an `InspectInfo` into `Slow#inspector` only while a visible pane needs `:inspect` (`Follow` passes the feed's needs).  Graphs come from `Session#ui_graphs` (each current player's GraphNodeInput, under the players' mutex only, never the render lock); roots climb through Tees and from a multi-output node's outputs to the node with the recipe (a Synth's outputs to the Synth, whose `to_ruby` prints the whole synth).  Nodes are read with `Traversable#param_info`/`#param_snapshot` (settings only, never sampling; nodes with their own parameter API, like ChannelMixer's Unison, get a Params from `param_info`).  The node list, the knob names the graph reads (Knob readers in its graph, in order), and the code are cached per graph (by the roots' identity); each poll takes only the selected node's snapshot again, so its preview follows turns.  A node's knobs include those read through a few nodes of arithmetic (`lp4(knob(:cut) * lfo)` reads :cut).  Plumbing (Constants, Knobs and readers, Tees, Multipliers, Mixers, ProcNodes, note frequencies, synth outputs) is never listed.  `Inspect.target` (`{ track:, node: }`, set by the inspector's keys) is what the panes ask for; without one the inspector follows the clip matrix's track (`Clips.selected`), else the first player.  Measured on the Mac container (dnb_reese, 173 nodes): the first gather of a graph ~6-12 ms, cached polls ~0.4 ms.
- **Knob values** are the snapshot's (`Snapshot#knobs`, per buffer), so meters move with turns, follows, and MIDI.
- **Turning**: `UI::KnobTurns` (`ui/knob_turns.rb`), the racks pane's turning moved into a module both panes include: PaneKeys::Preview steps through `Session#preview_turn` while a key is held, one PaneKeys::Commit (`Session#gesture_line`) when it stops (TurnGesture), PaneKeys::Run `turn` lines for set values; a turn moves by 2% (0.2% fine) of the knob's position along its curve (`Spec#position`/`#value`: a cutoff moves evenly in pitch), stepped knobs (Integer ranges) by one step.
- **Typed values**: a key may return `PaneKeys::Ask[prompt, text, answer]`: the tiles open a prompt line (the palette's line editor, Router `:line`, returning to the pane's mode), and Enter hands the text to the pane's `key_<answer>(state, text)`, whose result is handled like a key's (the inspector's is a `turn :cut, <text>` line); Esc cancels.

## The render pane (sound-design-ui-2)

The maintainer, after the mock-up captures (2026-10-26): "a one-shot render of the processed waveform updated periodically when parameters change".  `Panes::Render` (`render`, jump w; in the right column between the code and the keys, weight 1, at least 6 rows) draws an offline render of the inspected track's patch: the min/max envelope of every channel (two `area` marks from 0: C fills; a `band` mark's fill is Ruby, 1.3-3 ms a draw), the previous render of the same track faintly behind (what the last change did), and on the first row the track, integrated LUFS, peak and RMS (dBFS, the track pre-master: master gain 1, like a stem), the length and input, and the render's time; ` …` while a newer render waits or runs.  Mode keys: s the spectrum (a 256-point Welch average, the previous one behind), o the overlay, p the demo phrase instead of the track's clip, + and - the length (0.5-20 s; `PatchRender.seconds`), r again.

- **What renders** (`UI::PatchRender.render`): the track's patch block called again, in a sandbox Session like `Arrangement#warm_up`'s (the session's tempo, meter, key, tuning, copies of every knob at its value now), so it is the same code that built the live graph and the same sound.  Considered: the graph's recipe through `to_ruby` and `GraphIO.load` (works for graph tracks too, but 210/220 graphs round-trip and it prints and parses every render) and preset documents with their params (only presets).  Graph tracks (`bg :x, graph` without a `track` patch) say so instead of rendering.
- **Never the live graph**: a fresh instance only, never sampled on the render thread or under the render lock (the patch, clip, and transport values come from Poll: the arrangement's mutex).  The first render of a patch and clip builds it twice and renders only if the builds share no node (a patch reaching nodes made outside it would advance them; it says so instead).  The spec renders three times between buffers of a live session and compares it with a twin session that didn't: bit-identical.
- **Seeds**: `Internal.with_private_rng(SEED)` gives the worker thread its own root generator, so renders differ only by what changed and the live set's seed draws are untouched (the shared generator was why `warm_up` only runs while idle).  `Internal.strictly` turns live mode off on the thread: a patch's `live_error` is the result line, not a warning per render.  Major GCs are held off during a render (`GCQuiet`).
- **Input**: the track's own clip from its start (what the patch is made for: register, lengths, velocities, slides; a reese playing the demo's C4-C5 arpeggio is not the bass you're shaping), else `Playable.demo_phrase` (the C major arpeggio and chord auditions use); p switches.  Effects (a library entry's demo source, else a reference by tags) belong to the picker's auditions, which aren't built: a track's patch always takes a clip.
- **When** (`PatchRender::Debounce`, a state machine with a transition table: idle, waiting, busy, dirty): 0.25 s after the last change of what decides a render (the track, its patch and clip by identity, the demo flag, the length, the values of the knobs the graph reads), at most every 0.5 s while changes keep coming (a held sweep), at once when nothing is shown for the track.  One render at a time; a change during one makes the next.  `Driver#tick` runs in the pane's draw (painter thread, ~10/s) and takes finished renders there; a render of a track no longer inspected is dropped, and the overlay is only ever the same track's.
- **Where**: `PatchRender::Worker`, one thread per pane placement at priority -3, starting on the first render and ending after 10 s without one; renders in 256-frame buffers, sleeping after each so the render takes at most `PatchRender.duty` of wall time (0.5 by default; Ruby runs one thread at a time, and a render that never paused took the GVL from the live render thread whenever both had work: measurements below).  `PatchRender.inline` (UI specs and the golden captures) renders on the drawing thread.

### Measurements (Mac container, 2026-10-26, YJIT as in bin/sound.rb)

Measured with `/tmp`-scratch scripts (not kept; the numbers are what matters), alternating runs where they compare.

| what | result |
|---|---|
| dnb_reese, 3 s of its own bass clip, 256-frame buffers, unpaced | first render 630 ms (two builds, YJIT compiling), then median 128 ms, max 240 ms (~4% of the rendered time) |
| 16-voice unison saw synth, 4 voices of 7th chords, lp4 on the knob (worst case tried) | first 592 ms, then median 415 ms, max 424 ms (~14%); a worker at duty 0.5 takes about twice that |
| painter, wave view, cached chart (44x8 / 100x24) | 0.44 / 0.46 ms a draw (10 draws/s: under 0.5% of the painter); with a band mark 1.3 / 3.0 ms, so areas |
| painter, spectrum view, cached | 0.06 / 0.22 ms |
| painter, a new render shown (chart rebuilt) | 1.1 / 1.5 ms, once per render |
| live render thread, 256 frames, wall-clock paced NullOutput, dnb_reese playing, a held sweep re-rendering the worst-case synth; 4 rounds x 6 s, first round's start-up left out | without renders: write gaps p99 5.8-5.9 ms, lag behind the clock p99 0.7 ms, max 0.8-4.5 ms.  Renders unpaced (duty 1): gaps p99 14-15 ms, lag p99 10-11 ms, max 12-19 ms.  Duty 0.5 (default): gaps p99 10 ms, lag p99 9-12 ms, max 11-12 ms (one 67 ms outlier, a VM-minute-stall-sized one).  Duty 0.25: lag p99 5-7 ms, max 12-17 ms, but the worst-case synth rendered only every ~6 s |

So the render thread is not unaffected: while a render runs, it waits for the GVL up to ~10 ms (the worker's unpaced stretches are the patch builds, ~100 ms of Ruby each), which the default latency profile's 50 ms queue absorbs but `latency :low` may not.  An open question below.

## Open questions (2026-10-26, for the maintainer)

Render pane (sound-design-ui-2): pause renders while a low-latency profile plays, or render in a forked process (no GVL sharing at all; the patch block can't cross a fork boundary as data, but a fork inherits it); the clip versus the demo phrase as the default input; the pane's place (right column; a full-width strip would give the waveform more columns); effects' demo sources once the picker's auditions exist.


In the mock-up's README, numbered; the ones that change direction: whether `:sound` is the name, the console along the bottom, turning document params that aren't knobs (dnb_reese's `param :cutoff` when not bound to a knob: a rebuild, the "live literals" step), which track the inspector follows, the code panel as the graph's `to_ruby` versus the track's patch block, and which nodes get previews next (lp4/diode responses, envelopes, compander curves).

## Not built yet

The library picker and its side panel (library-core-1's index), auditions on CUE from the picker, the save key flow, A/B, dirty state and `diff`, favourites, morph/randomize; previews beyond filters and shapers; turning literals and document params (rebuilds); MIDI encoders beyond `learn` (an encoder bound to "the picked knob" would need a relative-CC knob mode).
