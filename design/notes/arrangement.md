# Arrangement and the Session groundwork

Phase 1 of the arrangement plan (branch `arrange-1`, 2026-10-10): the shared Session groundwork ("G0") and the Set layer.  CLAUDE.md keeps a summary and points here.  Update both when behavior changes.

Sources: the study on branch `research-arrangement` (`research/arrangement/README.md`, prototype in `prototype/`), the interconnect contracts K1-K10 on `research-plan-interconnect` (`research/plan-interconnect/README.md`), and the maintainer's decisions of 2026-10-10 (quoted below).

## Session groundwork (G0)

Built to the interconnect contracts so the terminal UI and glhtui can use it later; only what phase 1 needs is built.

- **Stamps (K1)**: `Session::Stamp` (`lib/mb/sound/session/journal.rb`) = `frame` (session frames since the Session was created; monotonic, never reset by seeks, rewinds, or tempo changes; `Session#frame`) + `pos` (Rational whole notes), plus `bar_length` for display only.  Shown as `bar:beat` (`9:1`, `13:2.5`), never parsed.  `Session#clock` is the stamp of the next frame (where a change made now lands); `Session#transport_record` is the per-buffer `{frame, pos, bpm, bar_length, playing}`.
- **Journal (K3)**: `Session::Journal` keeps up to 10,000 `Journal::Entry`s (`seq, kind, subject, issued, commits, lands, status, source, line, data, undoes`); status is `:queued`, `:landed`, `:cancelled`, or `:failed`, and a status change is a new entry with the same `seq` (`journal.entries` has all of them, `journal.changes` the latest per change, `journal[seq]`).  `subscribe { |entry| }`.  The render thread only pushes small notes onto a `Thread::Queue`; they become entries when the journal is next read or written.  Entries print as `bg :bass lands 9:1 (queued)`; `entry.name` is the subject.  Sources: `:console`, `:schedule`, `:replay`, `:undo`, `:set`.
- **Change queue** (`session/changes.rb`): every change to what plays goes through `Session#change(kind, subject, time, data:) { |t| ... }`: `add` (`:bg`), `remove` (`:stop`), `resume`, `swap`, `master`, mute/solo, `:restore` (undo), `:scene`.  A change landing now applies right away; a future one waits in a sorted queue (time, then issue order) and is applied at the start of the buffer that holds its time, on its exact sample (`commit_due`, after scheduled blocks run, before players render).  This fixed the study's finding 2: a clip source holds one pending swap and a player one stop time, so `swap :bass, b, at: 4r` then `swap :bass, c` lost the first swap; queued graphs, stops, swaps, and master chains for one name now all land.  Validation errors (no such player, unrelated clips) still raise when the command is made; a queued change that fails when it lands is journaled `:failed` and printed (raised with `raise_errors`).
  - Changes apply under a render lock (a `Monitor` that `process_buffer` holds until the mix is done, released before `output.write`), so a console change lands exactly at the next buffer's start, and the journal says where.  Lock order: render lock, then the session mutex.
  - `players` lists graphs waiting to start ("starts at bar N") and queued stops; `idle?`, the timeline, and new player numbers count queued starts; a stop for now cancels queued starts of that name; a queued start after a queued stop plays (the old code dropped graphs that "would never have played").
  - `Session#queued(name)`, `#cancel_changes(*seqs)`, `#playing_after_queue?(name)`, `#timeline_nodes_of(name)`.
