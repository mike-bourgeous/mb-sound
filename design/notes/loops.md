# Loop files, slice stretch, tempo-following loops

<!-- summary -->
`Sample['loop.wav']` reads loop metadata without ffmpeg's help (`Sample::Riff`: ACID tempo/beats/meter/root, `smpl` loops, cue labels as `sample.markers`), then FLAC tags, then tempo and key words in file and folder names (`Sample::LoopInfo`, reasons in `meta[:why]`), or detects the tempo and key (`detect: true`; `#detect_key`, Krumhansl-Schmuckler on a chromagram fold, `Analysis::Key`).  `stretch(r, mode: :slice)` (`Sample::SliceStretch`) moves slices to scaled times with exact attacks; `sample.follow` (`GraphNode::LoopPlayer`, a TimelineNode and plan boundary) plays a loop in time with the session tempo (slice stretch for percussive loops, spectral for tonal ones).  Console `loops(dir, bpm:, key:, beats:, detect:)` lists a folder from headers and names only (`detect:` decodes files missing a tempo or key; keys match enharmonically).  Help `help :loops`.
<!-- /summary -->

## Quick reference

- `Sample['loop.wav']` reads ACID/`smpl`/cue metadata, tags, and names (`sample.meta[:why]`); `detect: true` or `#detect_key` measures; `stretch(r, mode: :slice)`; `sample.follow` plays in time with the session tempo.
- Console `loops(dir, bpm:, key:, beats:, detect:)`; help `help :loops`.

The summary block above feeds the generated index (`design/notes/README.md`, `rake docs:index`).  Update it when behavior changes.

Branch `loops-1` (2026-10-15).  The maintainer: "If we add a slice-based stretch, could we start loading ACID metadata?  I have a large loop library."  Builds on the sampler (`sampler.md`: `Sample`, onsets, the cyclic stretch) and the spectral stretches (`granular.md`).

## API

```ruby
brk = Sample['~/Loops/Funk/break_98bpm.wav']   # ACID chunks, smpl, cues, tags, then names
brk.bpm  brk.beats  brk.bars  brk.meter  brk.key  brk.root  brk.markers  brk.meta_source
Sample['take3.wav', detect: true]              # tempo detection when nothing says (cached)
brk.detect_tempo                               # the same on any Sample
brk.stretch(1.25, mode: :slice)                # slices at the hits, attacks exact
brk.stretch(1.25, mode: :slice, fill: :stretch)   # each decay drawn out instead of a gap
brk.stretch(0.8, mode: :slice, slices: :grid)  # markers / onsets / grid / a Duration / a count / positions / Slices
bg :brk, brk.follow                            # follows the session tempo (pitch kept, slice stretch)
bg :pad, pad.follow(stretch: :spectral)        # any stretch mode or a Hash of stretch options
bg :vinyl, brk.follow(:resample)               # pitch follows the tempo (varispeed)
brk.node(follow: true)                         # the same as follow
loops '~/Loops/Funk'                           # a listing (no audio decoded)
loops('~/Loops', bpm: 90..100, key: [:Am, :C], beats: 8)[0].sample.follow
```

Signatures: `Sample['Funk/break_98bpm.wav']` (`sample.markers`, `bpm`, `beats`, `bars`, `meter`, `key`, `meta_source`); `Sample[path, detect: true]` / `#detect_tempo` (Structure on the loop tiled to 8 s, cached); `stretch(r, mode: :slice, fill: :gap | :stretch, slices:)` (ratio 1 is exact; 4 ms fades and pre-rolls at every discontinuity); `sample.follow(:stretch | :resample, stretch: :auto, align: :timeline | :launch)` (restretched per 1/4 BPM, cached); `loops(dir, bpm:, key:, beats:, detect:)` (never writes); `#key_analysis`, `#detect_key` (below).  Every stretch divides `bpm` by its ratio.  Help `help :loops`.

## Keys from the audio (listen-1, 2026-10-30)

