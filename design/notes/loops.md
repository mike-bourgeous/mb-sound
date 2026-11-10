# Loop files, slice stretch, tempo-following loops

<!-- summary -->
`Sample['loop.wav']` reads loop metadata without ffmpeg's help (`Sample::Riff`: ACID tempo/beats/meter/root/one-shot, ACID stretch markers (`strc`) or cue labels as `sample.markers`, `smpl` loops), then FLAC tags, then tempo and key words in names (`Sample::LoopInfo`, reasons in `meta[:why]`), or detects tempo and key (`detect: true`; `#detect_key`, `Analysis::Key`).  `stretch(r, mode: :slice)` (`Sample::SliceStretch`) moves slices (markers, else onsets) to scaled times with exact attacks; `sample.follow` (`GraphNode::LoopPlayer`, a TimelineNode and plan boundary) plays a loop in time with the session tempo (slices for percussive loops, spectral for tonal ones, ACID one-shots as recorded).  Console `loops(dir, bpm:, key:, beats:, detect:)` lists a folder from headers and names only (keys match enharmonically).  Help `help :loops`.
<!-- /summary -->

## Quick reference

- `Sample['loop.wav']` reads ACID/`smpl`/cue metadata, tags, and names (`sample.meta[:why]`); `detect: true` or `#detect_key` measures; `stretch(r, mode: :slice)`; `sample.follow` plays in time with the session tempo.
- Console `loops(dir, bpm:, key:, beats:, detect:)`; help `help :loops`.
- ACID loop info (below): `sample.markers` are ACID's stretch markers when the file has them (`meta_source[:markers] == :strc`; the chunk itself: `Sample::Riff.read(path).strc`); ACID one-shots `follow` as recorded (`stretch: :none`); `stretch(r, mode: :spectral, transients: :markers)` or `transients: [positions]`; spec `spec/lib/mb/sound/sample_acid_spec.rb`.

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
brk.markers                                    # ACID's stretch markers (the slice points), else cue points
bg :pad, pad.follow(stretch: { mode: :spectral, transients: :markers })   # the vocoder, attacks at the markers
bg :hit, shot.with(bpm: 120).follow            # an ACID one-shot: as recorded from each loop start (stretch: :none)
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
- `strc` (ACID's stretch markers; no public description of its layout could be found, so it was worked out from loop files, "ACID loop info" below): a 28-byte header (uint32 28, uint32 entry count, five uint32 settings: the third the stretching method, 1 looping and 2 non-looping segments, the fifth the stretch spacing as a note division, 3 eighths and 4 sixteenths), then 32-byte entries: uint32 flags (0x01 disabled, 0x02 automatic), uint32 unused, uint64 sample position (frames at the file's rate), uint64 pin, uint32 value, uint32 unused.

Robustness: odd chunk sizes with or without the pad byte (an unpadded chunk is recognized by a chunk id starting right after it and none a byte later), RF64/BW64 (`ds64` data size), WAVE_FORMAT_EXTENSIBLE (subformat from the GUID), unknown chunks, truncated files (data size clamped to the file), chunks over `MAX_CHUNK` (4 MB) skipped, counts clamped to their chunk, at most 10000 chunks.  `Riff.write` makes fixtures (specs write theirs at run time; no third-party loops in the repo).

## Metadata (`Sample::LoopInfo`, `Sample` attributes)

Order: our own tags (`Sample#save`) > ACID/smpl/cue chunks (WAV, and FLAC APPLICATION `riff` blocks from `flac --keep-foreign-metadata`) > tags (FLAC Vorbis comments BPM/TBPM/TEMPO, KEY/INITIALKEY; ffmpeg metadata) > names (file, then up to 3 folders) > detection, only when asked.  Explicit options win over all.