- **Launch points count from `Session#now`**: the scheduled block's time inside `at_bar`/`after`/`every` blocks (finding 1: `at_bar(5) { bg :x, g, at: :beat }` landed a beat and a half early, because the scheduler runs blocks up to half a bar ahead), a take's recorded issue time while it replays, and the transport position otherwise.
- **Exact fades** (`session/fades.rb`): fades and mute ramps are `Fades::Ramp`s counted in session frames from their first sample (level `k * slope + from` at frame offset k, so any buffer size gives the same levels), and fade-outs start on the exact sample of their stop time (they used to start at the next buffer start).  Levels are cast to SFloat before multiplying audio (Numo's SFloat * DFloat is ~20x slower).
- **Commands return journal entries**: `bg`, `swap`, `resume`, `master`, `mute`/`solo`, `go` return the change's entry (`stop`/`panic` still return names; inside scheduled blocks commands return names); `stop`/`swap`/`resume`/`mute` accept an entry in place of a name.  Every console command (and every scheduled block's batch) is one undo step (`Session#command(label) { }`).
- **Names (K2)**: `Session::Names` (`session/names.rb`): tracks, mute groups, and later knobs share one namespace; `:master` and `:cue` are reserved; a name claimed for two kinds goes through `MB::Sound.live_error` (maintainer decision 6).  `Names.path(:bass, :cut, 3)` is `"bass/cut/3"` (display and files only).
- Not built yet (later projects): the player strip's gain and route stages (K7; mute/solo is built), the session stream (K4), markers (K8), knobs (K6).

## Mute and solo (`session/strip.rb`)

Maintainer, 2026-10-10: "Sleep; softmute now; use or extend existing fade functionality for synced fades or mutes".

- `mute`/`unmute`/`solo`/`unsolo` (Session and console) take player names or mute groups (`mutes :breakdown, :drums, :bass`, alias `mute_group`).  Right away by default with a 5 ms declick (`Fades::DECLICK_SECONDS`), or at a launch point (`at: :bar`) over a `fade:` in bars (a synced fade), through the change queue.  `solo` with no names clears every solo, and `unmute`/`unsolo` with no names everything, resolved when the change lands (subject `:strip`), so a solo still in the queue isn't missed (the demo render found this).
- Flags belong to names, so a graph replacing a muted one starts muted.  The strip runs fade, then mute/solo (K7 order; gain and routes come later).
- A silent player sleeps: its graph isn't rendered (no CPU).  A mute ramp ending inside a buffer stops reading on its last frame, so oscillators fall asleep at the same sample at any buffer size.  On the unmute sample its timeline nodes restart there like after a seek (clips and tempo-locked tones come back in time); everything else is stale.
- Cost per 800-frame buffer (median, 2026-10-10): 64 constant players 1013 us unmuted, 55 us all muted (asleep), 1858 us all ramping (~13 us per ramping player); 64 ramp+lp4 tracks 2769 / 52 / 3698 us (`/tmp` bench in the arrange-1 report).

## Undo (`session/undo.rb`)

Maintainer: "Raw commands also, and yes, CPU permitting"; quantized to the next bar by default.

- Each change snapshots its subject as it lands: `PlayerState` (current Player, stopped Player, each clip source's clip, mute/solo flags), `MasterState` (the chain's block), `StripState` (all flags, for `:strip`).  `undo` issues `:restore` changes that put each subject back to its state before the step's first change, at the next bar (`at: :now` right away), through the change queue (exact, journaled with `undoes:`, replayed by takes).  Graphs come back as the same objects (stale state, as with `resume`) with a 5 ms declick crossfade; master chains are rebuilt from their blocks; Set state (track clips, current scene) through participants (`Session#note_undo_extra`, `Arrangement#restore_undo_state`).
- A step whose changes haven't landed (by the logical time, `Session#now`) is cancelled right away; `redo!` queues them again.  Undo and redo are symmetric (each pushes the reverse step on the other list).  Steps print as `undo go :drop lands 9:1`; `changes` lists them (`history` is a Pry command).
- Bounds: 64 steps, and at most 8 retired graphs (neither playing on nor resumable) held by the lists (oldest steps dropped).  Measured live heap (`ObjectSpace.memsize_of_all`) with 8-voice `sq80_voice` Synths replaced 16 times: 13.6 MB at limit 0, 74.7 MB at 8, 134.6 MB at 16, i.e. ~7.5 MB per retired graph, ~60 MB worst case at the bound.  A snapshot of that player takes 4 us; a console mute with journal, snapshots, and pruning ~170 us.
- Later (graph-io): undo could keep recipes instead of live graphs.

## The Set layer (`lib/mb/sound/arrangement.rb`, console `ArrangementMethods`)

