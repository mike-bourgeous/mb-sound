# Modulation effects (flanger)

<!-- summary -->
`sig.flanger(:sweep | :jet | :sheen | :steel | :orbit | :tape_flange | rate, delay:, range:, depth:, feedback:, mix:, spread:, shape:, phase:, law:, through_zero:, sweep:)` (`GraphNode::Flanger`, library family `:flanger`) is a short delay swept by an LFO with signed feedback, built from `#delay`'s node-time DelayLine and feedback loop (no delay engine of its own); settings share names and meanings with `phaser` (rate in Hz or bars, linear mix, spread in cycles); same output at any buffer size.
<!-- /summary -->

## Quick reference

- `sig.flanger` (`:sweep`), `sig.flanger(:jet)`, `sig.flanger(2.bars, feedback: -0.7, spread: 0.25)`, `sig.flanger(:steel, range: 0.3.ms..3.ms)`, `sig.flanger(sweep: env * 2 - 1)`; presets `L.fx.flanger`.
- Code `lib/mb/sound/graph_node/flanger.rb` (`Flanger.build`), `flanger_methods.rb`, the shared LFO `modulation_lfo.rb` (`ModulationLfo.tone`); spec `spec/lib/mb/sound/graph_node/flanger_spec.rb`; help `help :effects`.

Built in effects-2 (2026-11-09; the maintainer's "Add effects to the plan including phaser, if time permits", the overnight plan in the workbench's `briefs/overnight-2026-11-08.md`, brief `briefs/effects-2.md`).  phaser-1 built `phaser` in parallel; the two share their settings' names and meanings.

## Flanger

The input plus a copy through a delay of a few milliseconds swept by an LFO.  Mixed equally, the two cancel where the delay is an odd number of half periods: notches at (2k + 1) / (2t) Hz, peaks at k / t, a comb whose teeth all move as t moves (the jet whoosh).  Feedback around the delay (`y = D_t(x + g y)`, output `dry * x + wet * y`) sharpens the peaks at k / t (positive g, 1 / (1 - g) over the wet level) or puts peaks where the notches were (negative g: hollow and metallic, the comb an octave up).  `MAX_FEEDBACK` is 0.95, as the phaser's.

**Built from the library's delay** ("no second delay engine"): one `#delay` per side with a node time in seconds, `smooth: false` (the LFO is smooth already, and the delay's slew limit of 0.5 s/s would bend fast sweeps), the given `interpolation:` (sinc by default); with feedback that is `#delay`'s feedback-loop engine (a FeedbackLoop around a Filter::Delay, a bare loop without compensation), so ring-out, latency, and recipes come with it.  Numeric dry and wet levels mix in C on the loop's output (`FeedbackLoop#output_mix`); feedback 0 is a plain swept delay with its dry/wet in the delay filter.

