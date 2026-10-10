# Arrangement and the Session groundwork

Phase 1 of the arrangement plan (branch `arrange-1`, 2026-10-10): the shared Session groundwork ("G0") and the Set layer.  Phase 2 (branch `arrange-form`, 2026-10-10): ring-outs, song forms (`flow`), follow actions and performer controls, fills, the marker table, and the meter map (sections below the Set layer).  CLAUDE.md keeps a summary and points here.  Update both when behavior changes.

Sources: the study on branch `research-arrangement` (`research/arrangement/README.md`, prototype in `prototype/`), the interconnect contracts K1-K10 on `research-plan-interconnect` (`research/plan-interconnect/README.md`), and the maintainer's decisions of 2026-10-10 (quoted below).

## Session groundwork (G0)

Built to the interconnect contracts so the terminal UI and glhtui can use it later; only what phase 1 needs is built.

- **Stamps (K1)**: `Session::Stamp` (`lib/mb/sound/session/journal.rb`) = `frame` (session frames since the Session was created; monotonic, never reset by seeks, rewinds, or tempo changes; `Session#frame`) + `pos` (Rational whole notes), plus `bar_length` for display only.  Shown as `bar:beat` (`9:1`, `13:2.5`), never parsed.  `Session#clock` is the stamp of the next frame (where a change made now lands); `Session#transport_record` is the per-buffer `{frame, pos, bpm, bar_length, playing}`.
- **Journal (K3)**: `Session::Journal` keeps up to 10,000 `Journal::Entry`s (`seq, kind, subject, issued, commits, lands, status, source, line, data, undoes`); status is `:queued`, `:landed`, `:cancelled`, or `:failed`, and a status change is a new entry with the same `seq` (`journal.entries` has all of them, `journal.changes` the latest per change, `journal[seq]`).  `subscribe { |entry| }`.  The render thread only pushes small notes onto a `Thread::Queue`; they become entries when the journal is next read or written.  Entries print as `bg :bass lands 9:1 (queued)`; `entry.name` is the subject.  Sources: `:console`, `:schedule`, `:replay`, `:undo`, `:set`.
- **Change queue** (`session/changes.rb`): every change to what plays goes through `Session#change(kind, subject, time, data:) { |t| ... }`: `add` (`:bg`), `remove` (`:stop`), `resume`, `swap`, `master`, mute/solo, `:restore` (undo), `:scene`.  A change landing now applies right away; a future one waits in a sorted queue (time, then issue order) and is applied at the start of the buffer that holds its time, on its exact sample (`commit_due`, after scheduled blocks run, before players render).  This fixed the study's finding 2: a clip source holds one pending swap and a player one stop time, so `swap :bass, b, on: 4` then `swap :bass, c` lost the first swap; queued graphs, stops, swaps, and master chains for one name now all land.  Validation errors (no such player, unrelated clips) still raise when the command is made; a queued change that fails when it lands is journaled `:failed` and printed (raised with `raise_errors`).
  - Changes apply under a render lock (a `Monitor` that `process_buffer` holds until the mix is done, released before `output.write`), so a console change lands exactly at the next buffer's start, and the journal says where.  Lock order: render lock, then the session mutex.
  - `players` lists graphs waiting to start ("starts at bar N") and queued stops; `idle?`, the timeline, and new player numbers count queued starts; a stop for now cancels queued starts of that name; a queued start after a queued stop plays (the old code dropped graphs that "would never have played").
  - `Session#queued(name)`, `#cancel_changes(*seqs)`, `#playing_after_queue?(name)`, `#timeline_nodes_of(name)`.
