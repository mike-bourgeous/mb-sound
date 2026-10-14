# Granular synthesis and spectral time-stretching

Branch `granular-1` (2026-10-14).  The maintainer picked "Granular + spectral stretch" from the Did You Know notes "Granular synthesis" and "The four families of time-stretching" (both "note for later" until then).  Builds on the sampler (`sampler.md`: `Sample`, its band-limited playback levels, `fast_sampler`) and the cyclic `Sample#stretch` (`fit: :auto`).

## API

```ruby
bowl = Sample['bowl.flac']
bg :drone, bowl.grains(position: 0.42, size: 120.ms, density: 30, spread: 0.02, pan_spread: 0.8)   # frozen
bg :rain,  rain.grains(scan: 0.25, size: 60.ms, density: 80, pitch_spread: 3, reverse: 0.3)         # a 4x slower cloud
bg :scrub, pad.grains(position: tween([0, 1], 8.bars), size: 80.ms)                                  # scrubbing
bg :shimmer, pad.grains(pitch: [0, 12, 19], pitch_spread: 0.1, window: :expodec)                    # pitch spray
synth(midi) { |v| v.grains(pad, density: 40, size: 70.ms) * v.env(0.2, 0.3, 0.8, 1.2) }             # key-tracked voices
pad.grains(read: :drop)                                                                               # lofi drop-sample reads

pad.stretch(8, mode: :spectral)        # phase vocoder, identity phase locking, transients kept crisp
pad.stretch(32, mode: :paul)           # Paulstretch: big windows, random phases (seeded)
pad.stretch(2)                         # the cyclic S950 stretch (mode: :cyclic, fit: :auto) stays the default
```

## Granular node (`GraphNode::Grains`)

