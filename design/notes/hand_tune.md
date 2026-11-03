# Hand-tuning a fitted sound

<!-- summary -->
The hand-tune loop (`lib/mb/sound/hand_tune.rb`, `fit_patch.rb`, `reference.rb`, `take/reader.rb`, `ui/note_log.rb`): `tune :kick, code, ref: 'kick.wav', tune: (30.0..110.0).at(51.3), ...` turns a fit's printed voice into a graph document whose fitted numbers are the track's knobs (`FitPatch`), opens it in `design`, and puts the reference on its own track for A/B (`ab`, b in the inspector; loudness-matched); `ui.note 'text', at:, freq:` (or the RENDER pane's , . < > markers) keeps his words with the sound, view, and spot as a JSON record; `take.turns` / `Take.read` read his take as knob rows (Prism, no eval) with start/end renders; `HandTune.infer` scores his path with `Analysis.compare` (L3) and names the steps the loss calls worse.
<!-- /summary -->

## Quick reference

- Console: `tune :kick, code, ref: path, play: clip, as: :name, param: (lo..hi).at(v), ...`; `fit_patch :name, code, param: (lo..hi).at(v)` (no design); `ab :kick, path` / `ab` / `ab :kick, :off`; `ui.note 'text', at: 0.012, freq: 3000`; `take.turns`; help `help :hand_tune`.
- Agents: `MB::Sound::Take.read('take.rb')` (rows, `changed`, `reversals`, `values(:kick, :start)`, `renders(:kick, note: 36, dir:)`), `HandTune.infer(turns, track:, reference:, note:, seconds:)`, `UI::NoteLog.records` / `.read(path)`, `HandTune.note_image(path)`, `HandTune.note_look(path)`; `HandTune.compare` is the loop's one loss call site.
- Specs `spec/lib/mb/sound/fit_patch_spec.rb`, `reference_spec.rb`, `hand_tune_spec.rb`, `take/reader_spec.rb`, `ui/note_record_spec.rb` (synthetic fits and references only).

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

## Open questions

1. A/B: mute/unmute (built), solo, CUE, or a crossfade knob?  And should `b` also A/B against the loaded preset, as first planned?
2. Fit patches go to `tmp/fits/`; should a tuned fit be saveable to the library (`save :kick_tuned, ...` works from the document; a `tune`-time `save:` option?).
3. The markers' keys (, . < > x) and steps; a pointer later?
4. Note records keep the RENDER pane's drawn data (about 40 KB a note); keep, or only the spot and the patch state (renders are reproducible)?