- **Launch points count from `Session#now`**: the scheduled block's time inside `at_bar`/`after`/`every` blocks (finding 1: `at_bar(5) { bg :x, g, on: :beat }` landed a beat and a half early, because the scheduler runs blocks up to half a bar ahead), a take's recorded issue time while it replays, and the transport position otherwise.
- **Exact fades** (`session/fades.rb`): fades and mute ramps are `Fades::Ramp`s counted in session frames from their first sample (level `k * slope + from` at frame offset k, so any buffer size gives the same levels), and fade-outs start on the exact sample of their stop time (they used to start at the next buffer start).  Levels are cast to SFloat before multiplying audio (Numo's SFloat * DFloat is ~20x slower).
- **Commands return journal entries**: `bg`, `swap`, `resume`, `master`, `mute`/`solo`, `go` return the change's entry (`stop`/`panic` still return names; inside scheduled blocks commands return names); `stop`/`swap`/`resume`/`mute` accept an entry in place of a name.  Every console command (and every scheduled block's batch) is one undo step (`Session#command(label) { }`).
- **Names (K2)**: `Session::Names` (`session/names.rb`): tracks, mute groups, and later knobs share one namespace; `:master` and `:cue` are reserved; a name claimed for two kinds goes through `MB::Sound.live_error` (maintainer decision 6).  `Names.path(:bass, :cut, 3)` is `"bass/cut/3"` (display and files only).
- Not built yet (later projects): the player strip's gain and route stages (K7; mute/solo is built), the session stream (K4), knobs (K6).  Markers (K8) arrived in phase 2 (below).

## Mute and solo (`session/strip.rb`)

Maintainer, 2026-10-10: "Sleep; softmute now; use or extend existing fade functionality for synced fades or mutes".

- `mute`/`unmute`/`solo`/`unsolo` (Session and console) take player names or mute groups (`mutes :breakdown, :drums, :bass`, alias `mute_group`).  Right away by default with a 5 ms declick (`Fades::DECLICK_SECONDS`), or at a launch point (`on: :bar`, `in: 1.beat`, `at: bar(17)`) over a `fade:` in bars (a synced fade), through the change queue.  `solo` with no names clears every solo, and `unmute`/`unsolo` with no names everything, resolved when the change lands (subject `:strip`), so a solo still in the queue isn't missed (the demo render found this).
- Flags belong to names, so a graph replacing a muted one starts muted.  The strip runs fade, then mute/solo (K7 order; gain and routes come later).
- A silent player sleeps: its graph isn't rendered (no CPU).  A mute ramp ending inside a buffer stops reading on its last frame, so oscillators fall asleep at the same sample at any buffer size.  On the unmute sample its timeline nodes restart there like after a seek (clips and tempo-locked tones come back in time); everything else is stale.
- Cost per 800-frame buffer (median, 2026-10-10): 64 constant players 1013 us unmuted, 55 us all muted (asleep), 1858 us all ramping (~13 us per ramping player); 64 ramp+lp4 tracks 2769 / 52 / 3698 us (`/tmp` bench in the arrange-1 report).

## Undo (`session/undo.rb`)

Maintainer: "Raw commands also, and yes, CPU permitting"; quantized to the next bar by default.

- Each change snapshots its subject as it lands: `PlayerState` (current Player, stopped Player, each clip source's clip, mute/solo flags), `MasterState` (the chain's block), `StripState` (all flags, for `:strip`).  `undo` issues `:restore` changes that put each subject back to its state before the step's first change, at the next bar (`on: :now` right away), through the change queue (exact, journaled with `undoes:`, replayed by takes).  Graphs come back as the same objects (stale state, as with `resume`) with a 5 ms declick crossfade; master chains are rebuilt from their blocks; Set state (track clips, current scene) through participants (`Session#note_undo_extra`, `Arrangement#restore_undo_state`).
- A step whose changes haven't landed (by the logical time, `Session#now`) is cancelled right away; `redo!` queues them again.  Undo and redo are symmetric (each pushes the reverse step on the other list).  Steps print as `undo go :drop lands 9:1`; `changes` lists them (`history` is a Pry command).
- Bounds: 64 steps, and at most 8 retired graphs (neither playing on nor resumable) held by the lists (oldest steps dropped).  Measured live heap (`ObjectSpace.memsize_of_all`) with 8-voice `sq80_voice` Synths replaced 16 times: 13.6 MB at limit 0, 74.7 MB at 8, 134.6 MB at 16, i.e. ~7.5 MB per retired graph, ~60 MB worst case at the bound.  A snapshot of that player takes 4 us; a console mute with journal, snapshots, and pruning ~170 us.
- Later (graph-io): undo could keep recipes instead of live graphs.

