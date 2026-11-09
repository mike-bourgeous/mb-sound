# Phaser

<!-- summary -->
`sig.phaser(:vintage | :swirl | :ripple | :deep12 | :jet | rate, depth:, stages:, feedback:, mix:, center:, range:, spread:, shape:, sweep:)` (`GraphNode::Phaser`, kernel `FastFilter.phaser` with an exact Ruby mirror) is a chain of 2-12 first-order allpass stages at one LFO-swept frequency, feedback around the chain solved in closed form, a linear dry/wet mix, Tone LFOs (sine or triangle, Hz or tempo-synced lengths), and stereo pairs whose right LFO runs `spread:` cycles ahead.
<!-- /summary -->

## Quick reference

- `sig.phaser` (the :vintage preset), `sig.phaser(:jet)`, `sig.phaser(1.bar, stages: 8, feedback: 0.6)`, `sig.phaser(:swirl, range: 200..6000)`, `sig.phaser(sweep: env * 2 - 1)`; presets `L.fx.phaser` (`Phaser.preset_names`).
- Code `lib/mb/sound/graph_node/phaser.rb` (node, presets, build) and `phaser_methods.rb` (the DSL method); kernel `ruby_phaser` in `ext/mb/sound/fast_filter/fast_filter.c`; spec `spec/lib/mb/sound/graph_node/phaser_spec.rb`; help `help :effects`.
- Analysis helpers: `Phaser.notch_frequencies(stages, fc)`, `Phaser.response(freqs, stages:, frequency:, feedback:, dry:, wet:)`.

The summary block above feeds the generated index (`design/notes/README.md`, `rake docs:index`).  Update it when behavior changes.

## Design (phaser-1, 2026-11-09)

The maintainer's request (2026-11-08): no phaser in the library, though the pieces existed (`filter(:allpass, cutoff: node)` with an LFO; fit_patch once built one ad hoc); a dedicated GraphNode with Params, `phaser(rate, depth:, stages:, feedback:, mix:, spread:, center:, range:)`, tempo-synced rates, even stages 2-12, signed feedback with a resonance limit, a mix, Blue Cat-style stereo spread, sweep center and range, and knobs onto which the plug-ins in his old ACID projects map (BluePhaser on a hi-hat, Blue Cat Phaser stereo and mono, VdPhazor, BassPhaserV10, an eFX Phaser).

