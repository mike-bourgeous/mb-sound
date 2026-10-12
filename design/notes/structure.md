# Structure analysis (music information retrieval)

CLAUDE.md keeps a summary and points here.  Update both when behavior changes.

Audio in, song structure out, as a later arrangement phase (maintainer, 2026-10-11: "The music information retrieval idea for identifying structures is a great idea; let's build that at some point, maybe as a later arrangement phase").  Research spike: branch `research-structure-analysis` (45df0158), `research/structure-analysis/README.md` (method, results, phases S1-S4, the prototype `structure_analysis.rb`, ground truth and scoring in `ground_truth.rb`/`evaluate.rb`).

Maintainer's decisions (2026-10-12, all four of the spike's recommendations): section labels are letters (`a`, `b`, `a2`), guessed names later as an option; our own renders use the Session's exact grid by default and only imported audio is beat-tracked; analysis markers go in the Session's marker table with an `:analysis` kind and prefixed names, so they can't clash with a playing form; a phrase level under sections in S3.

## Phases

- **S1 (branch `structure-1`, 2026-10-12): grid and meter.**  Built; below.
- S2: bar features, self-similarity, novelty, DP segmentation with the 4/8/16-bar prior, letter labels, `form` / `markers!` (`:analysis` kind) / `meters!`, a rendered flow analyzed back to its boundaries, `take.form` comparison.
- S3: phrases under sections, energy cues (fades, risers, drops), a backbeat model (fixes drums_808 and the half-time downbeats below), guessed section names.
- S4: other music (tempo drift, 3/4 and 6/8, repetition-based boundaries, an annotated corpus).

## S1: tempo, beats, bars, meter (`lib/mb/sound/structure.rb`, `structure/`)

Pure Ruby + Numo (Pocketfft), no new gems, no C (features are 85% of the time and still about 120x realtime).

- `MB::Sound.analyze_form(source, **options)` (alias `analyze_structure`; `StructureMethods`; names checked against MB::Sound methods and Pry commands) returns a `Structure::Result`.  Sources: a filename (read at 48 kHz), audio data (Array of channels or a Numo array, `sample_rate:`), or a graph or a block rendered in memory (`Structure::Capture`, a NullOutput that keeps the buffers) for `bars:`/`seconds:` at `bpm:`; the block works like `render`'s (`bg`, `at_bar`, `meter`, ...).
- Our renders use the render's grid: the transport the render ended with (its tempo and meter map, including meter changes made while rendering), so beats and bars are exact (`tracker: :transport`).  `grid: false` tracks instead (specs use it to test the tracker on known audio).  Files and data are tracked unless `grid:` is a Transport or a Session (its transport) whose timeline position 0 is at `start:` seconds in the audio.
- `Structure.analyze(data, ...)` options: `bpm:` hint (replaces the estimate; the grid still refines within `refine:` ±0.5 %, `refine: false` uses it exactly), `beats: :grid | :dp`, `beats_per_bar:` (4), `short_bars:` ([2, 3]), `downbeat_penalty:` (15), `phase_weights:` ([4, 1, 1]), `offset:` (`ONSET_LATENCY`), `min_bpm:`/`max_bpm:`/`center_bpm:` (50/220/120).
- Result: `tempo` (alias `bpm`), `tempo_estimate` (the autocorrelation's pick, nil with a hint or grid), `beats` (`Structure::Beat(seconds, bar, beat)`, printed `bar:beat` like Stamps; a pickup before the first downbeat is bar 0), `bars` (`Structure::Bar(number, seconds, beats, end_seconds)`, `#length` in whole notes, `#meter` like "2/4"; numbered through irregular bars like `Transport#bar_at`), `meters` (`Transport::Meter(pos, bar_length, bar)` entries, pos 0 at bar 1's downbeat), `irregular_bars` (the last bar is never irregular: it runs off the end at the usual length), `downbeats`, `transport` (a new Transport with the tempo and meter map), `bar_at(seconds)`/`seconds_at(bar)`, `meters_ruby` (`meter 2, 4, at: bar(33)` lines), `tracker`, `timings`, `frames`.  Beats and bars cover the music from the first beat with sound to the last (silent ends trimmed, on the transport grid too).

Method (the spike's, with S1's changes marked):

