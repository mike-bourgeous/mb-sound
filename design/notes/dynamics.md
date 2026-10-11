# Dynamics (compressor, compander, ducking, limiter, multiband)

Branch dynamics-1 (2026-10-11).  CLAUDE.md keeps a summary and points here.  Update both when behavior changes.

Maintainer's asks: a limiter for the master chain (oscillators are full scale, the master bus is -10 dB), lookahead brickwall and true-peak aware, plus a clipper-style option; a classic feed-forward compressor with a sidechain input as a node; tech house ducking ("bass needs to be louder"); multiband OTT-style upward + downward compression on Linkwitz-Riley crossovers; an arbitrary piecewise compander (2026-10-11), with monotone cubic segments.

## Survey (from memory; marked where unverified)

- Giannoulis, Massberg, Reiss, "Digital Dynamic Range Compressor Design: A Tutorial and Analysis" (JAES 60(6), 2012).  The recommended structure: level detection in dB (`x_L = 20 log10 |x|`), a static gain computer with a quadratic soft knee (below `T - W/2` unity, inside the knee `y = x + (1/R - 1)(x - T + W/2)^2 / (2W)`, above `T + W/2` `y = T + (x - T)/R`), then the gain (`y - x_L`) smoothed in the log domain with a branching one-pole (attack coefficient when the gain falls, release when it rises), then makeup.  They compare detector placements (smoothing the level before the gain computer vs the gain after it; the log-domain gain smoother avoids the release-dependent "attack lag" of linear-domain detectors and keeps the knee exact).  Their "smooth decoupled" peak detector adds a release stage inside the attack stage; I recalled but did not reverify its exact equations, so the branching smoother is what's built.  The quadratic knee formula above is verified by its own properties in the specs (continuous value and slope at both knee edges).
- True-peak limiting: BS.1770-4 Annex 2's 4x polyphase interpolator (12 taps per phase) estimates inter-sample peaks; `fast_loudness` and `Loudness::TruePeak::PHASES` already have it.  Commercial true-peak limiters oversample the gain detection (and sometimes the gain application); the latency of the interpolator (about 6 samples here) adds to the lookahead.
- Lookahead brickwall (common design, e.g. in open-source limiters such as Signalsmith's write-up; unverified details): required gain per sample `min(1, ceiling / |x|)`, a sliding minimum over the lookahead window, an instant-attack release smoother, then a moving average over the same window, with the audio delayed so the average has reached the peak's required gain when the peak arrives.  Because every value averaged is at most the peak's required gain, the output never exceeds the ceiling (up to float rounding; a final clamp catches that).
- Linkwitz-Riley crossovers: LR(2n) is a Butterworth-n lowpass squared and highpass squared; since `B_n(s) B_n(-s) = 1 + (-1)^n s^(2n)`, low + high is the allpass `B_n(-s)/B_n(s)` (LR2 needs the high band inverted).  Multi-band trees stay flat when each lower band also passes the higher crossovers' allpasses.  TPT SVFs keep these identities exactly in the digital domain (same bilinear mapping for every branch).
- OTT (Xfer, free; descended from Ableton's "OTT" multiband preset): three bands (crossovers about 88 Hz and 2.5 kHz, unverified), each with downward compression at a very high ratio (about 66:1, unverified) above a threshold and upward compression (about 4:1, unverified) below a lower one, per-band output gains, `depth` as a parallel mix, `time` scaling attack/release.  Built here from the same pieces, with values chosen by ear and measured, not copied.

## Design

One gain-computer core, several faces (`lib/mb/sound/graph_node/dynamics.rb`, kernel `ext/mb/sound/fast_dynamics`, exact mirror `Dynamics.process_ruby`):

1. **Detector**: `:peak` (|x| per sample) or `:rms` (one-pole mean square over `rms:` time, default 10 ms), in dB with a floor of -200 dB.  Linked (default): one detector for all channels, driven by the loudest channel each sample (max of |x| or of x^2); `link: false` gives each channel its own.  The detector reads the `sidechain:` (any node or bundle; one sidechain channel drives every channel) instead of the input when given.
2. **Gain computer**: a transfer curve, input level dB → output level dB, as segments `[x0, y0, b, c, d]` (`y = y0 + b dx + c dx^2 + d dx^3`, dx = x - x0) found by binary search; the first and last segments are linear, so the curve continues its end slopes.  Every face builds its segments in Ruby: the compressor's quadratic knee exactly, upward compression and expansion as extra linear segments, the compander's points linearly, as monotone cubics (Fritsch-Carlson / PCHIP slopes, never overshooting), or with a Curve shape per segment (sampled at 32 points and joined by monotone cubics), and a block form sampled every dB.  The gain is `y - x_L`, clamped to `range` (lowest, for gates and expanders) and `max_gain` (highest, for upward compression and the compander).
3. **Smoothing**: the gain in dB through a branching one-pole: `down` time while the gain falls, `up` time while it rises (compressors and ducks: attack = down, release = up; gates: attack = up, release = down), plus an optional `hold:` that delays the slow direction.  Per-sample recursion with state carried across buffers, so output is identical at any buffer size.  Times take seconds, Lengths, Durations (follow the tempo; `release: 1.n8` for a duck), or nodes; the kernel recomputes a coefficient only when its time changes.
4. **Lookahead**: the audio is delayed by `lookahead:` (whole samples) while the detector reads it undelayed (compressor: anticipates attacks; the limiter's own algorithm below).
5. **Makeup**: dB number, or `:auto` (half the curve's gain at 0 dBFS back, a heuristic).

**Units**: levels (`threshold:`, `ceiling:`, `amount:`, `range:`) accept dB numbers (`-12`) or linear gains (`-12.db`, which is 0.251): numbers above 0 are linear gains, 0 and below are dB (so `0` and `0.db` agree).  `makeup:` and compander points are dB numbers only.  Times as in numbers_lengths_phases.md.

**Limiter** (`limit`, its own kernel in the same extension, mirror `Dynamics::Limiter.process_ruby`): detector level per sample (with `true_peak: true`, the max of the sample and the Annex 2 interpolated values on both sides of it, which delays the detector by 6 samples), required gain `min(1, ceiling/level)`, a sliding minimum over `lookahead + 1` samples, an instant-attack release one-pole, a moving average over `lookahead + 1` samples, then the delayed audio times the gain, clamped to the ceiling.  Linked across channels by default.  Latency: `lookahead` samples, plus 6 with `true_peak`.

**Multiband**: `bands(f1, f2, ..., order: 4) { |low, mid, high| ... }` splits with an LR crossover tree (C kernel, mirror), yields one node (or bundle, for multichannel input) per band, and sums what the block returns.  Any node works per band.  `ott(...)` builds on it.

**Channels**: every face takes a single node or a bundle and handles channels itself (excluded from ChannelDispatch, like `reverb`), returning a node for one channel, a bundle otherwise.

**Plan layer**: boundary for now (the nodes are not Describable).  A later `Op::Dynamics` could run the same kernel (the state is already per node in one DFloat).

**CPU budget**: the master chain at 800-sample stereo buffers should stay well under 1% of realtime per compressor or limiter (one log10 and one pow per sample per detector; the limiter's window loops are O(lookahead) per sample, ~72 compares and adds at 1.5 ms), and an OTT under about 3%.  Measurements below.

## Measurements

(filled in as built)
