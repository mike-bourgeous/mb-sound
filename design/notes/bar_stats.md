# Bar statistics

<!-- summary -->
`bar_stats(file, bpm:)` and `compare_bars(a, b)` (`BarStatsMethods`; `MB::Sound::BarStats`, `lib/mb/sound/bar_stats.rb` + `bar_stats/`, pure Ruby + Numo) measure a recording beat by beat on its grid (a render's exact one, `render(..., bar_stats: true)`; a constant `bpm:`/`offset:`; or Structure's tracking) and reduce to bars, sections, and the song: onset timing per band (low/mid/high), loudness (LUFS, momentary/short-term maxima, RMS, peaks, true peak, crest, tails), octave bands, centroid, tilt, width and side per band, chroma and key; a broadcast loudness report with delivery pass/fail (`Broadcast`); a readable-Ruby sidecar beside the file (`song.flac.bar_stats.rb`, read with Prism, never run; fresh by digest); and bar-by-bar comparison with per-band lags, worst bars, likely causes by rule, thresholds for specs, and a narrative.
<!-- /summary -->

## Quick reference

- Console: `r = bar_stats('song.flac', bpm: 140)` (`r.bars[:lufs]`, `r.bar(9)`, `r.section('A')`, `puts r.broadcast`; `save: true` writes the sidecar, `cache: true` reads a fresh one), `c = compare_bars('a.flac', 'b.flac', bpm: 140)` (`c.worst(5)`, `c.causes`, `c.narrative`, `c.check!(timing: 2)`), `compare_bars(r, sections: ['A', "A'"])`; renders: `render 'song.flac', bars: 64, bar_stats: true { song }`.
- Library: `BarStats.analyze(source, grid:, bpm:, offset:, sections:, stems:, targets:, save:, cache:)`, `.compare(a, b, align:, max_lag:, thresholds:)`, `.load(path)`; `Grid` (`.constant`, `.from_structure`, `Grid::Recorder`), `Bands`, `Timing` (`.grid_offsets`, `.lags`), `Measures`, `Table`, `Broadcast`, `Report`, `Sidecar`, `Comparison` (`THRESHOLDS`, `CAUSES`).
- Script: `bin/bar_stats.rb [-b BPM -o OFFSET] [--bars] [--save] FILE [FILE_B] [--check --timing MS]`.
- Code `lib/mb/sound/bar_stats/`; specs `spec/lib/mb/sound/bar_stats/` on synthetic songs (`spec/support/bar_stats_sounds.rb`), `spec/bin/bar_stats_spec.rb`; help `help :analysis`.

The summary block above feeds the generated index (`design/notes/README.md`, `rake docs:index`).  Update it when behavior changes.

## Why (2026-11-08)

The maintainer: "Let's brainstorm some tools that gather statistics per bar vs. over a whole song.  I think these would be useful for identifying localized mix and .acd converter issues, as well as my idea of a histogram-based mastering approach."  His answers (brainstorm `workbench/briefs/bar-stats-brainstorm.md`): measures in the order timing, loudness, spectral, stereo, plus harmony (mastering omits timing); per bar by default, per section, and everything per beat; mix for mastering, mix + stems for troubleshooting; comparisons of a conversion with its original, a song with a reference, section with section; reports with the worst bars, which measure moved, a likely cause, and pass/fail thresholds; a sidecar per render plus the broadcast loudness numbers a video editor shows.  "Build A+B in the background for now and save the rest for a future mastering-related round": this round built the grid, the measures, the sidecar, and the comparison (sketch steps 1-4) with console entry points and a script.  Views (a console heatmap, a report page with a bar A/B player) and the per-bar mastering experiment (quantile matching of sorted bars, psychoacoustic smoothing, transient-masked gain changes) are later rounds.

The lesson that shaped the timing layer (2026-11-08): an .acd conversion's drum bus was 66 ms late, and whole-mix timing (one cross-correlation of the mixes) missed it, because the other parts were on time.  Every timing number here is per band.

## Grid

`Grid` holds Structure's own `Beat`, `Bar`, and `Section` values in seconds.  Sources:

- `:render`: `Grid::Recorder`, a Session tap attached by `render(..., bar_stats: true)`.  After each buffer it reads the timeline position and finds the quarter notes crossed in `[start, end)` of the buffer, each at its interpolated frame (exact while the buffer's tempo is constant; ramps change tempo in 800-frame cells, read to a fraction of a sample), numbered through the meter map.  Section passes come from `MixReport::SectionMarks` (the same frames as the mix report and per-section mastering).  A buffer whose timeline moved more than `JUMP` (10%) off its tempo's step held a seek: it counts as if it started where the timeline would have to start to reach its end, so a beat in such a buffer may be off by up to a buffer.  Beats in the file's last frame are dropped (a render's end bar rounds up to a whole frame).  Render windows (`from:`) shift the grid to the file's first frame.
- `:transport`: a constant-tempo Transport through `Structure.analyze(grid:)`.
- `:tracked`: Structure's beat tracking (`bpm:` as a hint), its sections.
- `:given`: `Grid.constant(bpm:, offset:)`, bar 1's downbeat at `offset`, beats before it a pickup in bar 0.

Sections default to the grid's (form passes, tracked analysis); a grid without any gets Structure's S2 sections on its bars (`BarStats.analysis_sections`, `Sections.find` on the bars and Structure frames).  `sections: false` leaves them out.  Beat spans run to the next beat; the last lasts the median beat.

## Timing per band

`Bands`: low/mid/high at Structure::Frames' onset bands (150 Hz, 2 kHz) by two 4097-tap linear-phase Blackman windowed-sinc lowpasses applied by FFT with their delay removed: zero phase (an impulse peaks on its own sample in every band), summing to the signal exactly (1e-16), and sliceable with margins (a slice equals the whole within 1e-9).

`Timing.onset_function`: the band's amplitude envelope (squared band smoothed twice by a centered moving mean of `SMOOTH` seconds: 12/4/1.5 ms low/mid/high, a triangular window whose sidelobes leave little of a low note's ripple) and its rise across `SMOOTH`, positive part.

Grid offsets (`Timing.grid_offsets`, the `onset_*` measures): per beat and band, the onset function's largest peak within `WINDOW` (a quarter beat) either side, or the first peak reaching half of it up to 20 ms earlier (a chord's attack rather than its beating just after), less the place a hard attack reads (`calibration`: a tone starting on a sample at 70/550/5500 Hz).  A beat's onset counts when it reaches `FLOOR` (20%) of the band's typical (75th percentile) beat onset, and a band whose typical onset is under 1% of the strongest band's holds only leakage (nil).  Measured on the synthetic songs: kicks and hats read within 0.5 ms of the beat (0.2 and 0.0 ms); a hat delayed 96 samples reads exactly 2.000 ms later than the undelayed one.  Chords whose tones beat read later (a C major triad of equal sines: 13.7 ms; its energy keeps rising for a beat of its beating), so grid offsets compare recordings of the same parts; absolute offsets of sustained parts are not hit times.

Lags between two recordings (`Timing.lags`, the comparison's `lag_*`; `Timing::Lag` values: `samples`, `wave`, `onset`, `on_time`, `reliable?`, `by`, `ms`): per bar and band, the onset functions at about 1 kHz (`coarse_onsets`: block mean squares) cross-correlated within ±`max_lag` (125 ms by default); the peaks within 90% of the best (at most `MAX_CANDIDATES` 4, nearest the band's whole-song lag first: `song_lags`, the same correlation over the whole song) are each refined on the band waveforms within ±2 ms (a dot product per lag, a parabola through the peak), and the best waveform correlation wins.  Under a waveform correlation of 0.3 the onset lag stands (about 1 ms resolution), and it counts (`reliable?`) when the onsets correlate 0.25 or more: lossy or re-rendered copies line up on their hits where their waveforms differ (an MP3's top band against a render's).  Several candidates because rhythm and harmony repeat: a C major triad's 4:5:6 partials repeat every 15.3 ms, so its onset peaks tie at 66 ± 15 ms, and the pick nearest the song lag alone took 81 ms.  `on_time` (for lags past 2 ms): the waveform correlation within 2 samples of lag 0 less twice what unrelated lags (±3, 5, 7, 11 ms) give by chance: how much of the band still lines up beside a late part.  Measured: a band delayed 37 samples reads 37.00 (corr 0.92-1.0) with the other bands under 0.05 samples; a 66 ms (3168-sample) delay of kick and hats at 140 BPM, past the 107 ms spacing of 16th-note hats, reads 3168.00 in the high band and 3167.9 in the low band (the chord's leakage there stays put); kick, clap, and hats 66 ms late beside on-time steady noise read 66.0 in every band with on_time 0, 0.53, and 0.79 (low, mid, high).  Cost about 0.06 s per second of audio on the Mac container (two band splits and a few hundred dot products per band and bar).