Maintainer: "Yes, with a realtime demo script that shows a set being sculpted".  One `Arrangement` per Session (`Session#arrangement`).

- `track :bass, q: 1 do |clip| patch end` (alias `define_track`) or `track :pad, graph`: a named player remembering its patch or graph, its clip, launch quantization `q:`, and `fade:`.  `bg :bass, clip` on a track with a patch builds the patch with that clip.  `tracks` lists them.
- `scene :verse, pad: chords, bass: bass_a, drums: beat` (alias `define_scene`): a full state; values are a Clip or Kit, `:on`, `:off`/`nil`, or `:keep`; tracks not named stop unless `others: :keep` (partial scenes like fills and risers); a block runs at launch with commands landing at the launch time.  `scenes` lists them (current one marked).
- `go :drop` (alias `launch_scene`, `at:`, `fade:`): each track changes at its own launch point (the call's `at:`, then the track's `q:`, the scene's `q:`, the set's `quant`, 1 bar by default).  Only differences change: a patch track already playing swaps clips (keeping graph and effect state), rebuilding when swap can't map the clips or a Kit brings rows the old kit lacks; a track playing the scene's clip is left alone; stops get a 5 ms declick unless the scene or call gives a fade.  One undo step; returns the `:scene` journal entry (`scene :drop lands 13:1 (queued)`).
- Launch points in the Set: `:now`, `:beat`, `:bar`, `:clip`, a Duration, or a number of **bars** (unlike `bg`'s `at:`, where numbers are note grids; fades are bars too).
- Scene keys naming a non-track (e.g. a mute group) go through `live_error`; unknown tracks raise at `go`.
- Reserved, not built (later phases): `turn`/`move` (knobs, phase 3), `loop!`/`onward`/`unloop!` (forms, phase 2), `form`/`flow` (phase 2).

## Takes (`lib/mb/sound/take.rb`, `take/replay.rb`)

Maintainer: takes on by default; "Repo sets if standalone or requested, user data directory otherwise, with file path printed".

- `MB::Sound::Take.current` records every console line (Pry `:before_eval`/`:after_eval` hooks in `bin/sound.rb`, started after `warm_up`) with its issue Stamp and where each change it made landed.  `take` shows the last lines; `take.entries` their journal entries; `take.restart`.
- `take.save(path = nil, repo: false)` writes an executable replay script: explicit path, else `take.home`, else `sets/` with `repo: true`, else the user data dir (`$XDG_DATA_HOME`/`~/.local/share/mb-sound/takes`, macOS `~/Library/Application Support/mb-sound/takes`); prints the path.  Lines starting with foreground or display commands (`play`, `plot`, `vis`, `wait`, `take`, `players`, ...) stay as comments.  `take.form` prints a note (forms are phase 2) and returns the scene launches.
- `Take::Replay` restores tempo, bar length, master gain, default fades, and the root random generator (Marshal), then schedules each line at min(issue time, landings) in a fresh console-like binding (`Take.console_binding`), with its landing times forced on its changes (`Session.with_perform(forced:, now:)`) and `Session#now` = the issue time, so undo/cancel decisions match although lines run ahead.  The saved script renders with `-o file` (`-b 367,368` cycles buffer sizes) or plays.
- Measured (spec/lib/mb/sound/take_spec.rb, 960 buffers of tracks, scenes, mutes, solos with fades, two queued changes on one track, undo of a queued change, stop + undo now, a mute group fade): clip and constant sources replay bit for bit at buffer sizes 800, 367/368, 64, 1001/13; band-limited tones exactly at the live buffer size and within 3.7e-9 (-151 dB re peak) at others (Tone phase accumulates per buffer).
- Not exact: tempo and master gain changes (applied at buffer starts / when the line runs), nondeterministic code, live MIDI input.

## Demo

`bin/songs/night_bus_set.rb`: 48 bars performed command by command (scenes, a riser as a partial scene, a mistake undone on the next bar, mute/solo breaks, a mute-group drop-out, a synced mute fade); `night_bus_set` alone sets up tracks and scenes to play by hand.  Grow it with each phase.  Listening renders: `/app/tmp/listening/arrange-1/`.
