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
| `render` (jump w) | `Panes::Render` (plot) | one note through a second copy of the track's voice: a settled cycle, its spectrum, the envelope, LUFS, peak, RMS, the previous render faintly behind; renders again 0.1 s after the knobs it reads stop moving (see The render pane) | s views, o overlay, p guessed note, + - envelope length, r again |
| `sound_keys` | `Panes::SoundKeys` | the inspector's keys (from its keymap, so they can't drift) and the planned ones, dim, marked later (/ find, a audition, Enter the picker's action, S save, b A/B, * favourite) | |

The status line names Enter's action while a pane's mode is on (`Tiles#enter_hint`: a pane's `enter_hint(state)`, the design's "Enter's guessed action is named in the status line before it is pressed"), first, before the usual pane hints.

## How it works

- **Data** (`UI::Inspect`, `lib/mb/sound/ui/inspect.rb`): `Poll#call(needs)` gathers an `InspectInfo` into `Slow#inspector` only while a visible pane needs `:inspect` (`Follow` passes the feed's needs).  Graphs come from `Session#ui_graphs` (each current player's GraphNodeInput, under the players' mutex only, never the render lock); roots climb through Tees and from a multi-output node's outputs to the node with the recipe (a Synth's outputs to the Synth, whose `to_ruby` prints the whole synth).  Nodes are read with `Traversable#param_info`/`#param_snapshot` (settings only, never sampling; nodes with their own parameter API, like ChannelMixer's Unison, get a Params from `param_info`).  The node list, the knob names the graph reads (Knob readers in its graph, in order), and the code are cached per graph (by the roots' identity); each poll takes only the selected node's snapshot again, so its preview follows turns.  A node's knobs include those read through a few nodes of arithmetic (`lp4(knob(:cut) * lfo)` reads :cut).  Plumbing (Constants, Knobs and readers, Tees, Multipliers, Mixers, ProcNodes, note frequencies, synth outputs) is never listed.  `Inspect.target` (`{ track:, node: }`, set by the inspector's keys) is what the panes ask for; without one the inspector follows the clip matrix's track (`Clips.selected`), else the first player.  Measured on the Mac container (dnb_reese, 173 nodes): the first gather of a graph ~6-12 ms, cached polls ~0.4 ms.
- **Knob values** are the snapshot's (`Snapshot#knobs`, per buffer), so meters move with turns, follows, and MIDI.
- **Turning**: `UI::KnobTurns` (`ui/knob_turns.rb`), the racks pane's turning moved into a module both panes include: PaneKeys::Preview steps through `Session#preview_turn` while a key is held, one PaneKeys::Commit (`Session#gesture_line`) when it stops (TurnGesture), PaneKeys::Run `turn` lines for set values; a turn moves by 2% (0.2% fine) of the knob's position along its curve (`Spec#position`/`#value`: a cutoff moves evenly in pitch), stepped knobs (Integer ranges) by one step.
- **Typed values**: a key may return `PaneKeys::Ask[prompt, text, answer]`: the tiles open a prompt line (the palette's line editor, Router `:line`, returning to the pane's mode), and Enter hands the text to the pane's `key_<answer>(state, text)`, whose result is handled like a key's (the inspector's is a `turn :cut, <text>` line); Esc cancels.

## The render pane (sound-design-ui-2)

The maintainer, after the mock-up captures (2026-10-26): "a one-shot render of the processed waveform updated periodically when parameters change".  Three rounds:

- Round 1 rendered 3 s of the track's clip through its whole patch (Synth, clip, sandbox Session) on a worker thread; held: the live render thread's lag went from p99 0.7 ms to ~10 ms in a held sweep (builds were ~100 ms of Ruby holding the GVL).
- Round 2 rendered one note for 0.5 s in forked processes (one render server per patch, a forked copy per render); the lag came back to the no-render numbers.
- Round 3 (2026-10-27), his redesign: "I'm expecting that I will build up a patch from nodes. I had no problem with realtime rendering a waveform+filter for one cycle in the fft_experiment by just keeping two copies and calling sample one time on the second copy"; "one can reset every oscillator and filter in the copy, grab a bunch of cycles, and find the Nth cycle where N is long enough for the filter to be at steady state.  Maybe show a few cycles and/or adjust to zero crossings when using unison"; "The second copy can also run at a much lower sample rate for display, as long as it's not too close to filter frequency response warping territory".  What is built now, replacing the forks and the sandbox render:

`Panes::Render` (`render`, jump w; the right column between the code and the keys, weight 2, at least 8 rows):

- **The copy** (`UI::PatchRender::Copy`): one voice of the inspected graph's Synth, built by calling the live `Synth#voice_block` again (lane 0's index and seed, `Synth.with_lane`, so `per_voice` values and seeds match lane 0) with a `Notes` reading a `NoteFeed` (a MIDI::Source the render plays notes into).  Not a Synth, no clip, never in a Session's render.  `knob(:x)` inside the block resolves through a scope Session that is never rendered: it only holds copies of the session's knobs (at the copy's rate) and the tempo, meter, key, and tuning for build-time lengths; readers of live knobs that the block captured (a document param bound to a knob is resolved when the preset loads) are rebound to the copy's knob of that name, and a copy that still shares any node with the live graph is refused.  Plans are installed on it.  It is rebuilt only when the voice block, the note, or the session settings change (Job#copy_key); a knob turn sets the copy's knobs (exact jumps) and renders again.  The copy is built on the worker under `Internal.with_private_rng` (the voice block draws seeds; the shared generator would race scene builds) and `Internal.strictly`.
- **Reset**: one block of silence after the build (so every oscillator has made its state), then a snapshot of every node's `plan_snapshot` and of the note streams' state; each render puts them back (`plan_restore`, the feed and streams rewound to that stream time), so every render starts from the same state: the same knobs give the same samples.  Knobs and their readers keep counting forward (the values set before a render land on the next frame they read).
- **The cycle view** (`PatchRender.cycle`): the note held, sampled a few periods at a time; a period has settled once it differs from the one before by less than -40 dB after both are scaled to the same RMS (the next period read a fractional period later, linearly interpolated; slow envelopes don't count as change).  The view is that period from the first rising zero crossing of the channels' mix after it, plus a period's worth of samples to stop.  A note whose periods never repeat within 0.4 s (detuned unison copies, a moving LFO) shows 4 periods from a rising zero crossing at 0.4 s.  The settled sound's second half gives the spectrum.
- **The envelope view**: the copy reset again and the note played for `PatchRender.seconds` (0.5 s), held for the clip note's length or the role's share; min/max over 1024 columns; LUFS (measured a tenth of a second at a time), peak, RMS.
- **Input** (`PatchRender.input`): the clip's first note (number, velocity, length), else a guess from `ROLES` matched on the track's name and its graph's code: kick C2, drums D2, bass A1, pad C3 (the maintainer, 2026-10-27: "pad C3 to start probably"), pluck/keys C4, lead G4, else C3.
- **Rate** (`PatchRender.rate_for`): the lowest of 24, 32, 48 kHz at least 8 times every lowpass cutoff in the copy (four-pole, diode, lowpass SVFs; a cutoff that moves, an LFO or envelope on it, keeps 48 kHz, as does a voice with no lowpass or one that can't change rate).  Measured against the same copy at 48 kHz (a saw through lp4, and 16 detuned saws through lp4), drawn as the pane draws (each column's min and max): at 88 columns the cycle differs only by an edge landing one column over (0.0-0.9% of the peak once a column's shift is allowed; 6-24% without); at 472 columns 0.0-4.7% (a Braille dot of 8 rows is 6.2%).  12 and 16 kHz rounded the saw's edge visibly at 472 columns (12-23% beyond a column's shift), so the lowest rate is 24 kHz.  RMS within 0.03 dB, peak within 0.16 dB.  dnb_reese stays at 48 kHz (its cutoff has an LFO).
- **Views**: s cycles all that fit (the cycle above the spectrum above the envelope, 5 rows each at least; the cycle beside the spectrum in a wide, short pane; the cycle alone in a small one), the cycle, the envelope, the spectrum.  The first row: track, LUFS, peak, RMS, what played, "settled 18 ms" or "4 cycles", the copy's rate, the render's time.
- **When** (`PatchRender::Debounce`, a state machine with a transition table: idle, waiting, busy, dirty): 0.1 s after the last change (the track, the voice block, the input, the length, the values of the knobs the voice reads), at most every 0.2 s while changes keep coming, at once when nothing is shown for the track.  A render of a track no longer inspected is dropped; the overlay is only ever the same track's.
- **Where**: in this process, `PatchRender::Worker` (one thread per pane placement, priority -3, ending after 10 s idle and dropping its copy), in 128-frame blocks with a pause after each (a sleep keeping to `PatchRender.duty`, 0.5) and between the analysis steps (spectrum windows, loudness tenths), so no step holds the GVL for long: medians 0.1-0.3 ms between pauses, the longest steps a minor GC.  `PatchRender.inline` (UI specs, captures) renders on the drawing thread.

### Measurements (Mac container, 2026-10-27, YJIT as in bin/sound.rb)

| what | round 2 (forked) | round 3 (copy in-process) |
|---|---|---|
| dnb_reese per update (48 kHz) | 145 ms wall, none on this process's GVL | median 44 ms, max 62 (the first, with the copy's build: 227 ms, build 82 of it) |
| a saw through lp4 on the knob (24 kHz) | - | median 4.6 ms (settled after 18 ms) |
| 16 detuned saws through lp4 (24 kHz; worst case tried) | median 102 ms wall | median 18.5 ms, max 23 (48 kHz: 30 ms) |
| build per knob turn | none | none (once per voice block and note: 8-95 ms) |
| painter, all views, charts kept (44x9 / 44x16 / 100x24) | - | 0.42 / 0.27 / 0.33 ms a draw |
| live lag behind the clock, 512 frames (default), held sweep previewing dnb_reese, 4 x 6 s, the first round's start-up left out | p99 0.7 ms, max 0.7-0.9 (no previews: p99 0.7, max 0.8-1.0) | p99 1.0-1.8 ms, max 2.0-3.3 |
| same, 256 frames (`latency :low`) | p99 0.7-0.8, max 1.9-5.9 (no previews: p99 0.7, max 0.7-1.0) | p99 0.8-1.3 ms, max 1.9-5.1 |
| the round that builds the copy (once per voice and note) | - | p99 3.7-4.6 ms, max 10.6-11.3 (the build: one unpaused stretch) |

Between rounds 1 and 3, the per-render GVL work fell from ~100 ms builds to blocks of 0.1-0.3 ms.  What's left over the no-preview numbers is the pauses' granularity and minor GCs from the render's ~16k objects; the copy's build (when the voice block or note changes) is one stretch of 8-95 ms, at the 10 ms GVL timeslice.

## Open questions (2026-10-26, for the maintainer)

Render pane (sound-design-ui-2, round 3): the ROLES table (notes and holds per role); voices of graphs without a Synth (no voice block to call: a `bg :pad, sound` graph says so) and what follows a synth (a reverb after it isn't in the voice); the copy's build as one stretch (8-95 ms) when the voice block or note changes; the pane's place once tried (at 120x40 it has room for the cycle only); effects' demo sources once the picker's auditions exist.


In the mock-up's README, numbered; the ones that change direction: whether `:sound` is the name, the console along the bottom, turning document params that aren't knobs (dnb_reese's `param :cutoff` when not bound to a knob: a rebuild, the "live literals" step), which track the inspector follows, the code panel as the graph's `to_ruby` versus the track's patch block, and which nodes get previews next (lp4/diode responses, envelopes, compander curves).

## Not built yet

The library picker and its side panel (library-core-1's index), auditions on CUE from the picker, the save key flow, A/B, dirty state and `diff`, favourites, morph/randomize; previews beyond filters and shapers; turning literals and document params (rebuilds); MIDI encoders beyond `learn` (an encoder bound to "the picked knob" would need a relative-CC knob mode).