## Measures

Per beat, each kept as sums so bars, sections, and the song are measured from their beats the way they would be measured whole (energies add, peaks take the largest, spectra add before dB), not by averaging dB:

| group | columns | how |
|---|---|---|
| timing | `onset_low`, `onset_mid`, `onset_high` (ms, nil without an onset) | Timing.grid_offsets; bars and longer take the median |
| loudness | `lufs` (ungated mean over the span), `momentary_max`, `short_term_max`, `integrated` (gated; bars and longer, nil where no 400 ms block fits) | one `Loudness::Analyzer` over the audio: `mean_loudness_in`, `momentary_max_in`, `short_term_max_in`, `loudness_in` |
| | `rms`, `peak` (dBFS over the channels), `true_peak` (dBTP, the Annex 2 kernel on each span with its filter history), `crest` (peak minus RMS), `tail` (the beat's second half re the whole beat, dB) | samples of the span |
| spectral | `bands` (octave levels at `Spectrum::OCTAVE_CENTERS`, dB RMS), `centroid` (Hz), `tilt` (dB/octave over third octaves, `Spectrum.tilt_of`) | each beat's own FFT (the span zero-padded to a power of two, at least `MIN_FFT` 4096): by Parseval its power is the span's energy, so a hit on the beat counts whole in its beat |
| stereo | `correlation` (first two channels), `width` (side re mid, dB; -Infinity for no side), `side_low`, `side_mid`, `side_high` (per Bands band; nil where the band holds under -60 dB of the mid) | time-domain sums; side and mid powers from the same FFTs |
| harmony | `chroma` (12 shares, C first), `key`, `key_r` (bars and longer) | `Analysis::Chroma` frames centered in the span; `Analysis::Key.detect` |

Why each beat's own FFT, not STFT frames (measured while building it): hits sit exactly on beat edges.  With 85 ms frames assigned to the beat holding their centers, a kick left out of a bar read only 12.5 dB down in its 63 Hz octave (the next bar's downbeat kick reached back into the last frames); with only frames wholly inside a beat, a hat moved 10 ms later raised the 2-16 kHz octaves by 13-15 dB and the tilt by 2.8 dB/octave, because the frames had caught the undelayed hat only under their windows' leading edges.  One FFT per beat has no edge to weigh, costs about the same (one 32k FFT per beat at 140 BPM), and its rectangular window's leakage stays about 50 dB down a few octaves away.

`Table` keeps a level's measures as Numo columns (NaN for no value, rows x n for `bands` and `chroma`, Arrays for keys); `row(i)` and `at(key)` give Hashes.  Mix and stems are measured alike (`stems:` a Hash or a directory; each on the mix's grid and sections).

## Broadcast report

`Broadcast` (from the same Analyzer when the file is at 48 kHz, else `MB::Sound.loudness` at the file's own rate): integrated loudness with its relative gate, LRA with its ends, max true peak and sample peak, max momentary and short-term, PLR, and a `Check` per target (`Loudness.target` names or numbers): pass when within the target's published tolerance (1 LU where none is published, e.g. streaming) and under its true-peak ceiling.  Default targets: EBU R 128 (-23 ±0.5, -1 dBTP), ATSC A/85 (-24 ±2, -2 dBTP), Spotify (-14, -1 dBTP).

Against `ffmpeg -af ebur128=peak=true` (2026-11-08, Mac container): 12 s of band-limited noise bursts (spec) within 0.1 LU integrated, 0.2 LU LRA, 0.3 dB true peak.  White noise's top octave is the true-peak filters' worst case (Annex 2's 12 taps read 0.6 dB under ffmpeg's interpolator); `Loudness::TruePeak`'s `:accurate` filter is closer there.  A 12 s render with a nearly constant level read LRA 0.66 here and 0.0 in ffmpeg (Tech 3342's trailing-silence rule on short files).