## The Set layer (`lib/mb/sound/arrangement.rb`, console `ArrangementMethods`)

Maintainer: "Yes, with a realtime demo script that shows a set being sculpted".  One `Arrangement` per Session (`Session#arrangement`).

- `track :bass, q: 1 do |clip| patch end` (alias `define_track`) or `track :pad, graph`: a named player remembering its patch or graph, its clip, launch quantization `q:`, and `fade:`.  `bg :bass, clip` on a track with a patch builds the patch with that clip.  `tracks` lists them.
- `scene :verse, pad: chords, bass: bass_a, drums: beat` (alias `define_scene`): a full state; values are a Clip or Kit, `:on`, `:off`/`nil`, `:cut`, or `:keep`; tracks not named stop unless `others: :keep` (partial scenes like fills and risers); a block runs at launch with commands landing at the launch time.  Stopping tracks ring out (phase 2, below) unless `others: :cut` (or the value `:cut`) or a fade.  `scenes` lists them (current one marked).
- `go :drop` (alias `launch_scene`, `on:`/`in:`/`at:`, `fade:`): each track changes at its own launch point (the call's `on:`/`in:`/`at:`, then the track's `q:`, the scene's `q:`, the set's `quant`, 1 bar by default).  Only differences change: a patch track already playing swaps clips (keeping graph and effect state), rebuilding when swap can't map the clips or a Kit brings rows the old kit lacks; a track playing the scene's clip is left alone; stops ring out (phase 2) unless the scene says `others: :cut` (5 ms declick) or the scene, call, or track gives a fade.  One undo step; returns the `:scene` journal entry (`scene :drop lands 13:1 (queued)`).
- Track and scene `q:` and `quant` are alignments (`on:` values): `:now`, `:beat`, `:bar`, `:clip`, a Duration, or a number of **bars** (fades are bars too).
- Scene keys naming a non-track (e.g. a mute group) go through `live_error`; unknown tracks raise at `go`.
- Reserved, not built (later phases): `turn`/`move` (knobs, phase 3).  Forms are below.

## Launch points: `on:`, `in:`, `at:` (`lib/mb/sound/launch_point.rb`)

Maintainer, 2026-10-10 ("Do we have a name for alignment vs placement elsewhere? Eg on vs in"; "Yeah, make that change in bg"): `at:` used to mean alignment everywhere with different units (`bg ... at: 4` was the next quarter note, Set `at: 4` the next 4-bar line).  Now every command that lands a change (`bg`, `swap`, `resume`, `master`, `mute`/`unmute`/`solo`/`unsolo`, `go`, `undo`/`redo!`, their Session methods, `Arrangement#go`/`#play`) takes three keywords, and plain numbers are bars everywhere:

```ruby
go :drop, on: :bar                # alignment: :now, :beat, :bar, :clip, 4 (bars), 1.n4, 2.beats
go :drop, in: 2.bars              # relative placement from Session#now (bars, Durations, Lengths)
go :drop, at: bar(33)             # absolute placement: bar(n, beat: 1), counting from 1 like at_bar
go :drop, in: 2.bars, on: :beat   # two bars from now, then the next beat
```