- **Stages.**  Each stage is the topology-preserving (trapezoidal) one-pole allpass, H(s) = (wc - s) / (wc + s): v = (u - s) G, lp = v + s, s' = lp + v, y = 2 lp - u, with g = tan(pi fc / rate) from `mb_tan_pade` (only + - * /, so C and Ruby agree exactly) and G = g / (1 + g).  All stages share one frequency, as in the classic pedals (MXR Phase 90, Small Stone), so notches of N stages at fc sit where the chain's phase is an odd multiple of -180 degrees: tan(pi f / rate) = tan(pi fc / rate) tan((2k + 1) pi / (2N)), k = 0 ... N/2 - 1 (four stages: 0.414 fc and 2.414 fc; exact for the prewarped bilinear stages, spec'd within a 2.9 Hz bin from the rendered impulse response, which matches `Phaser.response` within 0.01 dB wherever the response is above -40 dB).  `filter(:allpass)` is the library's second-order SVF allpass; first-order stages give the classic unequal notch spacing and half the notches per stage pair, so the kernel has its own.  Odd stage counts raise (a lone stage leaves a tilt rather than a notch pair).
- **Feedback** goes from the chain's output to its input with no unit delay: each stage is linear in its input (y = (2G - 1) u + 2 (1 - G) s), so the chain is Y = A u + B and u = x + k Y solves to u = (x + k B) / (1 - k A) (zero-delay feedback, Zavalishin; the four-pole's method).  The closed loop is dry + wet H / (1 - k H): positive k peaks where H = 1 (the chain's phase a whole number of turns), negative k where H = -1, at 1 / (1 - |k|) over the wet level (spec'd; the rendered response matches the analysis within 0.02 dB at k = 0.7, -0.7, 0.95).  |k| is limited to 0.95 (+26 dB peaks): numbers past it raise, nodes are clamped in the kernel (NaN reads as 0).  A unit-delay loop would move the peaks off the analysis as the frequency rises; the closed form costs N multiply-adds per sample.  Stability: with |H| = 1 the static loop is stable for |k| < 1; a 30 Hz, 10-octave sweep of noise at k = 0.95 through 12 stages stays bounded (peak under 30 over 3 s, not growing; spec'd).  No level compensation for feedback (the pedals have none): on the Bench sources :jet measured +3.4 LU over the dry 909 beat (-10.3 vs -13.7 LUFS; :vintage -15.1, its notches take energy out), -0.1 LU on the saw pad (:vintage -2.6), and -0.7 LU on the hats.
- **Sweep**: the stages' frequency is center * 2 ** (range / 2 * depth * sweep), computed in the kernel per sample (exp; coefficients only when it changes) and clamped to 1 Hz .. 0.49 rate.  `center:` is Hz (a Pitch or node too), `range:` octaves at depth 1 (a node too) or a Range of frequencies for the sweep's ends (`200..5000`: center their geometric mean, range log2(hi / lo); with `center:` it raises), `depth:` 0..1 the share swept (the knob plug-ins call depth or sweep).  Octaves rather than Hz because phasers sweep geometrically and the plug-ins' min/max frequency pairs map onto a Range directly.
- **LFO**: a Tone LFO (`.lfo.sine` / `.lfo.triangle`, `with_phase(phase)`) feeding the node's sweep input, so tempo sync is the existing machinery: `1.bar`, `2.bars`, `1.n4`, `knob(:len).bars` follow the tempo and lock to the timeline (`Sequence::Duration#lfo`); numbers and Pitches are Hz, a Length (`4.seconds`) is a period, a node is Hz.  `sweep:` replaces the LFO with any node of -1..1 (an envelope follower, a knob, a sample-and-hold) on both sides (with `spread:` it raises).
- **Stereo**: a mono input without spread gives one Phaser node; with `spread:` (cycles, 0.5 opposite) or a stereo input, two nodes, the right LFO started `spread` cycles ahead (exactly a left phaser with `phase: spread`, spec'd), returned as a Channels bundle (`ChannelDispatch::EXCLUDED`: the method handles bundles itself).
- **Mix**: linear, dry gain (1 - mix) dry, wet gain mix wet (`BlendMethods.gains(mix, :linear)`), default 0.5: the dry and wet are the same signal phase-shifted, so equal parts give full notches with peaks at 0 dB.  The delays' equal-power law (dry sqrt(1 - mix)) would put the same notches under +3 dB peaks; linear is the usual phaser law (question 3 in the phaser-1 report).  `dry:`/`wet:` are levels (Decibels, numbers, nodes) the mix multiplies; a negative wet inverts the wet polarity (Blue Cat's wet phase), turning notches into peaks.
- **Kernel and plans**: `FastFilter.phaser(out, x, sweep, center, range, depth, feedback, dry, wet, state, rate)` in fast_filter (no new source or header, so the memcheck map's structure is unchanged), exact Ruby mirror `Phaser.process_ruby` (`Kernels.register :phaser`).  The state is one double per stage plus the flush grid count (`MB_FLUSH_GRID`, 800 samples of the node's own time), so output is bit-identical at any buffer size (spec'd at 1/7/128/33 vs 800).  A plan boundary: one C call per buffer whose work dwarfs the call; fusing would need a fast_plan op and a lane-major op for a node that rarely sits inside a voice.  `node_traits memory: :short, carry: :adopt` (a rebuild with the same stage count keeps the stages' state).

Measured (Mac container, i9-9880H, 800-sample buffers, a moving sweep, ns per sample per channel, % of realtime at 48 kHz): kernel 43 / 71 / 98 ns at 4 / 8 / 12 stages (0.20 / 0.34 / 0.47%); the whole node with its Tone LFO about 48 / 77 / 107 ns (0.23 / 0.37 / 0.51%); the Ruby mirror 907 / 1231 / 1976 ns with YJIT (4.4 / 5.9 / 9.5%), 2042 / 2853 / 3686 without, so the C kernel was worth it.

## Presets (`L.fx.phaser`)

| preset | stages | rate | range | center | feedback | spread | shape | for |
|---|---|---|---|---|---|---|---|---|
| `:vintage` (default) | 4 | 0.5 Hz | 4 oct (175-2800 Hz) | 700 | 0 | 0 | sine | a four-stage pedal |
| `:swirl` | 6 | 0.12 Hz | 6 oct | 900 | 0.3 | 0.25 | triangle | slow wide stereo pads |
| `:ripple` | 4 | 4 Hz | 1 oct | 1200 | 0.2 | 0 | sine | fast shallow shimmer |
| `:deep12` | 12 | 0.2 Hz | 5 oct | 800 | 0.4 | 0.5 | sine | deep, six notches |
| `:jet` | 8 | 0.08 Hz | 6 oct | 1000 | 0.85 | 0 | triangle | resonant jet on drums |

Names are open questions (`:classic` collided with a library tag, so the default is `:vintage`).  Bench set: `/app/tmp/listening/phaser-1/` (presets on a drum loop, a pad, a hi-hat pattern, loudness-matched).

## Mapping plug-in controls (for the .acd converter)

The plug-ins' states don't decode yet and their references (his next Windows run: each at his settings on an impulse, drums, and a level-stepped sine) aren't in, so this is the intended mapping, to be checked against those renders.

| plug-in control | phaser option | notes |
|---|---|---|
| Rate (Hz) / tempo sync | `rate` (Hz, or `1.bar`, `1.n4`) | Blue Cat: Hz |
| Depth (%) | `depth` (0..1) | Blue Cat "amount of delay variation around the average"; maybe range rather than depth if its center is fixed: fit from the impulse renders |
| Feedback (%, signed) | `feedback` (-0.95..0.95) | Blue Cat allows +-100% (it warns of runaway); scale x 0.95 or clamp, decided from the renders |
| Stages / Order | `stages` (2-12 even) | Blue Cat up to 32: raise the limit if his settings go past 12 (question) |
| Center / Manual / Frequency | `center` (Hz) | |
| Min / Max frequency | `range: lo..hi` | sets center too |
| Sweep width (octaves) | `range` | |
| Stereo / Spread / LFO phase (%, degrees) | `spread` (cycles) | Blue Cat Spread %: probably % of a half cycle (0.5 cycles at 100%): check |
| Dry, Wet (%) | `dry:`, `wet:` levels | a negative wet for Blue Cat's wet phase invert |
| Mix (%) | `mix` | linear |
| LFO shape (sine/triangle) | `shape` | |
| Gain (dB) | `.at(gain)` before the phaser | |
| BassPhaser-style low split | not built: `bands(f) { |lo, hi| [lo, hi.phaser] }` keeps the bass dry | |
| Envelope-follower sweep | `sweep:` a follower node | |