## Sidecar

`song.flac.bar_stats.rb` beside the file: one call per line (`bar_stats FORMAT, file:, digest:, bytes:, mb_sound:, made:`, `settings ...`, `grid source, tempo:, duration:`, `bar n, seconds, beats, end`, `section label, first_bar, bars, seconds, end`, `loudness ...`, `table level, [columns]` followed by `row ...` lines, `stem name, path`), values printed by `RubyValue`.  `Sidecar.read` walks the Prism tree with `RubyValue.literal` (plain values only; any other node raises), so a sidecar is data, never code.  The beats table carries the beat times (the grid's beats are rebuilt from it).  Paths are relative to the sidecar's directory when inside it.  A 3-minute song at 140 BPM writes about 420 beat rows.

Staleness: `Sidecar.fresh?(sidecar, file, settings)` holds while the format number (`Sidecar::FORMAT`, 1) and the file's SHA-256 match and the saved settings answer the request (grid kind, bpm, offset, beats per bar, sections, window); `analyze(..., cache: true)` reads a fresh sidecar instead of measuring.

## Comparison

`BarStats.compare(a, b)` measures B on A's grid (shifted by `align:` seconds) and pairs bars by number; `Comparison.sections(report, a, b)` pairs two sections' bars by position (timing from grid offsets; no lags).  Per bar: the change of every measure (B minus A; levels under -90 dB, side levels under -40 dB, and tails under -60 dB read as those floors, so a part going silent or a collapse to mono shows), each band's lag in ms with its waveform correlation, a score per measure (|change| / threshold) and the largest.  `THRESHOLDS`: timing 5 ms, lufs 1 LU, rms 1 dB, true peak 1 dB, crest 1.5 dB, tail 3 dB, bands 6 dB, centroid 15%, tilt 0.75 dB/oct, correlation 0.2, width 4 dB, side 4 dB, chroma 0.25 (1 minus the cosine).  `failures(**thresholds)`, `pass?`, and `check!` (raises naming the measures and their bars) take overrides; nil skips a measure.

Likely causes (`CAUSES`, by rule): every band late alike within 1 ms, either a file offset (encoder delay or a trimmed start; the text gives the `align:`) or, when a median `on_time` of 0.2 or more says part of each band still lines up, a late part (`:late_part`: a bus or track whose hits fill every band, drums usually, outweighing what lines up in each band); bands whose median lag passes the threshold, agreed by a quarter of the bars (bands within 1 ms of each other make one cause naming them, with the bands on time and how a mixed band's bars split between the late lag and 0, as a low band holding a late kick and an on-time bass does: a late or early bus or track); tails shorter or longer (reverb or delay), louder with less crest (over-compression), octaves 12 dB or more down or up (neighbors in the same bars merged; EQ or a missing part), chroma past the threshold (a transpose when one rotation of A's chroma explains B's, else a wrong clip), narrower or more correlated (a mono fold or a missing wide part), a level step with the same crest (gain, automation, a part missing).  Localized causes need one bar.  `narrative` writes the chat summary from the same data: bars compared and failing, the median band lags, the worst bars, the causes, and the measures that stayed within thresholds.

Synthetic checks (spec): each case names its cause and bars: a band 37 samples late (that band, 37.00 samples, the others on time), a 10 ms file offset (and aligned away), a late part filling every band beside an on-time pad, a 6 dB step (bars 3-4, -6.0 LU), a stereo collapse, a missing kick (31.5-125 Hz octaves, bars 2-3), a +2 transpose, missing tails, tanh over-compression, and a recording against itself (passes, no causes).

## Known limits and open questions

- Grid offsets of sustained parts are not hit times (above); the comparison's lags are the exact timing tool.
- One constant tempo for tracked and given grids (renders follow tempo maps exactly).
- Chroma frames (341 ms windows) are centered in beats, so a beat's chroma includes its neighbors' edges; keys per bar are short-window guesses (`key_r` says how clear).
- Names and formats are the conservative choices, open for the maintainer: `bar_stats`/`compare_bars`, `render(bar_stats:)`, the sidecar name `song.flac.bar_stats.rb` and its line format, the default thresholds and targets.