`Sample#key_analysis(profile: :krumhansl | :temperley)` is an `Analysis::Key::Result` (cached per audio and region): the Krumhansl-Schmuckler method, the region's chromagram (`Analysis::Chroma`: 16384-point Hann frames every 4096 samples, 65 Hz to 5 kHz, folded onto 120 bins an octave, the tuning their circular mean, then 12 pitch classes at that tuning) summed over frames and correlated (Pearson) with the Krumhansl-Kessler major and minor profiles rotated to each tonic; the best of 24 is the key, with its correlation, the runner-up, the margin, and every score.  `Sample#detect_key(force: false)` sets `key` (`meta_source[:key] = :detected`) when the pick is clear (`Result#clear?`: r at least `MIN_CORRELATION` 0.7 and a margin of `MIN_MARGIN` 0.02) and `#material` isn't percussive; the reason is in `meta[:why][:key]` either way.  `Sample[path, detect: true]` detects a missing tempo and key (`detect: :bpm`, `:key`, or an Array; other names raise with did_you_mean); `loops(dir, detect:)` does the same for listed files that nothing gave a tempo (loops only) or key, remembered per path, size, and mtime for the process, and `key:` filters match any spelling (`Analysis::Key.parse`/`.same?`: `:"A#m"` finds `:Bbm`; before, only the exact Symbol matched).  Keys print as `Sample#key` always has (`:Am`, `:"F#"`, `:Eb`): flats for F, Bb, Eb, Ab, Db major and Dm, Gm, Cm, Fm, Bbm, Ebm, sharps otherwise.  `Result#musical_key` gives a `MusicalKey` for the session key.

Measured (2026-10-30, `spec/lib/mb/sound/analysis_spec.rb` and a lab script): I-IV-V-I and harmonic-minor i-iv-V-i triad progressions (8-partial decaying tones, the root an octave down) in all 24 keys come out right with r 0.83-0.96 and margins 0.10-0.22, one of them 30 cents sharp (tuning found within 3 cents); a saw Am-F-G-Am clip 0.90 (next C major 0.77), the same over an 808 groove 0.89; drums alone: the jungle break 0.41, an 808 groove 0.66 (its tuned kick and snare read as D minor, margin 0.26: why the material check is there), a 909 groove 0.69 (margin 0.01), white noise 0.28.  The usual confusions of the method are the relative major/minor and the keys a fifth away (`scores` shows them).  Speed: about 100x realtime (a 180 s song in 1.85 s on the Mac container; the fold reads only the fifth of each spectrum inside 65 Hz to 5 kHz).