**Sweep law**: the delay is `delay * 2 ** (range / 2 * depth * sweep)` with the sweep in -1..1: `range` octaves of delay around `delay` (the geometric middle), so the notches move evenly in pitch (`law: :octaves`, the default, the same shape as the phaser's `center * 2 ** (range / 2 * depth * sweep)`).  `range:` may be a Range of delay times for the ends (`0.5.ms..8.ms`, center sqrt(lo hi), octaves log2(hi / lo)), as the phaser's Range of frequencies.  `law: :linear` moves the delay evenly in time between the same ends (around their arithmetic middle), the sweep of plug-ins whose depth is given in ms; it wants a fixed delay and range.  (A third law, notches moving evenly in Hz like a bucket-brigade flanger whose clock follows a triangle, is a question, not built.)

**Through zero** (`through_zero: true`, cheap: one more constant delay per side): the dry signal is delayed by the sweep's center (whole samples, read directly), so the wet passes it twice a cycle; around the crossing the comb's spacing runs off to infinity, the tape-flanging moment.  The output is `delay` later than the input (latency); feedback still runs around the swept delay's absolute time.

**Settings shared with the phaser** (phaser-1's `Phaser.build`, read on its branch 2026-11-09): `rate` (Hz, a Pitch, a musical length per cycle that follows the tempo, a Length per cycle, or a node of Hz), `depth` 0..1, `feedback` signed, `mix` linear (`BlendMethods.gains(mix, :linear)`, multiplying `dry:`/`wet:`; 0.5 gives the deepest notches; a negative wet inverts), `spread` (the right LFO's phase offset in cycles; nonzero makes a mono input stereo; a stereo input is flanged per side), `shape` (:sine, :triangle), `phase`, `sweep:` (a -1..1 node replacing the LFO on both sides).  Its own: `delay` (the center, where the phaser has `center`), `range` (octaves of delay, or a Range of times), `law`, `through_zero`, `interpolation`.

**LFO** (`ModulationLfo.tone`): the rate as a Tone LFO; a `Sequence::Duration` is a Length, so it is matched before Lengths, or `1.bar` would freeze to its Hz at build time instead of following the tempo (found here; phaser-1's copy had the same order, reported to its branch).

**Presets** (family `:flanger`, effect kind; names are nouns that no effect preset uses as a tag; numbers chosen from common flanger settings, not yet judged by ear):

| preset | rate | delay, range | feedback | mix | spread | shape | about |
|---|---|---|---|---|---|---|---|
| `:sweep` (default) | 0.2 Hz | 2 ms, 4 oct (0.5-8 ms) | 0.5 | 0.5 | 0 | triangle | classic |
| `:jet` | 0.08 Hz | 2.5 ms, 5 oct (0.44-14 ms) | 0.85 | 0.5 | 0 | triangle | resonant whoosh |
| `:sheen` | 0.35 Hz | 4 ms, 1.5 oct | 0.2 | 0.35 | 0.25 | sine | subtle stereo shimmer |
| `:steel` | 0.15 Hz | 1 ms, 3 oct (0.35-2.8 ms) | -0.85 | 0.5 | 0 | triangle | hollow, metallic |
| `:orbit` | 0.25 Hz | 3 ms, 3 oct | 0.4 | 0.5 | 0.5 | sine | sides opposite |
| `:tape_flange` | 0.12 Hz | 3 ms, 2 oct, through zero | 0 | 0.5 | 0 | sine | tape flanging |

**Mapping a delay-depth-rate flanger plug-in** (Blue Cat's Flanger, which the maintainer's projects use: controls rate, depth, delay, feedback, stereo, mix).  UNVERIFIED: the plug-in's units and laws are from its control names, not measured; his Windows reference renders (each plug-in at his settings on an impulse, drums, and a level-stepped sine) will settle them.

| plug-in control | flanger setting | conversion (to check against the reference renders) |
|---|---|---|
| Rate (Hz, or a tempo-synced note) | `rate:` | Hz as is; synced values as musical lengths (`1.bar`, `2.bars`, `1.n4`) |
| Delay (ms) | the sweep's low end | if Delay is the shortest delay: `range: d.ms..(d + w).ms` with w from Depth |
| Depth | the sweep's width | if Depth is ms of sweep: w = depth ms, `law: :linear`; if a share of Delay: w = depth * d |
| Feedback (%) | `feedback:` | percent / 100, signed, clamped to +-0.95 |
| Stereo (LFO phase between sides) | `spread:` | degrees / 360 (0.5 = opposite) |
| Mix (dry/wet %) | `mix:` | percent / 100 (assumes a linear crossfade) |

**Cost** (Mac container, YJIT, thread CPU per sample after the source's own cost; `/claude/jobs/e84fa5c8/tmp/effects-2/proto/cpu.rb`): see the table added with the measurement below.

**Older script**: `bin/effects/flanger.rb` (2022) builds its own flanger from a delay, a feedback loop, softclips, and oversampling, with audio-rate LFO examples (to 3300 Hz); it is unchanged (whether it becomes a front end of `flanger` is a question: its examples depend on the softclips in the loop and the oversampling).