- `Sample#grains(**options)` returns a stereo `Channels` bundle of a `GraphNode::Grains` (MultiOutput, two outputs; alternates two sets of output buffers like ChannelMixer, so a Tee may share the last frame's).  `Notes#grains(sample, **options)` (`v.grains`) adds the voice's `freq:` (key tracking: each grain's speed times freq / the sample's root frequency) and `trigger:` (a note-on restarts the scan playhead and starts a grain on its exact sample).
- Every parameter is a number, Length/Interval where it fits, Knob, or node, read per sample; a grain reads the values on its onset sample and keeps them (the classic per-grain parameters):
  - `density:` grains per second (20; a Pitch or a node of Hz; a Duration (`1.n16`) is tempo-synced through its TempoNode frequency).
  - `jitter:` onset randomness, 0 (synchronous: a grain every 1/density, which buzzes at the density) to 1 (default: Poisson onsets, Roads' asynchronous cloud): each interval is 1/density × ((1 - j) + j × -ln(1 - u)), mean 1/density at any jitter.
  - `size:` grain length (100 ms; seconds, a Length, or a node of seconds), 2 samples to 10 s.
  - `position:` the grain center as a 0..1 fraction of the sample region in play order (a Length is converted; a node scrubs).  `position: 0.42` freezes.
  - `scan:` the playhead's speed relative to the sample's own (1 plays through in real time, 0.25 is a 4x granular stretch; a node), added to `position` and wrapping around the region.  Default: 1 when no `position:` is given (plain `rain.grains` plays the sample through, looping), else 0.
  - `spread:` ± random position offset (0..1 of the region, or a Length), clamped to the region.
  - `pitch:` semitones (an Interval, number, or node), or an Array of semitones to pick from at random per grain (`[0, 12, 19]`: octave and fifth spray); `pitch_spread:` ± random semitones.
  - `pan_spread:` 0 (center) to 1 (each grain anywhere from hard left to hard right): equal-power pans × sqrt(2) (center is unity on both sides, like Unison spread).  A stereo sample's grains read both channels and the pan acts as a balance.
  - `reverse:` the chance a grain plays backwards (0..1; true = 1).
  - `window:` `:hann` (default), `:triangle`, `:tukey` (half flat), `:gauss`, `:blackman`, `:rect` (64-sample edges), `:expodec` (sharp attack, exponential decay: Roads' percussive grains), `:rexpodec` (reversed); or a Proc of 0..1, or an Array of values.  Tabulated in Ruby (1024 + 1 points, linear interpolation, the same table in C and the mirror).
  - `normalize:` (true = `:power`) each grain's gain is 1 / sqrt(max(1, density × size × mean(window²))), so dense clouds of uncorrelated grains keep the sample's level and sparse grains play at full level.  Grains that line up into the original sound (scan 1, pitch 0, no spread: every grain reads the same source sample at each output sample) add up coherently instead (+11 dB at 400/s × 50 ms; measured): `normalize: :amplitude` divides by the windows' overlap (density × size × mean(window)) for that case; `false` turns it off.
  - `max_grains:` (32) the most grains sounding at once: an onset with no free slot is skipped (no stealing, no clicks), so the worst-case cost per sample is fixed.
  - `seed:` per-grain randomness from one splitmix64 state (`wt_noise_random`, mirror `Tone.noise_random`) seeded from `seed:` or `MB::Sound.next_seed`; every onset draws exactly six numbers (position, pitch choice, pitch jitter, pan, reverse, next interval) whatever the settings, so changing one parameter doesn't reshuffle the others.
  - `read:` `:clean`/`:drop` (or `interpolation:`/`mips:`) as for `Sample#read_as`; default the sample's own read (the lofi presets read drop-sample).
- Grain geometry: a grain of L output samples at speed s (2^(semitones/12) × source rate / output rate × key ratio) reads positions a + k·s (backwards: from a + (L-1)·s down to a); its center goes at the position and its start a is clamped so every read lies inside the region; a grain longer than the region is shortened to fit (never cut mid-window).  The window is read at k × 1024 / L.
- Kernel `FastSampler.grains` (`ext/mb/sound/fast_sampler/granular.c`, sharing fast_sampler's `-ffp-contract=off` build and `mb_wavetable.h`): onsets on exact samples from a per-sample accumulator (so the output is the same at any buffer size); each active grain is one `wt_value_dispatch` (two levels of the sample's band-limited table, selected by |s|) per channel, a window lookup, and two multiply-adds.  Exact Ruby mirror `Granular::KernelRuby.grains` (specs compare sample for sample).  State: a DFloat row per grain slot and a few globals (onset phase, interval scale, playhead), plus the UInt64 RNG.
- A plan boundary (`plan_unsupported_reason`).  Never ends (like oscillators) unless an input ends.
- Live audio: grains play Samples, so `capture_audio(4.bars)` (once done, `cap.sample`) and `bounce` results work.  A Clouds-style rolling live buffer (grains reading a ring that a node writes) is left for later: it needs a non-mipmapped read path.

## Spectral and Paulstretch modes (`Sample::Spectral`)

Offline edits like the cyclic stretch (baked into a new Sample, cached per audio and arguments; `Sample::EDITS`).  `Sample#stretch(ratio, mode: :cyclic | :spectral | :paul, ...)`; `:pv`/`:vocoder` alias `:spectral`, `:paulstretch` aliases `:paul`.

- `:spectral`: a phase vocoder (Hann windows of `window:` 4096 samples, `overlap:` 4, i.e. a fixed synthesis hop N/4 and analysis hops N/4 / ratio; FFTs through Numo::Pocketfft on copies) with Laroche & Dolson (1999) identity phase locking: peaks are bins above their two neighbours on each side; each peak's phase advances by its instantaneous frequency over the synthesis hop; every other bin keeps its analysis phase offset from the peak whose region it is in (regions split midway between peaks).  Channels are locked together: the phase rotation is computed on the channels' mix and applied to every channel, so the stereo image doesn't wander.  Transients (`transients: true`): onsets from `Sample::Onsets` get an unstretched span (from a hop before the onset to half a window after) mapped at ratio 1, the rest stretched more to keep the total length, and the phases reset to the analysis phases at the first frame holding the onset, so at ratio 1 the frames reconstruct the input there and attacks stay sharp instead of smearing over a window.  Output length round(ratio × length), aligned with the input's start (frames padded by half a window).
- `:paul`: Paulstretch (Nasca Paul): windows of `window:` 0.25 s, synthesis hop N/4, analysis hop N/4 / ratio, magnitudes kept and every phase replaced by a random one.  Random phases come from a counter-based splitmix64 hash of (seed, frame, bin) computed with Numo (vectorized, the same at any chunking), `seed:` 0 by default (stretching the same sample the same way gives the same audio, and the edit cache stays meaningful); all channels share the phases (the image keeps its level panning).  For extreme ratios (8x-1000x+).
- Realtime: both could run streaming (a frame per hop, latency one window), but they are offline for now (bounce-time edits, no per-voice CPU).

## As built and measured (granular-1, 2026-10-14)

- Onsets snap: an accumulated phase within 1e-9 of 1 starts a grain on that sample (100 grains per second at 48 kHz landed every 481st sample from rounding before).
- Reading one output alone (`grains[0]`) is fine; `.mono`/`.mixdown` for a mono cloud (the left output alone loses right-panned grains).
- Grain cost (AMD 7950X, min of 3 runs, `/tmp`-style bench of a 3 s noise sample; ns per output sample, both outputs): defaults (20/s × 100 ms, ~2 active) 105 / 59 ns at 128 / 800-sample buffers (0.50% / 0.29% of realtime); worst case, all 32 slots sounding: mono 624 / 583 ns (3.0% / 2.8%), stereo 1191 / 1137 ns (5.7% / 5.5%), stereo with node inputs 1308 / 1201 ns (6.3% / 5.8%), drop-sample reads 289 / 251 ns (1.4% / 1.2%), `:sinc` 5715 / 5883 ns (27-28%).  About 18 ns per grain per channel with `:optimal` reads.  So a synth with 8 stereo grain voices costs up to ~45% of realtime at the default cap; lower `max_grains:` for voices.
- Spectral stretch speed (2 s stereo chord): 4x 0.27 s (30x realtime of output), 32x 1.3 s (50x); Paulstretch 8x 0.17-0.23 s.  Instantaneous frequencies come from a second FFT N/8 before each frame (so quality doesn't depend on the ratio, and huge ratios with zero analysis hops work), except in unstretched (transient) frames, which use the real hop so they rebuild the input exactly.
- Transients: a noise burst stretched 4x rises (5% → 50% of its peak) in 2-6 samples with `transients: true`, ~2500 samples without.
- Paulstretch frames are random-phase, so they add in power: the overlap-add divides by sqrt(Σw² × mean(w²)) instead of Σw² (the plain normalization played 6 dB low).

## Round 2 (maintainer answers, 2026-10-14)

- Clouds keep 32 slots; `v.grains` (Notes#grains) defaults to `Granular::VOICE_MAX_GRAINS` = 16 per voice (`max_grains:` still overrides), so 8 stereo grain voices cost at most ~23% of realtime instead of ~45%.
- Stretch results longer than `Sample::LONG_STRETCH` (30 s) read with `mips: :octave` (about 8x the audio for levels instead of about 14x) unless the source sample has its own mips (an explicit `read_as(mips:)`, a drop read); voices' and grains' `mips:` options still win.
- Later follow-ups, not now: the Clouds-style live grain buffer, and an opt-in grain layer for the ambient genre.

## Not yet

Live rolling grain buffer; grains in plans; per-grain filters; spectral freeze as a node; the ambient genre's optional grain layer (not changing its default sound without the maintainer).