Not yet: key changes inside a sample (a windowed fold, `Chroma#fold(from:, to:)` is there for it), modes beyond major/minor, profiles for electronic music (Faraldo's EDM profiles), the attack-only listing shortcut for keys.

## RIFF chunks (`Sample::Riff`)

ffmpeg ignores the chunks loop libraries rely on, so a Ruby reader reads the headers and skips the data chunk.  Layouts (little-endian):

- `acid` (24 bytes; libsndfile's `wav_read_acid_chunk`): uint32 flags (0x01 one-shot, 0x02 root note set, 0x04 stretch, 0x08 disk-based, 0x10 high octave), uint16 root note, uint16 + float32 unknown, uint32 beats, uint16 meter denominator, uint16 numerator, float32 tempo.
- `smpl` (36 + 24 per loop): unity note, pitch fraction (of a semitone, /2^32), loops (type 0 forward, 1 ping-pong, 2 backward; end inclusive).
- `cue ` (4 + 24 per point; the sample offset is the position), `LIST`/`adtl` `labl`/`ltxt`, `LIST`/`INFO`.
- `strc` (ACID's slice/stretch data) is not decoded: no public description of its layout could be confirmed (searches 2026-10-15 found only `acidcat` listing it as a writer signature), so slices come from cue points or onsets.

Robustness: odd chunk sizes with or without the pad byte (an unpadded chunk is recognized by a chunk id starting right after it and none a byte later), RF64/BW64 (`ds64` data size), WAVE_FORMAT_EXTENSIBLE (subformat from the GUID), unknown chunks, truncated files (data size clamped to the file), chunks over `MAX_CHUNK` (4 MB) skipped, counts clamped to their chunk, at most 10000 chunks.  `Riff.write` makes fixtures (specs write theirs at run time; no third-party loops in the repo).

## Metadata (`Sample::LoopInfo`, `Sample` attributes)

Order: our own tags (`Sample#save`) > ACID/smpl/cue chunks (WAV, and FLAC APPLICATION `riff` blocks from `flac --keep-foreign-metadata`) > tags (FLAC Vorbis comments BPM/TBPM/TEMPO, KEY/INITIALKEY; ffmpeg metadata) > names (file, then up to 3 folders) > detection, only when asked.  Explicit options win over all.

- Names: "98bpm", "98 BPM", "bpm140", a bare 60-200 number only when no "bpm" word appears and only one such number; keys as capitalized words (Am, F#m, Ebmaj7, C#min, "F minor"), a lone letter only next to a tempo ("Loop A 90").
- `beats`: the file's count (ACID) while the region is the whole file, else tempo × length (whole within 2%, else a Float).  `bars` = beats / meter numerator.  ACID one-shots keep no tempo.
- ACID root (when the root-set flag is on) sets `root`; `smpl` sets the root (unity note minus pitch fraction) and the loop; an ACID loop without a `smpl` loop loops the whole file (`:forward`).  Positions scale from the file's rate to 48 kHz.
- `markers`: `Sample::Marker(position, label)`, play-order positions from the region start; views keep them, edits scale them.
- Every stretch now divides `bpm` by the ratio (before loops-1 a stretched bounce kept its old tempo for Durations).
- `detect_tempo`: `Structure.analyze` on the loop tiled to at least 8 s (the loop repeats seamlessly, so the tracker sees several cycles), rounded so the loop holds whole beats when within 5%; the analysis is cached per audio and region.

## Loop or one-shot, and name tempos that fit (round 2, maintainer 2026-10-15)

Maintainer: bare numbers in names "should check that the length of the file plausibly matches the tempo, and default to one-shot below a certain length"; "I don't think ACID loops ever loop just a subset."

- **Name tempos must fit** (`LoopInfo.fit_tempo`): every tempo in the file name and up to 3 folders (numbers next to "bpm", else every bare 60-200 number), and each one's double and half (double/half-time names), counts only if the length is a whole number k ≥ 1 of its beats within max(5 ms, 1.5% of a beat) (a trimmed tail or padded end of a few ms still fits).  Best score wins: the fit error over the tolerance, +0.75 for double/half time, +0.5 unless k is 1/2/4/8/16/32/64 or whole bars, +0.25 for bare numbers, +0.1 per folder level up.  The reason is kept in words (`entry.why[:bpm]`, `sample.meta[:why][:bpm]`): "name 98 (fits 8 beats)", "name 87 as 174 (double time, fits 3 beats)", "name 98 (no fit to 3.300 s)" (no tempo then; `detect: true` still works).  Without a known length (listing an mp3) the first explicit tempo, or the only bare number, counts unchecked ("length unknown"); `Sample.from_file` passes the decoded length.  ACID and tag tempos are not checked.
- **Loop or one-shot** (`LoopInfo.classify`, `entry.one_shot` true/false/nil, `sources[:one_shot]`, `why[:one_shot]`), first rule that applies:
  1. ACID's one-shot flag, always.
  2. A `smpl` loop (non-ACID files): a loop at those points.
  3. A word in the nearest name that has one (file name, then folders): loop words (loop, groove, break, beat, pattern, phrase, riff, top, fill, plurals) win over one-shot words (kick, snare, clap, rim, tom, crash, cymbal, cowbell, hit, shot, "one shot", stab, fx, sfx, impact, zap) in the same name, so "Kick Loop" is a loop and "One Shots/Loop 3.wav" a loop; a folder's loop word doesn't make a file shorter than `SHORT` a loop ("Loops/blip.wav").
  4. Shorter than `TINY` (0.25 s, one beat at 240 BPM): a one-shot.
  5. A name tempo that fits: a loop at that tempo.
  6. Shorter than `SHORT` (0.75 s, one beat at 80 BPM, the slowest common loop tempo: a sound shorter than that with no fitting tempo is a hit): a one-shot.
  7. In `Sample.from_file` only (it has the audio), files rules 1-4 didn't decide and rule 5 called loops: one hit decaying to silence is a one-shot (at most one onset, within 10 ms of the start, and the last tenth 30 dB below the loudest 10 ms; `Sample.decays?`).
  One-shots keep no name tempo (the reason says "dropped: a one-shot").  Loops play `:forward` over the whole file unless a `smpl` loop applies; **ACID loops always loop the whole file**, keeping any `smpl` loops only as metadata (`sample.meta[:smpl_loops]`); smpl loops still apply to non-ACID files (sampler instruments).
- `loops()` shows `kind` (loop, one-shot, -) and `why` (`Entry#reason`).  `LoopInfo.scan` ignores folder names above the listed folder (a library root called "Loops" says nothing about one file).

Ideas not built (cheap signals for later):
- An "attack-only" check in listings (read the first and last 100 ms of PCM WAVs directly; no ffmpeg) so `loops()` can apply rule 7.
- A loop seam check: a loop's end flows into its start (small step at the seam, similar spectra) where a one-shot's tail doesn't.
- Onset spacing: onsets on a regular grid at a fitting tempo (strong evidence of a loop, and a tempo for nameless files without full tempo detection).
- Folder conventions of big libraries ("Drum Hits", "Loops/Drums", "Construction Kits"), and sample-pack name prefixes ("XX_120_Am_Bass_Loop_01").
- Key words for one-shots ("bass C2" as root rather than key) and Apple Loops / AIFF `basc` flags.

## Slice stretch (`Sample::SliceStretch`, `stretch(r, mode: :slice)`)

ACID/REX-style: cut at the hits, start slice i at round(r × its start), copy it exactly.

- Slices: markers, else onsets (Sample::Onsets), else sixteenths at the sample's bpm; or `slices:` given.
- Slowing down: `fill: :gap` (default) plays the slice's own audio, fading out over `fade:` (4 ms) before its end, then silence until the next hit; `fill: :stretch` keeps 15 ms of attack and draws the rest out with the fitted cyclic stretch (falls back to a gap for slices shorter than the attack plus two cycles).
- Speeding up: each slice is cut at the next one's new time with the same fade.
- Pre-rolls: a slice that doesn't follow on from the one before (as in the input) gets the input's last `fade` samples before its hit faded in ahead of it, crossfading with the outgoing fade, so the attack is exact and joins what led into it (no step out of silence).  The first slice's pre-roll comes from the loop's end, at the output's end, so seamless loops stay seamless.
- Ratio 1 gives the input back exactly.  Reversed samples stretch in play order.  Pure Ruby + Numo; a two-bar 909 loop takes 3-13 ms (`:gap`), 5-90 ms (`:stretch`).

## Tempo-following loops (`GraphNode::LoopPlayer`, `Sample#follow`)

- Round 3 (Bench verdicts 2026-10-16: drums 90 "slice (gap)", drums 128 slice, arp "follow, spectral"): `follow`'s default `stretch: :auto` picks by `Sample#material`: name words first (`MATERIAL_WORDS`: drum, kick, hat, perc, break, top... percussive; pad, arp, chord, keys, bass, vocal, pluck... tonal), else the energy-weighted spectral flatness (2048-sample Hann frames, 100 Hz-10 kHz): a 909 groove 0.12, an 808 groove 0.15; saw arps, pads, basses under 0.001, a filtered noise pad 0.019, an 808 kick alone 0.001 (pitched drums read tonal; the vocoder keeps their transients too).  `PERCUSSIVE_FLATNESS` 0.04 splits them: slice for percussive, spectral for tonal.  The choice and its reason are on each player (`LoopPlayer#stretch_reason`, in its `to_s`); `stretch:` overrides.  Onset density was no use (a saw bass measured 12 onsets a beat from waveform ripple), nor a per-eighth energy crest (saw beating gave pads 3 dB).
- The arp's slice-follow "hesitation around 11.5 s" was a missed onset: the bar-2 downbeat (A3 after D4, a lower note under a held envelope) rose less than #onsets' 9 dB, so one slice held two notes; sped up to 128 BPM it played the first at its old length and the second 68 ms late, cut short (measured at 11.543 s and again at 15.293 s, one loop later).  The slice stretch now also cuts at softer rises (4 dB) within 15 ms of a sixteenth when the sample has a tempo (`Sample#slice_onsets`); the fixed render has every onset after the change on the eighth grid within 5 ms.

- A TimelineNode: its position comes from the timeline (Rational whole notes, advanced by the transport's tempo each buffer), the loop's beats spanning `beats / meter[1]` whole notes; `align: :timeline` (bar 1, like looping clips) or `:launch`.  Silent while the timeline is paused; never ends.
- `:stretch` (default): the sample stretched to the current tempo (for the tempo rounded to 1/4 BPM, so ramps reuse stretches and whole, half, and quarter tempos are exact; up to 24 kept per player, and Sample's edit cache shares them between channels and players), read at index floor(phase × n): at the stretch's own tempo the output is the stretched audio sample for sample.  A new tempo's stretch is made on the render thread the first time it plays (slice stretch: milliseconds; spectral: call `#prepare(bpms)` ahead).
- `:resample`: Catmull-Rom reads of the original at the phase (pitch follows; no band-limiting).
- Same output at any buffer size.  A plan boundary.  Stereo samples give a Channels bundle of one player per channel.

## Not yet

AIFF loop chunks (`basc`/Apple Loops, `INST`/`MARK`), REX files, ACID `strc`, stretching in a background thread with a fallback, band-limited resample reads, a live "follow the detected tempo" for captured audio.

Clocks (time-automation, 2026-10-18): `loop.clocked(19.7.seconds, fit: :stretch | :resample)` / `sample.follow(mode, clock: :tide)` play a LoopPlayer on a clock instead of the session tempo (one loop per period on period clocks, no tempo needed; beats at the clock's tempo otherwise), phase from session run frames, per-sample phases from each 800-frame cell's exact base (identical at any buffer size); `:stretch` restretches past `LoopPlayer::CLOCK_STEP` (1/2000) of length change, `:resample` bends pitch with a speed knob.  See arrangement.md "Clocks".