- Order: start from `Session#now`, add `in:` or jump to `at:`, then align forward to `on:` (ceil; a time already on the grid stays).  Without `on:`, a change still aligns the way it would without `in:`/`at:` (maintainer, 2026-10-10: "Tracks should keep the same time alignment they would have otherwise"): `bg`/`swap`/`resume`/`master` to `:now` if idle, else `:bar` (so `bg :x, g, in: 2.bars` lands on the bar line after two bars while something plays); Set tracks to their effective `q:` (track, scene, `quant`), each on its own; mutes/solos not at all (exactly at `in:`/`at:`, right away without them); `undo` to `:bar`.  Write `on: :now` for an exact offset or position.  Take replays force recorded landing times, so they stay exact.
- `at:` takes only `bar(n)`/`bar(n, beat:)` (and alignment Symbols as aliases of `on:`, "at the bar").  Through `live_error`: a plain number (suggesting `on: 1.n4` / `on: 4` / `in: 4` / `at: bar(4)`), a Duration or Length (maintainer: "Agreed"; `at: 32.bars` would have been bar 33; the message points to `bar(n)`; they stay valid in `in:` and `on:`), `at:` with `in:`, `at: :bar` with `on:`, `in: bar(n)`, and a position that has already passed (maintainer: "live_error"; live, it warns and lands now; a replaying take lands it now silently, where the take forces it).  `at_bar` blocks keep warning and skipping for passed bars (unchanged: raising there could break scripts that schedule blocks after playback has moved on).
- One resolver: `LaunchPoint.of(binding)` reads the keywords (the only place that reads the `in` keyword), validates, and returns a frozen `LaunchPoint` (nil if skipped in live mode); console methods pass it down as `at:`; `Session#launch_time(point, nodes, default:)` and `Arrangement#resolve(q, track, point)` (the effective `q:` as the default alignment) call `LaunchPoint#resolve`.  Landing samples are unchanged for equivalent inputs (old `at: 4r` = `on: 4`; the take replay spec still matches bit for bit).
- Name check for the console `bar(n)` (`ScheduleMethods#bar`, returns `LaunchPoint::Bar`): no collision with `MB::Sound`, `Kernel`, `GraphNode`, or Pry commands; `Numeric#bar` (`1.bar`, a Duration) lives on a receiver.

## Takes (`lib/mb/sound/take.rb`, `take/replay.rb`)

Maintainer: takes on by default; "Repo sets if standalone or requested, user data directory otherwise, with file path printed".

- `MB::Sound::Take.current` records every console line (Pry `:before_eval`/`:after_eval` hooks in `bin/sound.rb`, started after `warm_up`) with its issue Stamp and where each change it made landed.  `take` shows the last lines; `take.entries` their journal entries; `take.restart`.
- `take.save(path = nil, repo: false)` writes an executable replay script: explicit path, else `take.home`, else `sets/` with `repo: true`, else the user data dir (`$XDG_DATA_HOME`/`~/.local/share/mb-sound/takes`, macOS `~/Library/Application Support/mb-sound/takes`); prints the path.  Lines starting with foreground or display commands (`play`, `plot`, `vis`, `wait`, `take`, `players`, ...) stay as comments.  `take.form` prints a note (forms are phase 2) and returns the scene launches.
- `Take::Replay` restores tempo, bar length, master gain, default fades, and the root random generator (Marshal), then schedules each line at min(issue time, landings) in a fresh console-like binding (`Take.console_binding`), with its landing times forced on its changes (`Session.with_perform(forced:, now:)`) and `Session#now` = the issue time, so undo/cancel decisions match although lines run ahead.  The saved script renders with `-o file` (`-b 367,368` cycles buffer sizes) or plays.
- Measured (spec/lib/mb/sound/take_spec.rb, 960 buffers of tracks, scenes, mutes, solos with fades, two queued changes on one track, undo of a queued change, stop + undo now, a mute group fade): clip and constant sources replay bit for bit at buffer sizes 800, 367/368, 64, 1001/13; band-limited tones exactly at the live buffer size and within 3.7e-9 (-151 dB re peak) at others (Tone phase accumulates per buffer).
- Not exact: tempo and master gain changes (applied at buffer starts / when the line runs), nondeterministic code, live MIDI input.

## Ring-outs (`lib/mb/sound/session/tails.rb`, phase 2)

