# Hand-tuning a fitted sound

<!-- summary -->
The hand-tune loop (`hand_tune.rb`, `hand_tune/`, `fit_patch.rb`, `reference.rb`, `take/reader.rb`): `tune :kick, code, ref: 'kick.wav', tune: (30.0..110.0).at(51.3)` makes a fit's numbers the track's knobs (`FitPatch`), opens `design`, and A/Bs the reference (`ab`, b); `retune :kick, code, noise_level: (0.0..1.0).at(0.2)` (or the edited file) redefines the graph, turned knobs carrying; `refine :kick, seconds: 20, within: 0.15` searches (CMA-ES, in a worker process started on demand through the process starter) from his knobs, proposing a `turn` line to A/B three ways and apply as one undo step; `ui.note` keeps his words with the sound; `take.turns` reads his take as knob and structure rows with start/end renders; `HandTune.infer` scores his path with L3, across redefinitions.
<!-- /summary -->

## Quick reference

- Console: `tune :kick, code, ref: path, play: clip, as: :name, param: (lo..hi).at(v), ...`; `fit_patch :name, code, param: (lo..hi).at(v)` (no design); `ab :kick, path` / `ab` / `ab :kick, :off`; `retune :kick, code, new_param: (lo..hi).at(v)` / `retune :kick` (the edited file; alone, prints the body); `refine :kick, seconds: 20, within: 0.15, only:, except:, evals:, staged:, weights:, seed:, tune: 40..60`, `refine.ab`, `refine.apply`, `refine.off`, `refine.stop`; `turn :kick, tune: 47.9, decay: 0.41` (a track's knobs as one change); `ui.note 'text', at: 0.012, freq: 3000`; `take.turns`; help `help :hand_tune`.
- Agents: `MB::Sound::Take.read('take.rb')` (rows, `structures`, `events`, `versions`, `changed`, `reversals`, `values(:kick, :start)`, `document(:kick, :start)`, `renders(:kick, note: 36, dir:)`), `HandTune.infer(turns, track:, reference:, note:, seconds:)` (`segments`, structure steps), `HandTune.refine_job(session, track, ...)` + `HandTune.refine_run(job)` (in-process), `HandTune::Search` / `CMAES` (the research optimizer, exact), `HandTune.blocks(text, params)`, `UI::NoteLog.records` / `.read(path)`, `HandTune.note_image(path)`, `HandTune.note_look(path)`; `HandTune.compare` is the loop's one loss call site.
- Specs `spec/lib/mb/sound/fit_patch_spec.rb`, `reference_spec.rb`, `hand_tune_spec.rb`, `hand_tune/{retune,refine,refine_job,worker,search,cmaes}_spec.rb`, `take/reader_spec.rb`, `ui/note_record_spec.rb` (synthetic fits and references only).

Branch hand-tune-1 (2026-11-03), from research-voice-match-3's Round 3 section 6 ("Hand-tune and infer", 6ea917e0) and the maintainer's "Add the analysis library to the project and start work on the hand-tuning tools.  I'd probably write notes along the way explaining what I am seeing on a waveform or spectrogram and hearing with my ears, and try to connect them together for the sake of improving the analyzers"; on the 909 kick: "I think I would need to hand tune this and have you figure out what I did and then make the loss metrics work for that."  The analysis toolkit is `analysis.md` (analysis-lib-1).

## The loop

1. An agent loads a fit (`tune`): the fit patch on a track, open in `design`, its reference beside it.
2. He tunes by ear in the inspector, flips A/B with b, writes notes (`ui.note`, NAV #) at spots on the RENDER pane's plots, and saves the take.
3. The agent reads the take (`Take.read`), renders his start and end, looks at both against the reference (`note_look`, `Analysis.look`), reads his notes' records, and runs `HandTune.infer`: where the loss calls his steps worse is what the loss gets wrong.
4. (Later, with analysis work) tune the loss until it falls along his paths; refit from his point.

## Fit patches (`FitPatch`)

A fit prints its voice as console Ruby with literal numbers.  `FitPatch.document` walks that code with Prism (no eval) and names each fitted literal by the param whose value prints as it: Float literals for Float values; a literal of 3+ decimals or 4+ significant digits matches any value rounding to it, a shorter one only the value to 6 places (0.25 doesn't print as 0.3); a keyword prefers the param of its name, else the closest value wins (0.009: a burst decay of 0.009 over a spacing of 0.0085); a tie raises.  Literals a param can't take stay numbers, listed with why (`Patch#skipped`): inside a Range (`sensitivity: 1.0..1.0`), typed values (`4.07.db`, `12.cents`, `.hz`, `.ms`, note lengths), runtime blocks (`then { |u| ... }`, outside the documents' safe subset).  A param found nowhere (a derived value: `d = 2 ** (drive * 2)` printed as `d = 2.460364`) is listed; name the printed number instead (`drive_gain:`).  A `play (...)`/`bg (...)` around the code is unwrapped; the voice's source (the first argument or receiver of the outermost synth/kit/tr909/tr808/sampler/struck call) becomes the document's `midi` input.

- **Why a graph document**: it is the init voice's form (`presets/init.mbg.rb`): `param` lines are a track's knobs through `Arrangement::TrackKnobs` (`:"kick/tune"`, the fit's range), so the inspector, binds, build knobs, carry, takes, and set documents all work with nothing new.  Library-file instruments would make session-wide `knob` names, not track knobs.
- **Where**: `FitPatch.dir` (`$MB_SOUND_FITS`, else the main checkout's `tmp/fits/`, else the user data directory), never a shelf: fits of his private samples stay out of the library and out of commits.  `Library.document_entry(path, session shelf)` gives the Entry `track`/`design` take (`Arrangement::InstrumentPatch` takes anything answering `#library_entry` except Procs).
- **Build-time settings**: a param where a setting is read once while building would fail to load; `GraphNode::Shaper` (softclip, clip) now reads params and knobs through `GraphNode.build_value`, so a fitted clip threshold is a build knob (each turn rebuilds the track), like the init voice's sync.  The 909 structure clap still can't load: `h.bursts` and `Drums::Repeats` take numbers, and its code calls `MB::Sound::Drums.decay_env` (not a document method); a `trigger:` on `Hit#env` and a `Hit#repeats` would make it printable.
- **Check**: the document is loaded and plays a block of a chord of drum and synth notes (36, 38, 39, 42, 46, 60: a kit voice answers only its GM note).
- **The queue** (2026-11-03, the maintainer's ten Bench items marked for hand tuning): 7 of 10 load as fit patches (scratch generator); XM1 21 (`MB::Sound.with_seed` in the code), XM2 13 (a `then` block calling `times`), and the 909 clap don't.  Fits are gain-matched to quiet originals, so several peak over 1: the one-liners add a `level` line.

## A/B (`Reference`)

`ab :kick, 'kick.wav'` (or a Sample) defines track `:kick_ref` playing `:kick`'s clip through a one-voice sampler at the sample's own pitch (keytrack 0: every note plays the reference from its start), muted, its level (`level :kick_ref`) set so the reference's integrated LUFS over its first seconds (at most 4) matches one note of the patch.  `ab` / `ab :kick` (b in the inspector: one console line, in the take) flips which is heard: one undo step muting one and unmuting the other, journaled, so the take reader sees each comparison (`Result#flips`).  On a flip to the reference after the knobs moved, the patch is measured again.

- **The patch's loudness**: one note rendered offline from the track's graph document at the knob values now (`HandTune.render`: `bounce` in a private Session, master at 0 dB, the note `UI::PatchRender.input` picks: the clip's first note, else the role's).  Patch blocks (not documents) play the reference unmatched, and the pair says so.
- **Choice and alternatives** (open question): mute/unmute of two tracks is the simplest existing path (exact landings, 5 ms declick, both on MAIN at the same note).  Solo would fight other solos; CUE needs phones routing; a crossfade knob would make a third control and a partial mix.  The `b` key was planned as "A/B against the loaded preset" (sound_design_ui.md); it now flips the reference.
- Setting up reads the reference file (ffmpeg, as any sound file read: a process start on a console command); flips start nothing.

## Kits in the RENDER pane

The 909 fits are kit voices, and the RENDER pane said "no synth voice to copy" for kits.  `Drums::Machine#kit` gives the kits it builds a copier (`Kit#copy_for(source)`: the same design, knobs, and seeds from another source); `UI::Poll#render_source` stands a `PatchRender::KitCopy` in for the Synth when a graph has no Synth but a copyable kit.  The copy plays the render's NoteFeed with every voice (the note picks which sounds); its knob readers are rebound to the copy's knobs as a synth copy's are.  A kit copy is built again for every render: after the plan-snapshot reset, the copied voices' note triggers stayed silent (the voices' own state, `Drums::Voice::ADOPT_IVARS`, restored too, didn't help); a kit voice builds in a few ms.  tr808 kits (not built by a Machine) stay without a preview.

A copy built below 48 kHz falls back to 48 kHz when the rate error comes wrapped in a graph document's LoadError too (a fit patch whose param feeds lp4 straight from the track's 48 kHz knob showed only the error).

## Notes (`UI::NoteLog`)

`ui.note` stays the one notes system: the day's Markdown as before (now with "about" and "data" lines), plus a JSON record per note in a directory per session (`NoteLog.dir/data/<start>_<pid>/<HHMMSS>.json`; `NoteLog.records`, `.read`: plain data, JSON.parse).  The record (`NoteLog.record`, version 1): the text and time; the screen (layout, size, focus, the screen as text); what plays; the last console lines; where in the take (its lines so far, the timeline position, the frame); the sound (`sound_capture`: the inspected track, else the last designed; its instrument entry and graph document; its knobs; the document's params at them; the note the RENDER pane plays; its A/B pair); the view (the RENDER pane's view, length, rate, time and frequency ranges, markers); what it drew (the envelope's 1024 columns, the spectrum's bands, LUFS/peak/RMS, rounded to 5 places); and the spot (`at:` seconds into the rendered note or a Length, `freq:` Hz or a Pitch; else the markers).

- **Markers**: in the RENDER pane, , and . move a time marker over the envelope view (steps of a fiftieth of its length; the first press shows it at a tenth), < and > a frequency marker over the spectrum (a sixth of an octave; first at 1 kHz), x clears; drawn as rules in `Render::MARKER`, named in the pane's first row (`@ 60 ms 1.12 kHz`).  `Tiles#pane_state` and `#session` let the note read them.  The plots' axes were already labeled (time in s/ms, frequency, level in dB) at sizes with room for them.
- **Images, offline**: `HandTune.note_image(record)` draws the record's own data (envelope and spectrum, labeled, the spot as markers); `HandTune.note_look(record)` renders the patch at the note's knobs and calls `Analysis.look` with the reference beside it.  Neither runs on a live path (a pure-Ruby PNG takes hundreds of ms); the note itself writes JSON only.

## Reading a take (`Take::Reader`)

`Take.read(path_or_text)` / `take.turns` walk the replay script with Prism (the live take through its `to_ruby`, one code path): the Replay's tempo, its raw gesture steps, and each `r.line`'s code (a squiggly heredoc of several lines is an InterpolatedStringNode of plain parts), reading `turn`/`move`, `level`, `ab`, `undo`, `knob`, `fit_patch`, `tune`, `track`, and `design` calls.  A Turn row: knob, from, to, pos (whole notes), seconds (at the take's tempo; tempo maps are not followed), line, kind (:turn, :gesture, :ramp, :follow, :level, :undo), steps (a gesture's keys, or the raw steps the take kept), code.  Values from literals (numbers, Rationals, `.hz`/`.khz`/`.ms`/`.seconds`, `.db` as a gain, keyframe Hashes, `(lo..hi).at(v)`); anything else is nil.

- **Where knobs start**: `start:`, `knob` lines, a `fit_patch`/`tune` the take made and gave a track (a later line's local is parsed as a call), `patch:` documents, the session's knob defaults (`Take#turns`), levels at unity.
- **Undo** puts back the last line it hasn't undone (an approximation of undo's "last command", right for a tuning session).
- `Result`: rows, flips, start, finish, `changed`, `by_knob`, `reversals` (a turn back toward where a knob was: he was unsure of it), `values(track, :start | :finish)` (the document's params), `renders(track, note:, dir:)`.
- **Takes' saved format is unchanged**; the reader needs nothing new in it.

## Infer (`HandTune.infer`, prototype)

Renders the track's document at every state along his path (his start, then each turn of one of its params; levels left out: the comparison is level-free) and scores each with `HandTune.compare` (`Analysis.compare`: L3).  The Inference: Steps (loss before/after, each term's change, agrees or not), `disagreements`, `weighted` (each term's change from start to end: what he listened for and what he gave up), and the loss along the straight line from his start to his end (each param's range and curve; `monotone?`).

First run (the queue's 909 kick thejames, four made-up turns standing in for his: shorter sweep time, less drive, more sweep, less tick): the loss called the sweep-time step worse (spectral +0.64, attack +0.23) and did not fall along the straight line (25% 1.93, 50% 2.05, 75% 2.48).  His real take is the test.

## Redefining the graph while tuning (`retune`, hand-tune-2)

The maintainer (2026-11-03): "The tuning process should be able to handle me redefining the graph to add missing oscillators or noise elements etc."  One command, two ways in:

- `retune :kick, code, noise_level: (0.0..1.0).at(0.2), ...`: the code is the document's body (its params by name: `retune :kick` alone prints the body playing, ready to copy), each new param's number written in the code and matched by fit_patch's literal rules (`FitPatch.document match:` limits matching to the new params, so the code's other numbers stay numbers; names the code references count as sites).  A kept param given again takes its new range.
- Edit the fit's file (`tmp/fits/kick_fit.mbg.rb`: new `param` lines, the code) and `retune :kick`.  The take keeps what was read: `Take.record_call_as` rewrites the line's call as `retune :kick, document: "..."`, so the take replays without the file.
- **Versions**: each document text the track plays is an immutable copy (`FitPatch.version_path`: `tmp/fits/versions/<name>-<sha12>.mbg.rb`); the track's Library entry is the copy, its lineage (`settings[:lineage]`) the editable path.  So an undo puts the old version back, and a rebuild after the file was edited plays the text that was loaded.  `InstrumentPatch.same_instrument?` treats versions of one lineage as the same instrument: turned knobs carry (TrackKnobs' rules: a knob still where its param put it takes the new value; a turned one keeps its value unless the new range leaves it out, then it goes back to the param's value: `Retuned#reset`), new params become knobs, removed ones are listed (their knobs stay, unread).  The same instrument given again now rebuilds carrying its state (`change_instrument carry:`; it used to spill like another instrument): the voices play on where the structures match, the rest spills.
- The rebuild and the reference's new loudness match (`Reference.match`, at the knobs now) are one undo step.  In sound design the rebuild lands on the next buffer or beat (Arrangement#rebuild_track's timing), elsewhere at the track's launch point.
- **The take reader**: a retune is a `Structure` row between the turns (added, removed, kept, changed, reset; `Result#events` has both in order).  Every version the take played is rebuilt from its lines (`FitPatch.document` for tune, fit_patch, and code retunes; the text for document retunes; Prism only), so `values`/`renders`/`document` at the start and the end use their own structures.  The live take (`take.turns`) starts a track retuned during the take at the version it played before its first retune there (`HandTune.history`); a saved take read cold needs its `tune` line or `patch:` with the starting version (a take restarted after `tune` doesn't say which document played).
- **Infer across**: the path is scored in segments (`Inference#segments`, one per version); the redefinition is a step of its own: the loss at his knobs before it, then in the new structure at the knobs it carried (the structure's own effect).  `line` is the last segment's straight line.
- Params named like a document function (`noise`) are refused: the loader read `noise.filter(...)` as the param.
- Guards (`hand_tune/retune_spec.rb`): a take with a code retune and a file retune mid-song replays to the same samples; knobs carry; structure rows and exact start/end renders; infer's structure step; undo; removed params and the rematch.

## Refine: an optimizer pass on his settings (`refine`, hand-tune-2)

The maintainer (2026-11-03): "optionally I'd like to be able to trigger an optimizer pass with time or range limitations on top of my own settings to refine them".  `refine :kick, seconds: 20, within: 0.15` starts from the knobs as they are, against the track's reference (`ab`, or tune's `ref:`):

- **Limits**: `seconds:` (wall clock; 20 when neither is given) and/or `evals:`; `within:` (a trust region: each knob moves at most this share of its range, in its own scale, from where he put it; 0.2 by default, nil for the whole range) or a range per knob (`tune: 40..60`); `only:`/`except:` (default every bounded numeric param of the document).  `staged: true` searches one block at a time (`HandTune.blocks`: the call a param is an argument of, an operator's operand with what it operates on, a local's value with the local: the 909 kick's body, clip, noise), the budget split by block size, each stage from the best so far: the voice-match lesson for layered voices; or `staged: [[:tune, :decay], [:tick]]`.
- **The loss**: `HandTune.compare` (L3), `weights:` overriding.  One note rendered offline from the document at each point (`HandTune.render`), at the track's note, as long as the reference (at most 2 s; `length:`).  The comparison keeps the target's side with its Signal (analysis.md), so one evaluation of a 0.5 s kick costs about 56 ms (render 10, compare 27) in the Mac container: about 350 evaluations in 20 s.
- **The search**: `Search` (research `fit.rb`'s loop: CMA-ES in the unit cube from his point, restarts on stagnation, penalty outside the cube, each run scoring its start, so it never ends worse than his settings) over `CMAES`, both ported operation for operation.  Port check: the research code (6ea917e0 `cmaes.rb`, `fit.rb`) and the lib on sphere, Rastrigin, and Rosenbrock losses in 2, 4, and 7 dimensions with seeds 1, 3, 11 gave the same best, the same evaluation it was found at, and the same history; 50 generations of ask/tell gave the same means and steps; `search_spec`/`cmaes_spec` keep the research run's numbers.  `seed:` defaults to 1, not a draw from MB::Sound's root seed: a replay doesn't search, so a draw would move every later random choice of the replayed set.
- **Where it runs (measured, the Mac container, a techno set live on the null device under the dropout probe, 30 s each)**:

| mode | evaluations | dropouts | render thread GVL waits >= 1 ms (held by others) | longest wait | GC |
|---|---|---|---|---|---|
| none (baseline) | 0 | 0 | 7 | 8.0 ms | 13 ms |
| in-process thread | 498 | 0 (1 in a 20 s run: an 82 ms major GC) | 1396 (11.7 s) | 20.3 ms | 2024 ms |
| in-process, one evaluation after each buffer (slack) | 493 | 0 | 1383 (11.2 s) | 22.0 ms | 2196 ms |
| worker process | 514 | 0 | 7 | 2.6 ms | 13 ms |
| a process started every 2 s while playing | 15 | 0 | 20 (143 ms) | 16.9 ms | 0 |

  An evaluation holds the GVL tens of milliseconds (Ruby rendering and analysis, preempted only at the 10 ms timeslice), so slack windows don't help, and its garbage makes major GCs on the render thread's time.  The worker (`HandTune::Worker`: `ruby -e` loading mb-sound, nice 10, JSON lines over pipes, about 2 s to load and 100 MB) keeps the render thread at its idle numbers at the same speed.  It starts on demand through the process starter (spawner-1, 2026-11-03; terminal_ui.md, Starting processes), so it can start while a set plays: the console's first `tune` starts it ahead (`Worker.prepare`, live mode only; `MB_SOUND_REFINE_WORKER=0`, as the specs set, turns that off), else refine's first run (`Worker.start`).  hand-tune-2 started it at every bin/sound.rb launch (100 MB and 2 s of a core even if never used; `Worker.prestart`, gone).  Without a starter (scripts, `MB_SOUND_STARTER=0`) it starts only while nothing plays and refine refuses while a render thread runs (a process start from the console holds the GVL through the fork, worse on macOS without vfork), offering `mode: :here` (in-process: scripts and specs).  The console waits on the worker's lines off the GVL (`worker_spec`: the console process used under a quarter of a core while a refine ran beside a playing Session).  Option (c), a `bin/refine.rb` in another terminal on a saved take, and (d), pausing playback, weren't needed.
- **Results**: a proposal (changed params, 5 significant figures), printed as one `turn :kick, tune: 47.9, decay: 0.41` line with the loss and its terms before and after.  Progress redraws one line (best loss, evaluations, time left; `ColorPolicy.animate?`); Ctrl-C (or `refine.stop`, or `wait: false` and `refine.stop`) keeps the best so far.  Nothing changes until asked: `refine.ab` sets up a muted copy of the track at the proposal (`:kick_refined`, his other knobs, loudness-matched to his patch) and cycles his patch, the copy, the reference (`Reference::Pair#alt`; `ab` and b cycle the three while it's up); `refine.apply` turns his knobs to the proposal as one change (`Session#turn_knobs` in one command: one undo step, build knobs rebuilding the track once, `Arrangement#turn_build_knobs`) and stops the copy; `refine.off` stops it.
- **`turn :kick, tune: 47.9, decay: 0.41`**: a track's knobs together, to plain numbers, one change (`KnobMethods#turn` with a track name and its params as keywords; a typo names the track's knobs).  The proposal prints this form so he can paste part of it.
- **Takes keep what was found, not the search**: the search's line becomes `refine(:kick, proposal: { ... }, searched: "seconds: 20, seed: 1, 284 evaluations, loss ...")` once its result is known, `refine.apply` becomes `refine(:kick, apply: { ... })`, `refine.ab` stays (the replayed proposal answers it).  A replay never searches.  The reader reads apply lines as `:refine` rows and three-way flips (`hearing: :alt`).

## Walk-through: a queue item with a noise layer, refined

In bin/sound.rb from /app (the `tune` line starts the worker in the background):

```ruby
# 1. A queue item: paste its tune line (tmp/hand-tune-queue/, private) or any fit's
tune :kick, "kit(grid(16, kick: 'X...'), seed: 1) { voice(:kick) { |h| h.body(51.33, decay: 0.469) } }", ref: 'tmp/kick_ref.wav',
  tune: (30.0..110.0).at(51.33), decay: (0.1..2.0).at(0.469)
# 2. Turn by ear (inspector arrows); b flips the reference
# 3. A noise layer: print the body, then give it with the layer and its numbers as new knobs
retune :kick
retune :kick, "kit(midi, seed: 1) { voice(:kick) { |h| h.mix(h.body(tune, decay: decay), h.noise(decay: 0.06, highpass: 2000.0) * 0.2) } }",
  noise_decay: (0.005..0.3).at(0.06), noise_hp: (200.0..12000.0).at(2000.0), noise_level: (0.0..1.0).at(0.2)
# 4. Turn the new knobs by ear, then let the optimizer refine for 20 s within 15% of each knob's range
refine :kick, seconds: 20, within: 0.15
refine.ab        # the refined copy
refine.ab        # the reference
refine.ab        # yours again
refine.apply     # one undo step (undo puts yours back)
ui.note 'refined: the click got shorter, the noise brighter'
# 5. Save the take and read it back
take.save :tmp, 'kick with a noise layer, refined'
puts take.turns   # turns, a structure row for the retune, the refine's rows
puts MB::Sound::HandTune.infer(take.turns, track: :kick, reference: 'tmp/kick_ref.wav', note: 36, seconds: 0.5)
```

Expected: the retune line says "added noise_decay, noise_hp, noise_level; kept 2"; refine shows one progress line for 20 s, then the loss before and after, the knobs it moved, and its `turn :kick, ...` line; the three A/B steps say which is heard; after apply the knobs are the proposal's; `take.turns` lists his turns, `structure: +noise_decay, +noise_hp, +noise_level, kept 2  (retune)`, and the `(refine)` rows.

## Open questions

1. A/B: mute/unmute (built), solo, CUE, or a crossfade knob?  And should `b` also A/B against the loaded preset, as first planned?
2. Fit patches go to `tmp/fits/`; should a tuned fit be saveable to the library (`save :kick_tuned, ...` works from the document; a `tune`-time `save:` option?).
3. The markers' keys (, . < > x) and steps; a pointer later?
4. Note records keep the RENDER pane's drawn data (about 40 KB a note); keep, or only the spot and the patch state (renders are reproducible)?
5. (hand-tune-2) Names: `retune` (alternatives: `tune :kick, edit: code`, `fit_patch.edit`, `redefine`) and `refine` (it shadows Ruby's `Module#refine` on MB::Sound itself; alternatives `hone`, `polish`, `nudge`)?
6. (Answered 2026-11-03: "Merge, starter process": a starter launched at startup starts the worker, ffmpeg, and git; spawner-1 starts the worker on demand at the first `tune` or refine.)
7. refine's defaults: 20 s, `within: 0.2`, joint search (not staged), seed 1; the refined copy as a third muted track (his knobs untouched until apply, so the take's turns stay his) vs turning his knobs to the proposal and back.
8. Apply lands each live knob with a turn's short glide at once, and build knobs with one rebuild; fine for a kick, or should apply land on the next note?