1. `Frames`: mono mix, 2048-point Hann STFT, hop 512 (93.75 fps at 48 kHz), reduced chunk by chunk (256 frames) so the magnitude spectrogram is never kept (S1; a 3-minute song is about 15 MB of features); 64 log-mel bands (30 Hz to 16 kHz, 80 dB floor), MFCC 0..19, chroma (55 Hz to 5 kHz), bass chroma (55 to 300 Hz, S1), energy, three-band log-mel flux (<150 Hz, 150 Hz to 2 kHz, >2 kHz).  Onset envelopes per band: minus the 1 s moving average, rectified, unit deviation; the tempo envelope averages them, the phase envelope weights them 4:1:1.
2. `Tempo.estimate`: autocorrelation of the onset envelope, a comb over four multiples of each lag (quarter-frame steps, parabolic peak), log-normal prior around 120 BPM one octave wide.  (TPS2, lag + 2 lag, picked 84 BPM for the 126 BPM night bus.)
3. `Beats.grid` (default): the period within ±1 % (0.02 % steps) whose onset fold (100-bin phase histogram, now a Numo `bincount`) has the sharpest peak, the phase from the 4:1:1 fold, silent ends trimmed; then (S1) `straighten`: a line through the onset peaks near each beat (Theil-Sen start, least squares within one frame).  The fold alone was 0.06 % off on an 8-bar groove (9 ms of drift); with the line, generated grooves come out at the exact tempo with beats within 0.3 ms, and a stray first-frame peak can't pull it.  `Beats.dp` (`beats: :dp`): Ellis 2007 (tightness 100), period from a least-squares fit; it drifts to offbeat hats on the night bus (below).
4. `Meter.observations` + `Meter.downbeats`: per beat, z-scored timbre change (MFCC 1..13 from the previous beat), harmony change, bass change (S1), energy rise, and half the low onset; a Viterbi over the position in the bar where a bar may end after 2 or 3 beats at a cost of 15.  S1 changes: the harmony change compares the 2 beats before with the 2 from the beat (half a bar) instead of beat to beat, so drum noise averages out and a kick on 3 doesn't look like a chord change; the bass chroma change is added at weight 1 (0 missed the 2/4 bar in generated grooves; 2 added false 2-beat bars in the night bus and drums_808); the first beat and the windows' edges get neutral values instead of "no change" (which pushed bar 1 a beat or two late).  Penalty sweep on the spike's songs: 8 and 10 add false 2- and 3-beat bars in the night bus (bars 7, 49), 12 and 15 are clean.
5. `ONSET_LATENCY` = 5 ms added to tracked beats: the flux peaks while the window's leading half takes in a transient.  Measured early by 4.9 ms on generated 808 grooves, 10-11 ms on the night bus, 1.5-3.7 ms on the pad songs; with the 5 ms, the songs measure -5.9 to +2.4 ms.

### Measurements (2026-10-12, the spike's five renders, its scoring: beats and downbeats ±70 ms)

| song | BPM | found | error | beat F | beat offset | downbeat F | irregular bars | time | x realtime |
|---|---|---|---|---|---|---|---|---|---|
| night_bus | 126 | 126.005 | 0.004 % | 0.999 | -5.9 ms | 0.994 | 33 (2 beats) | 1.41 s | 123 |
| night_bus_seed12 | 126 | 126.003 | 0.002 % | 0.999 | -4.9 ms | 0.995 | 33 (2 beats) | 1.55 s | 130 |
| tween_song | 96 | 95.98 | -0.021 % | 1.0 | 1.5 ms | 1.0 | | 0.37 s | 126 |
| drums_808 | 112 | 112.002 | 0.002 % | 0.0 | (half a beat) | 0.0 | | 0.27 s | 130 |
| unison_song | 100 | 99.961 | -0.039 % | 0.968 | 2.4 ms | 1.0 | | 0.21 s | 124 |

One core, `nice`, on the Linux desktop with other agents running.  Night bus timings: read 0.17 s (ffmpeg), features 1.25 s (the per-frame FFT loop), beats 0.05 s, downbeats 0.01 s, tempo 0.001 s.  With `beats: :dp`: night bus beat F 0.63, downbeat F 0.02 (false 3-beat bars at 7 and 30), tempo -0.25 % on seed 12; the pad songs within 0.1 %.  The script was the spike's `evaluate.rb` cut down to S1 (tempo, beats, downbeats, irregular bars) and pointed at `Structure.analyze`; inputs as in the spike's README (`/tmp/structure-analysis/*.flac` or `/app/tmp/listening/...`).

Generated grooves (`spec/lib/mb/sound/structure_spec.rb`; an 808 kit with kick on 1 and 3, claps on 2 and 4, eighth hats, and a saw bass changing notes every bar): tempo exact to 0.01 BPM, beats within 0.3 ms after the latency, the 2/4 bar found at 100, 112, 120, 128, 140 BPM with kicks on 1 and 3, 1 and 3.5, or every beat, given 4 or more bars before it.  A 2/4 bar after only 2 or 3 bars of half-note kicks was missed (the short-bar cost needs evidence on both sides).  A render-and-analyze of 8 bars takes about 0.4 s.

### Known limits

- drums_808 (kick `X.....x...X..x..`, accented offbeat hats): the grid sits half a beat late; more onset energy in every band is off the beat.  Spec'd as a known limit (the median beat phase is 0.5); S3's backbeat model is the fix.
- Half time (kick on 1 and the and of 3, clap on 3, at 140 BPM): tempo and beats exact, downbeats a beat early.  The kick's long tail makes beat 4's timbre like beat 1's, and the drums outweigh the bass in chroma.  Spec'd for tempo and beats only.
- One constant tempo; 4/4 with occasional 2- and 3-beat bars unless `beats_per_bar:` says otherwise; downbeats need a harmonic or bass change at bar lines (drum-only loops with kicks on 1 and 3 are ambiguous).
- `at_bar(n)` blocks are scheduled at the timeline position bar n had when scheduled, so in a render whose earlier `at_bar` block changes the meter, a later `at_bar` lands elsewhere; the specs set meters up front with `meter 2, 4, at: bar(5)` (a scheduling gotcha seen while writing the specs, not a structure issue).