Maintainer, 2026-10-10 ("Queue ringdown for p2"): when a scene drops a clip-driven track, the clip stops sending notes, the graph keeps rendering until it is silent, capped, then the track sleeps.

- `Session#remove(name, ring: true)` (console `stop :bass, ring: true`; the Set's default for tracks a scene stops): on the exact sample of the stop time every `MIDI::ClipSource` in the graph swaps to `Clip.silent` (notes in progress get note-offs there) and the player keeps rendering.  It sleeps (retired and kept for `resume`) once its output stays below `Master::TAIL_THRESHOLD` (-90 dB) for `RING_QUIET_SECONDS` (= `TAIL_QUIET_SECONDS`, 1 s), cut on the sample where that stretch ends, so the sleep frame is the same at any buffer size (spec: 800, 367, 64).  After `Master::MAX_TAIL_SECONDS` (10 s) a `TAIL_FADE_SECONDS` fade starts on that exact frame.
- The real clips come back when the player sleeps (`ClipSource#ring_out`/`#end_ring_out`/`#ring_clip`); swaps and undo snapshots see the ring clip, and a swap of a ringing source changes the clip it will play again.
- Graphs without clip sources (drones, files, raw oscillators) fade over `RING_DRONE_FADE` (1/4 bar).  Graphs whose sound doesn't come from notes but that do read clips (a `tween`-driven riser) ring to the cap: give their track a `fade:` (the demo's riser does).
- Launching the same graph while it rings (resume, undo, a scene bringing a patch track back with the same clip, a graph track) revives the ringing player (no second copy; its notes come back at the launch).  A later cut or fade takes over from a ringing tail; a muted ringing player sleeps right away.
- Journal: the stop's data is `{ ring: true }`; a `:rung_out` entry (source `:session`, data `seconds:`, `capped:`) is noted from the render thread when the tail ends (`Journal#note_entry`).  `players` shows "(ringing out)".  Takes replay ring-outs exactly (the stop's landing is forced; the tail is the graph's own output).
- Cost (2026-10-10, 800-frame stereo buffers): following one ringing player 12 us per buffer (fast paths for silent buffers and buffers ending loud; 42 us before them); the graph's own render as before.

## Song forms (`lib/mb/sound/form.rb`, `form/`, console `FormMethods`)

Maintainer, 2026-10-10: "I'd vote for the block builder" (`flow` alias of `form`; strings withdrawn), follow actions "use best judgement", fills "close; may tweak after it's built".

```ruby
flow do
  fill :turn, every: 8                         # a phrase fill (below)
  intro  4.bars
  verse  8.bars, times: 2, next: { chorus: 3, drop: 1 }   # weighted follow action
  chorus 8.bars, fill: :roll
  repeat 2 do
    verse
    chorus
  end
  drop   16.bars, fill: [:riser, 4.bars]
  outro  8.bars, next: :end
end
```

