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
| `sound_keys` | `Panes::SoundKeys` | the inspector's keys (from its keymap, so they can't drift) and the planned ones, dim, marked later (/ find, a audition, Enter the picker's action, S save, b A/B, * favourite) | |

The status line names Enter's action while a pane's mode is on (`Tiles#enter_hint`: a pane's `enter_hint(state)`, the design's "Enter's guessed action is named in the status line before it is pressed"), first, before the usual pane hints.

## How it works

- **Data** (`UI::Inspect`, `lib/mb/sound/ui/inspect.rb`): `Poll#call(needs)` gathers an `InspectInfo` into `Slow#inspector` only while a visible pane needs `:inspect` (`Follow` passes the feed's needs).  Graphs come from `Session#ui_graphs` (each current player's GraphNodeInput, under the players' mutex only, never the render lock); roots climb through Tees and from a multi-output node's outputs to the node with the recipe (a Synth's outputs to the Synth, whose `to_ruby` prints the whole synth).  Nodes are read with `Traversable#param_info`/`#param_snapshot` (settings only, never sampling; nodes with their own parameter API, like ChannelMixer's Unison, get a Params from `param_info`).  The node list, the knob names the graph reads (Knob readers in its graph, in order), and the code are cached per graph (by the roots' identity); each poll takes only the selected node's snapshot again, so its preview follows turns.  A node's knobs include those read through a few nodes of arithmetic (`lp4(knob(:cut) * lfo)` reads :cut).  Plumbing (Constants, Knobs and readers, Tees, Multipliers, Mixers, ProcNodes, note frequencies, synth outputs) is never listed.  `Inspect.target` (`{ track:, node: }`, set by the inspector's keys) is what the panes ask for; without one the inspector follows the clip matrix's track (`Clips.selected`), else the first player.  Measured on the Mac container (dnb_reese, 173 nodes): the first gather of a graph ~6-12 ms, cached polls ~0.4 ms.
- **Knob values** are the snapshot's (`Snapshot#knobs`, per buffer), so meters move with turns, follows, and MIDI.
- **Turning**: `UI::KnobTurns` (`ui/knob_turns.rb`), the racks pane's turning moved into a module both panes include: PaneKeys::Preview steps through `Session#preview_turn` while a key is held, one PaneKeys::Commit (`Session#gesture_line`) when it stops (TurnGesture), PaneKeys::Run `turn` lines for set values; a turn moves by 2% (0.2% fine) of the knob's position along its curve (`Spec#position`/`#value`: a cutoff moves evenly in pitch), stepped knobs (Integer ranges) by one step.
- **Typed values**: a key may return `PaneKeys::Ask[prompt, text, answer]`: the tiles open a prompt line (the palette's line editor, Router `:line`, returning to the pane's mode), and Enter hands the text to the pane's `key_<answer>(state, text)`, whose result is handled like a key's (the inspector's is a `turn :cut, <text>` line); Esc cancels.

## Open questions (2026-10-26, for the maintainer)

In the mock-up's README, numbered; the ones that change direction: whether `:sound` is the name, the console along the bottom, turning document params that aren't knobs (dnb_reese's `param :cutoff` when not bound to a knob: a rebuild, the "live literals" step), which track the inspector follows, the code panel as the graph's `to_ruby` versus the track's patch block, and which nodes get previews next (lp4/diode responses, envelopes, compander curves).

## Not built yet

The library picker and its side panel (library-core-1's index), auditions on CUE from the picker, the save key flow, A/B, dirty state and `diff`, favourites, morph/randomize; previews beyond filters and shapers; turning literals and document params (rebuilds); MIDI encoders beyond `learn` (an encoder bound to "the picked knob" would need a relative-CC knob mode).
