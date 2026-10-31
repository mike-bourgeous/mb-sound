# Sound guards: the golden set and perceptual fingerprints

<!-- summary -->
"Ears win": sound is the test, exactness only where it is heard or a workflow needs it.  The golden set (`golden/set.rb`: song scripts and presets across the maintainer's genres) is re-rendered by `rake golden:check` and compared by perceptual fingerprints (`MB::Sound::SoundGuard`, `lib/mb/sound/sound_guard/`) against calibrated thresholds.  Changes to DSP, presets, or the plan layer run it; a failure goes to the maintainer as a Bench set and only his verdict re-approves (`rake golden:approve[name] RUN=dir`), never an agent.
<!-- /summary -->

## Quick reference

- `rake golden:check` (or `golden:check[techno]`), `rake golden:list`; the set is `golden/set.rb`, fingerprints from `MB::Sound::SoundGuard`.
- Run it for changes to DSP, presets, or the plan layer; a moved piece goes to the maintainer as a Bench set, and only his verdict re-approves (`rake golden:approve[name] RUN=dir`), never an agent.
- Spec `spec/lib/mb/sound/sound_guard_spec.rb`.

The summary block above feeds the generated index (`design/notes/README.md`, `rake docs:index`).  Update it when behavior changes.

## Why (maintainer, 2026-10-22)

From the zoom-out (workbench `research/zoom-out/decisions.md`): guard rule "Ears win" ("Sound decides.  Exactness only where it can be heard or a workflow needs it (takes, stems).  Sound is guarded with reference renders he has approved."); layer 2 picked a golden set (10-20 approved renders across his genres and, later, the factory bank, re-approved on change) and perceptual measures (loudness/spectral/envelope distance instead of md5); layer 3 picked fingerprints in the repo (small committed features, renders regenerated), approved renders outside git, and failures going to the Bench automatically, with re-approval updating the fingerprint.  Not picked: selective per-change runs, declared-change bookkeeping, a listening budget, a verdict archive.

The trigger was the SQ-80 regression question ("Did the code change or did I?", 2026-10-19): nothing compared sound across merges the way specs compare samples, so a deliberate default change (lp4 `tuning: :musical`) and patch edits from Bench notes could only be told apart afterwards by archaeology (workbench `research/sq80-regression/README.md`).

Exactness policy that goes with it (same date, `.claude/collaboration.md` "Ears win"): reproduce what was heard (seeds, takes, variants identical on the same settings); buffer sizes "within -80db if possible. Just not obsessed over and never part of persona concerns"; new C kernels may compare with a Ruby reference within a tolerance instead of a bit-exact mirror; integer frame counters on hot paths, Rationals for musical positions.

## Pieces

`golden/set.rb` lists the pieces in plain Ruby (`MB::Sound::SoundGuard.golden_set do piece ... end`): a song script with its options (rendered as `ruby -Ilib SCRIPT -q -f -o OUT OPTIONS`, so the script runner, its options, and the script's own master chain are in the test), or a block returning a graph with `bars:` and `bpm:` (a preset on a phrase; rendered by `golden/render_piece.rb NAME OUT` in a process of its own, seed 1).  Each names the genre it stands for and what it covers.  Every piece renders in a process of its own (no state carried between pieces), `PARALLEL` (default 2) at a time.

Selection (guards-1, 2026-10-22; a proposal for the maintainer to adjust):

| piece | genre | render | covers | audio | render time |
|---|---|---|---|---|---|
| ambient | ambient | `genre_demo.rb -G ambient -s 20` | bowls on clocks, rain and wind through a `:weather` bus, `sounding`, reverb | 35 s | 82 s (the slowest; the ambient template renders at 0.4x realtime) |
| generative | generative | `generative_blur.rb -b 8` | seeded generators, blurred harmony, a granular cloud | 24 s | 10 s |
| chimes | ambient | `wind_chimes.rb -b 4` | dust, drift, modal resonators | 16 s | 5 s |
| swarm | cinematic | `swarm_song.rb -b 6` | the Deep-Note-like swarm of gliding saws | 25 s | 7 s |
| press_chop | lo-fi | `press_and_chop.rb -b 8` | sampler presses, chops with pitch marks, SP-1200 edits | 13 s | 4 s |
| grit | industrial | `node_graph_grit.rb` | a bass under rising distortion (ADAA shapers) | 23 s | 4 s |
| supersaw | EDM | `unison_song.rb -b 8` | unison supersaw pad in stereo, detuned bass | 26 s | 6 s |
| techno | dark techno | `genre_demo.rb -G techno -s 30` | tr909, rumble and echo buses, ducking, master chain | 47 s | 31 s |
| wavetables | electronica | `wavetable_song.rb -b 8` | wavetable scan pad, sampled piano, arp | 21 s | 13 s |
| feedback | electronica | `feedback_song.rb -b 8` | Karplus-Strong, tape echo, flanger, 808 | 21 s | 9 s |
| house | house | `genre_demo.rb -G house -s 30` | house template: kit, bass, buses, pump | 40 s | 31 s |
| vocal_club | house | `vocal_lead_song.rb -b 8 --master club` | formant + lp4 + key-tracked crusher lead; the `:club` mastering preset | 16 s | 11 s |
| drums909 | house | `drums_909.rb -b 8` | TR-909 machine, shuffle, flams | 17 s | 4 s |
| tunnel_vision | DnB | `tunnel_vision.rb -b 16` | neuro roller: reese, buses, sends, drum bus, master | 32 s | 25 s |
| acid | electronica | `acid_song.rb -b 8` | diode-ladder 303 voice, accents, slides | 16 s | 3 s |
| reese | DnB | `preset :dnb_reese` on a bass line, 4 bars at 174 | a graph document, unison, lp4 | 6 s | 2 s |
| tine_keys | lo-fi | `preset :tine_piano` on soft chords, 4 bars at 96 | FM tine with pickup drive | 10 s | 3 s |

About 6.3 minutes of audio; one render pass takes about 2 minutes at PARALLEL=2 on the Mac's i9 under load (render times above are from that pass, without YJIT, since renders run as `ruby -Ilib`).  Not yet represented: guitar/live input, the cinematic "trailer" wavetable bass beyond `wavetables`, jungle breaks (`genre_demo -G jungle`), funk.

No SQ-80 patch is in the set while the ban (2026-10-19) stands.  The factory bank joins later, a piece per patch family.

## Fingerprints (`MB::Sound::SoundGuard::Fingerprint`, FORMAT 1)

The guard code is `lib/mb/sound/sound_guard.rb` plus `lib/mb/sound/sound_guard/` (`fingerprint.rb`, `comparison.rb`, `golden_set.rb`, `runner.rb`).

Measured on the render as a listener gets it (the mix after the master), with the library's own analysis: BS.1770 loudness (`MB::Sound.loudness`) and `Structure::Frames` (2048-point Hann STFT every 512 samples, 64 mel bands 30 Hz-16 kHz, onset envelope).

- `loudness`: integrated LUFS, true peak (dBTP), LRA, sample peak.
- `momentary`: momentary loudness every 100 ms.
- `mel_mean` and `mel`: a 32-band mel spectrum (pairs of the 64) of mean power, over the whole render and per 0.5 s segment, with `segment_db` (each segment's total).
- `envelope`: frame energy in dB every 1024 samples (21 ms).
- `onsets`: peaks of the onset envelope (local maxima over ±3 frames, at least 1 deviation), `[seconds, strength]`.
- `centroid`: of the mean spectrum, Hz.
- `stereo`: side/mid energy overall, per band (<150 Hz, 150 Hz-2 kHz, above), and per segment; L/R correlation (nil for mono).
- `source`: the command, commit, render time.

About 1 KB per second of audio (348 KB for the 17 pieces), written one segment per line so diffs stay readable.  `golden/fingerprints/<name>.json` is committed; changing what the extractor measures bumps `FORMAT`, and `rake golden:refingerprint` re-extracts every committed fingerprint from the approved renders (no re-render, no re-approval).

## Comparison (`MB::Sound::SoundGuard::Comparison`)

Ten distances, each against its own threshold; a piece passes when all are within.  Level and timbre are kept apart: the spectral and envelope distances remove the mean (level) difference, so a gain change shows on the loudness distances only and a filter move on the spectral ones.

| distance | measures | threshold |
|---|---|---|
| `loudness` | integrated LUFS difference | 0.25 LU |
| `true_peak` | true peak difference | 0.5 dB |
| `loudness_curve` | 95th percentile momentary-loudness difference where either is within 40 LU of the loudest | 0.4 LU |
| `spectrum` | RMS of the whole render's mel-spectrum difference, level removed, bands within 60 dB of the top | 0.1 dB |
| `spectral` | the same per 0.5 s segment (bands within 50 dB), averaged over segments within 40 dB of the loudest | 0.25 dB |
| `centroid` | spectral centroid difference | 8 cents |
| `envelope` | 95th percentile frame-energy difference, median (level) removed, where either is within 50 dB of the loudest frame | 0.5 dB |
| `onsets` | the larger share of strong onsets (strength >= 2) in either render with no onset in the other within 30 ms | 0.15 |
| `width` | largest side/mid difference, overall and per band, floored at -40 dB | 0.3 dB |
| `duration` | length difference | 0.05 s |

## Thresholds and calibration

Calibrated 2026-10-22 (guards-1, at 757f233e plus the guard code) with `golden/calibration/calibrate.rb` over all 17 pieces (ambient then at `-s 30`); every distance per piece and change is in `golden/calibration/results.json`.

Changes known to be inaudible: a second render (all 17 bit-identical: the pieces are deterministic), 128-sample render buffers instead of 800 (14 of 17 renders differ in samples), Gaussian noise 80 dB under each render's RMS, +0.1 dB.  Changes known to be audible: +1 dB; lp4/diode `tuning: :hardware` (undoing filters-1, the SQ-80 suspect); every lp4/diode cutoff x1.1 (+1.65 semitones).  The tuning and cutoff changes alter only the 9 pieces that use lp4 or the diode.

Largest distance over the inaudible changes: loudness 0.10 (the +0.1 dB), true peak 0.10, loudness curve 0.10 and envelope 0.10 (the fingerprint's 0.1 dB rounding), spectrum 0.024, spectral 0.056, centroid 0, onsets 0, width 0.01, duration 0.015 s (renders end on whole buffers).  Thresholds sit 2.5x (loudness) to 4x (spectrum, spectral) or more above those, and below the audible changes where those moved the sound:

- +1 dB fails all 17 pieces (loudness, true peak, loudness curve 1.0 each), and nothing else: level and timbre stay apart.
- `tuning: :hardware` fails 7 of the 9 pieces it changes (generative, chimes, press_chop, techno, vocal_club, tunnel_vision, reese); it passes acid (spectrum 0.055, centroid 4.4 cents) and house (0.056, 0 cents), where the filters run at resonances whose tuning scale is near 1 or sit low in the mix.
- cutoff x1.1 fails 7 of 9 (generative, press_chop, techno, vocal_club, tunnel_vision, acid, reese); it passes house (centroid 3.4 cents) and chimes (width 0.10).
- All inaudible changes pass on every piece.

So the guard catches a 1 dB level change anywhere and a filter retune or 10% cutoff move wherever it changes a piece's spectrum by about a tenth of a dB (RMS over bands) or its centroid by 8 cents, which is finer than the maintainer's own verdict on the SQ-80 tuning A/B ("same", on a solo patch whose 64-band mel shape moved 1.7 dB RMS in the regression study): failures are prompts to listen, not verdicts.  If intended changes trip it too often, widen `spectrum`/`spectral`/`centroid` first (each 2x keeps every inaudible change passing with margin).

## Files and tasks

- Approved renders: `<main checkout>/tmp/golden/approved/<name>.flac` plus `<name>.json` (command, commit), shared by every worktree (the main checkout is found through `git rev-parse --git-common-dir`); `MB_SOUND_GOLDEN_DIR` overrides.  Never in git.
- Runs: `tmp/golden/runs/<UTC stamp>-<check|approve>-<commit>/`: each render and its log, `report.txt`, `results.json` (distances per piece), and for failures `bench/` (320 kbps MP3s, levels as rendered: a level change is what is being judged) plus `bench_set.py` (a Listening Bench set, approved vs new, each variant's `code` the git checkout and render command) for the main session to publish.
- `bundle exec rake golden:check` (all) or `golden:check[techno,dnb]` (or `PIECES=`), exit status nonzero unless everything passes; `RUN=dir` re-fingerprints a run's renders instead of rendering.
- `rake golden:approve[name]` (with a run: `rake golden:approve[name] RUN=dir`) renders and approves (fingerprint into `golden/fingerprints/`, render into `approved/`); `RUN=dir` approves a check run's renders (after the maintainer's Bench verdict) without rendering again.  Commit the fingerprints.
- `rake golden:list`, `rake golden:refingerprint`.
- `golden/calibration/calibrate.rb` re-runs the calibration (perturbations through `golden/calibration/perturb.rb`, loaded with RUBYOPT into the render processes) and writes `golden/calibration/results.json`.
- Specs: `spec/lib/mb/sound/sound_guard_spec.rb` (synthetic signals for the extractor and each distance; a two-piece runner round trip with `spec/test_data/golden_tone.rb`; a guard that every piece in the set has a committed fingerprint in the current format and no SQ-80).  The set itself is never rendered by the suite.

## When to run it (process)

Changes that touch DSP (nodes, kernels, filters, oscillators, envelopes, effects, mastering), presets, or the plan layer run `rake golden:check` before merging (collaboration.md, the agent-brief skill).  A failure is not an error to fix by re-approving: an intended sound change goes to the maintainer as the run's Bench set, and `golden:approve[...] RUN=dir` follows his verdict; an unintended one is a bug.  On the Mac container wrap it in `flock /claude/heavy-run.lock` like other heavy runs.

## Open

- The factory bank (layer 2) adds pieces per patch family; SQ-80 returns when the ban lifts.
- Thresholds were calibrated on this machine's renders of this set; recalibrate (`calibrate.rb`) when pieces change a lot.
- Piece renders must be deterministic (same command, same samples): a piece that stops being so fails `rerender` in the calibration and should be fixed (a seed), not given wider thresholds.
