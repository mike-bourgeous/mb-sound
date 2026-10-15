# Loop files, slice stretch, tempo-following loops

CLAUDE.md keeps a summary and points here.  Update both when behavior changes.

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

## Slice stretch (`Sample::SliceStretch`, `stretch(r, mode: :slice)`)

ACID/REX-style: cut at the hits, start slice i at round(r × its start), copy it exactly.

- Slices: markers, else onsets (Sample::Onsets), else sixteenths at the sample's bpm; or `slices:` given.
- Slowing down: `fill: :gap` (default) plays the slice's own audio, fading out over `fade:` (4 ms) before its end, then silence until the next hit; `fill: :stretch` keeps 15 ms of attack and draws the rest out with the fitted cyclic stretch (falls back to a gap for slices shorter than the attack plus two cycles).
- Speeding up: each slice is cut at the next one's new time with the same fade.
- Pre-rolls: a slice that doesn't follow on from the one before (as in the input) gets the input's last `fade` samples before its hit faded in ahead of it, crossfading with the outgoing fade, so the attack is exact and joins what led into it (no step out of silence).  The first slice's pre-roll comes from the loop's end, at the output's end, so seamless loops stay seamless.
- Ratio 1 gives the input back exactly.  Reversed samples stretch in play order.  Pure Ruby + Numo; a two-bar 909 loop takes 3-13 ms (`:gap`), 5-90 ms (`:stretch`).

## Tempo-following loops (`GraphNode::LoopPlayer`, `Sample#follow`)

- A TimelineNode: its position comes from the timeline (Rational whole notes, advanced by the transport's tempo each buffer), the loop's beats spanning `beats / meter[1]` whole notes; `align: :timeline` (bar 1, like looping clips) or `:launch`.  Silent while the timeline is paused; never ends.
- `:stretch` (default): the sample stretched to the current tempo (for the tempo rounded to 1/4 BPM, so ramps reuse stretches and whole, half, and quarter tempos are exact; up to 24 kept per player, and Sample's edit cache shares them between channels and players), read at index floor(phase × n): at the stretch's own tempo the output is the stretched audio sample for sample.  A new tempo's stretch is made on the render thread the first time it plays (slice stretch: milliseconds; spectral: call `#prepare(bpms)` ahead).
- `:resample`: Catmull-Rom reads of the original at the phase (pitch follows; no band-limiting).
- Same output at any buffer size.  A plan boundary.  Stereo samples give a Channels bundle of one player per channel.

## Not yet

AIFF loop chunks (`basc`/Apple Loops, `INST`/`MARK`), REX files, ACID `strc`, stretching in a background thread with a fallback, band-limited resample reads, a live "follow the detected tempo" for captured audio.