- Builder (`Form::Builder < BasicObject`, `instance_exec`): the first call with a length declares the section (a singleton method on the builder) and plays it; bare calls play it again (`verse`, `verse times: 2`); the same declaration again also plays it; a different one raises.  `method_missing` only declares: a bare unknown name is a `NoMethodError` whose message suggests names (`DidYouMean::SpellChecker`; did_you_mean's own method checker needs `#methods`, which BasicObject lacks).  Section names can be anything except `repeat`, `fill`, and keywords (`break`, `next`, `redo`: write `breakdown`).
- Options: `times:`, `next:` (`:next` default, `:again`, `:end`, a section name, a Hash of weights whose keys are any of these, a Proc given a read-only `Form::State` with `section`, `pass`, `plays(name)`, `history`, `bars`, `previous`), `fill:` (below), `scene:` (the scene launched; the section's name by default, `false` for none), `fade:`.  Lengths are Durations or plain numbers of bars (counted through the meter map where the section starts; Durations are fixed whole notes).  Trap: `verse 8.bars * 2` is one 16-bar verse (spec'd).
- `section :verse, 8.bars, next: ...` (console, `Arrangement#section`) declares a section outside a flow; bare calls in later flows play it.  `flow(play: false) { }` builds without playing; `play_form(form)`.
- `Form#to_ruby`/`#inspect` print the flow block back; `eval` of it builds an equal Form (`Form#==` compares the code).  Procs print as a commented placeholder.  `take.form` returns a linear Form of what played (passes as `times:`, follow actions dropped, `next: :end` if it ended; without a form, scene launches as sections lasting until the next launch).
- Playback (`Form::Playback`, `Arrangement#playback`; `flow` with no block shows it: `▶ a pass 1/1 (bar 2 of 4), next :b at 5:1 (open)`): each pass launches its section's scene on the pass's first sample (`go scene, on: :now` in a scheduled block; the scene's block may change the meter before the section's length is counted), sets phrase fills and a `:section` marker, and schedules the commit point and the boundary.  A form starting now launches its first section right away (a scheduled block would run a buffer later when idle, which made take replays a buffer late).  `next: :end` rings every player out at the boundary.  Scenes are checked at start (a missing one goes through `live_error`), follow actions must name sections of the form.
- Jumps to a section go to its next occurrence in the play order after the current step (wrapping); `:next` past the last step ends the form.

### Follow actions, commit points, and controls

- Commit point of a pass: the start of its fill, else its end (the bar line where the next section starts).  Controls issued before it (by logical time, `Session#now`) change that boundary; after it, the following one.  The decision runs in a scheduled block, which the scheduler runs up to half a bar early; a control arriving after the block ran but before the commit point re-decides it (the queued fill scene is cancelled and the Set state restored), so the boundary a control applies to depends only on its time and takes replay the same way (spec: a goto inside the lookahead window replays bit for bit at 800 and 367/368).
- Chance: `Random.new(seed * 1_000_003 + passes played)`, the seed from `MB::Sound.next_seed` (takes restore the root generator) or `flow(seed:)`; live, replayed, and re-decided commits draw the same numbers.
- Console (`FormMethods`; names checked against `MB::Sound`, Object/Kernel, and Pry's commands, spec'd): `loop!` (alias `loop_section`; repeats the section until `onward`, alias `unloop!`, `continue_form`; the maintainer: "loop! preferred over hold, you pick the inverse name"), `goto :drop` (`goto_section`), `finish` (`finish_form`; the last step next), `skip` / `skip :x` (`skip_section`; leave at the next bar line, honoring a pending goto/finish, ending a loop), `seek :chorus` (a section of the playing form from the next bar line, the timeline keeps running; otherwise a marker moves the timeline), `practice :drop` (`rehearse`; goto + loop!).  Each returns a `Playback::Decision` (`next :c at 5:1 (open)`).

### Fills

- A section's `fill:` plays in its last bar by default (`fill: :roll`), for a length (`fill: [:riser, 4.bars]`), alternating names per pass (`fill: [:a, :b]`, `[:a, :b, 2.bars]`), or only when leaving (`fill: { names: [:z], on: :leave }`; default `on: :pass`, every pass including `times:`, `:again`, and `loop!` repeats).  A fill whose name is a scene launches it at the fill's start (a partial scene like a riser; the next pass's scene, a full state, takes it away).  The fill is set at the commit point.
- Phrase fills: `fill :big, every: 16` (`length:` default 1 bar, `layer:`) in the flow plays fill `:big` at the end of every 16 bars from each section's start.  Only clips with fill marks react (no scenes: nothing would take a scene away mid-section).
- `Sequence::FillMap` (`Transport#fills`): intervals with priorities; a section's fill beats phrase fills, a longer period beats a shorter one ("Fizzbuzz for drums almost"), `layer: true` plays alongside.  A form prunes fills that ended over a whole note before each section start.
- Note marks (Elektron's FILL condition; `sequences.md`): `Event#fill_mark` / `Seq::Step#fill_mark` = `[:fill or :nofill, name]`; `C4.fill`, `C4.fill(:big)`, `.nofill`, `Seq#fill`/`#nofill`, `Clip#fill` with no argument or a Symbol (`fill(span)` still repeats to a span), `Clip#nofill`, `Kit#fill(name, rows / Kit / block)` layering fill rows onto the kit (`beat.fill(:turn) { grid(16, clap: '....X...x.x.xXXX') }`), `Kit#nofill(*rows, name:)`.  `Clip#edges(fills:)` keeps or drops marked notes by the fills at each note-on (`ClipSource` maps clip positions to the timeline); without a form nothing is a fill.  Cost: 26 us vs 25 us per 800-frame read of a 16-step marked row (177 us before only events in the window asked).

## Markers (`lib/mb/sound/session/markers.rb`, K8)

One table per Session (`Session#markers`), name -> `Marker(kind, pos or seconds)`: `:section` (forms register each section where it starts, and the next section when it is committed), `:position` (`marker :vo, at: bar(5, beat: 2)`), `:time` (`marker :hit, at: 12.5.seconds`, any Length; absolute times that don't move with the tempo, converted at the current tempo when used since ramps don't exist yet).  `markers` lists them; `at_marker(:drop) { }` runs a block at the marker if it is ahead, else the next time it is set ahead of now (e.g. when a form next reaches the section); `seek :name` moves the timeline to a non-section marker.  Marker files/imports: later.

## Meter map (`Sequence::Transport#meter`, `tempo_sync.md`)

Maintainer: "As recommended".  `Transport#meters` is a list of `Meter(pos, bar_length, bar)`; bar numbers count through it, so `meter 7, 8` (console, alias `time_signature`; at the next bar line or a launch point aligned to a bar line) doesn't renumber the bars before it.  `bar(n)`, `at_bar`, `after`, `every`, `seek(n)`, `:bar` and N-bar alignments (bar lines whose number is 1 more than a multiple of N), `in: N` bars, stamps (`Stamp.at`, `meter_pos`/`meter_bar`), scheduler descriptions, `render(bars:)` (the end bar read every buffer), forms (plain-number lengths), and takes (`meters:`) use it.  `Transport#bar_length=` sets one meter for the whole timeline.  Not converted: `Numeric#bars` Durations (whole notes at the global transport's current bar length), fade lengths in bars, script_runner's `--bars` end.

## Demo

`bin/songs/night_bus_set.rb`: 48 bars performed command by command (scenes, a riser as a partial scene, a mistake undone on the next bar, mute/solo breaks, a mute-group drop-out, a synced mute fade); `night_bus_set` alone sets up tracks and scenes to play by hand.  Grow it with each phase.  Listening renders: `/app/tmp/listening/arrange-1/`.

Phase 2: `bin/songs/night_bus_flow.rb` ("Night Bus: Last Stop", 126 BPM tech house in A minor, 89 bars + ring-out): the song as a `flow` block (intro, groove looped with `loop!`/`onward`, build with a riser fill, a 2/4 gap bar whose scene sets the meter and rings everything out, drop, pickup with `next: { breakdown: 3, drop: 1 }`, breakdown with a master highpass "cut", lift, drop2 as an anti-drop, pickup2 ended by `finish`, outro `next: :end`), `fill :turn, every: 8` playing the kits' fill rows.  `last_stop` sets up tracks and scenes, `last_stop_form` plays the form, `last_stop(perform: true)` the performance.  Section RMS with the default seed (dBFS, -10 dB master): intro -28.7, groove -25.5, build -26.6, gap -34.3, drop -23.7, pickup -23.4, breakdown -28.3, lift -26.6, drop2 -25.1, pickup2 -25.2, outro -27.1; full render ~52 s on the container.  Listening renders: `/app/tmp/listening/arrange-form/` (full, ring vs cut at the gap and into the breakdown, the turn fill vs none, the chance branch with seeds 1 and 12).