- Names: "98bpm", "98 BPM", "bpm140", a bare 60-200 number only when no "bpm" word appears and only one such number; keys as capitalized words (Am, F#m, Ebmaj7, C#min, "F minor"), a lone letter only next to a tempo ("Loop A 90").
- `beats`: the file's count (ACID) while the region is the whole file, else tempo × length (whole within 2%, else a Float).  `bars` = beats / meter numerator.  ACID one-shots keep no tempo.
- ACID root (when the root-set flag is on) sets `root`; `smpl` sets the root (unity note minus pitch fraction) and the loop; an ACID loop without a `smpl` loop loops the whole file (`:forward`).  Positions scale from the file's rate to 48 kHz.
- `markers`: `Sample::Marker(position, label)`, play-order positions from the region start; views keep them, edits scale them.  ACID's stretch markers (`strc`, labels nil, `meta_source[:markers] == :strc`) when the file has them, else its cue points (`:cue`); the cue points are always in `meta[:cues]`.
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

- Slices: markers (ACID's stretch markers, else cue points), else onsets (Sample::Onsets), else sixteenths at the sample's bpm; or `slices:` given.
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

## ACID loop info drives `follow` and `stretch` (acid-loop-info-1, 2026-11-10; held for the maintainer's Bench verdict)

The maintainer's decision (2026-11-10): "ACID loop info drives `follow`.  The WAV `acid` chunk's one-shot flag means no stretch.  Parse the `strc` chunk [...] into markers, so `follow` / `stretch` on any ACIDized loop gets ACID's slice points, not only inside the converter."  It changes what ACIDized loops do by default, so it waits for a Bench A/B.

- **Stretch markers are the markers.**  `Sample::Riff::Strc` (`Riff.read(path).strc`: `count`, `settings`, `entries` of `StrcEntry(flags, position, pin, value)`, `lists`, `markers`, `stretch_method`, `spacing`, `forced(frames, beats)`) reads the chunk; `LoopInfo` makes its markers the file's `markers` (`sources[:markers] == :strc`, `why[:markers]`: "strc: 17 stretch markers (5 forced divisions)"), scaled to the Sample's rate like every position.  They outrank cue points: in the 46 library files with both, the cue points are bar regions with labels or the first and last frame, not slice points (they stay in `Entry#cues` and `sample.meta[:cues]`).  So `stretch(r, mode: :slice)` and `follow`'s slice stretch cut at ACID's markers by default, as they already did at cue markers (`slices:` given still wins), and `LoopPlayer#stretch_reason` says so ("slice: name 'drum', at 31 ACID markers").
- **One-shots play as recorded.**  `follow`'s `stretch: :auto` picks `:none` for a Sample whose file has the `acid` chunk's one-shot flag (`meta[:one_shot] == true` and `meta_source[:one_shot] == :acid`; "none: an ACID one-shot (the acid chunk's flag) plays as recorded").  `stretch(r, mode: :none)` (aliases `:unstretched`, `:as_recorded`) is the building block, an edit like the other modes: the sample at its own speed in `r` times its length, zeros after it when longer, a 4 ms fade-out (`fade:`) at the cut when shorter; the LoopPlayer reads it like any stretch, so the hit starts again at every loop start.  Like every stretch it is read at floor(phase × length): sample for sample when the loop lasts a whole number of samples, else one sample is repeated or dropped per pass (a 15967.2-sample loop period played a real one-shot one sample late after its first sample).  On clocks its ratio is exact (other modes round to `CLOCK_STEP`, which would drop or repeat a sample every few thousand).  ACID one-shots keep no tempo, so `follow` still needs a length: `shot.with(bpm: 120)` or `shot.clocked(2.seconds)`.  `follow(stretch: :slice)`, `follow(:resample)`, and `stretch(...)` called directly do what they are asked.  One-shots by name, length, or decay (LoopInfo's other rules) are not covered by the decision and follow by their material as before.  `Sample#save` keeps the flag (the tag `mb_sample_acid_one_shot`), so a graph document that bundles the sample as a FLAC file plays it the same (a bundle round trip lost it before the tag: the loaded graph stretched the hit in slices).
- **`transients:` takes positions.**  `stretch(r, mode: :spectral | :paul, transients:)`: `true` (`:onsets`) detects as before; `:markers` takes the sample's markers (detected onsets when it has none past its start); an Array of positions as `slices:` takes them (samples, seconds, Lengths, Durations, Markers; play order) or a `Slices`; `false` (or `[]`) none.  `Spectral.vocoder`'s `onsets:` did the work already.  Reversed samples map positions to stored order.  `slices:` takes Markers in its lists too.
- **Tonal loops keep the plain spectral stretch** under `follow` (the listening study decides whether marker-guided spectral becomes a default); it is one option away: `follow(stretch: { mode: :spectral, transients: :markers })`.

The `strc` chunk, as read (`Sample::Riff::Strc`; 18058 WAV files of the maintainer's loop library, 13385 with the chunk, and the stretch markers his ACID projects hold for the same files):

- Verified (864 projects, 1641 takes with stretch markers for a library file that has the chunk): the header is 28 bytes and says so; entries are 32 bytes to the end of the chunk (one ACID generation leaves 8 zero bytes after them); the uint64 at +8 is the marker's sample position at the file's own rate (48 kHz files fit their own rate, not 44.1 kHz): 84% of the 83333 markers read are the source sample of a marker in the projects (projects move and drop markers by their own settings; 825 of the 1641 lists are the same marker for marker), and the audio's high-frequency energy rises by more than 6 dB at 36% of 13482 markers in 400 loops of 19 packs against 2% of the points halfway between markers (52% against 1% in the older one-list files; the rest are grid divisions in held sound); flag 0x01 markers are disabled (1 of 1318 is among the projects' markers); the header's stretching method and spacing match the projects' settings for the same files (1572 of 1609 and 514 of 521 takes).
- Likely: a pin (+16) that differs from its position is the marker's time on the grid, in frames (the projects pin 543 of 1734 such markers at that time; where a marker was moved, the audio rises at +8 and not at +16: a median 3 to 6 dB against 0.5 dB over 7479 moved markers).
- Against `Sample#onsets` on 28 loops of 15 packs (every chunk generation, 44.1 and 48 kHz): all marker lists rising and inside the file; 26% of 837 markers within 10 ms of a detected onset and 38% of 560 onsets within 10 ms of a marker (percussive loops agree hit for hit, 8 of 9 and 11 of 15 markers; tonal loops have markers on the sixteenth grid where the detector finds nothing, or ripple onsets between markers).  So markers and detected onsets are different slice points: what the Bench A/B is for.
- The chunk holds several lists one after the other, each sorted by position (a new list starts where the position goes down): in newer files the detected transients with float32 strengths ("hints": flags 2, pin 0), copies of an automatic marker list (flags 2, pin 0, value 0), then the stretch markers with pins.  Assumed: the markers are the last list that isn't hints; when that list holds only hand-set markers (no flag 0x02 entry), the automatic ones are in the list before it (the two together gave a whole grid wherever looked at).
- The header's count is taken as the end of what its writer described: the oldest files (settings all zero) often carry more entries after the counted ones (1400 files), appended by a later ACID version without changing the count; in a sample of 40 projects their markers agreed with the counted list more often (the same list in 4 of 8 and 3 of 4 files of two such shapes, against 1 and 0 for the appended lists).
- Older files (one list; 39% of the chunks) hold only detected markers, a median of 2 a beat, and ACID adds its "force divisions at" grid when playing; newer files have the divisions in the list (a median of 3.9 a beat).  `Strc#forced` adds the spacing grid for one-list files where no marker is within a quarter of a division (ACID keeps a division unless a marker is within about 2 ms, which would give slices of a few ms), for loops with ACID's beat count; 3378 library files get some.  Without them 724 of 5231 such files had under one marker a beat.
- Chunks made for other audio: 265 files have markers past their end (copies at half or a quarter of the rate, or rendered at another tempo, that kept the original's chunks); their markers are left out (`why[:markers]` says so).  A marker on the last frame is dropped.
- Not decoded: the header's other settings (65/5 and 25/10 pairs, a percentage), the 16.16 fraction one generation keeps per marker, the first marker's pin in the oldest files (the audio's first hit, a few ms in).  Not used yet: pins (ACID plays a moved marker's audio at its pinned time, so slices could be placed by pin instead of by `r` times their start), hint strengths, the stretching method.

## Not yet

AIFF loop chunks (`basc`/Apple Loops, `INST`/`MARK`), REX files, ACID `strc` pins and stretching method (above), stretching in a background thread with a fallback, band-limited resample reads, a live "follow the detected tempo" for captured audio.

Clocks (time-automation, 2026-10-18): `loop.clocked(19.7.seconds, fit: :stretch | :resample)` / `sample.follow(mode, clock: :tide)` play a LoopPlayer on a clock instead of the session tempo (one loop per period on period clocks, no tempo needed; beats at the clock's tempo otherwise), phase from session run frames, per-sample phases from each 800-frame cell's exact base (identical at any buffer size); `:stretch` restretches past `LoopPlayer::CLOCK_STEP` (1/2000) of length change, `:resample` bends pitch with a speed knob.  See arrangement.md "Clocks".

