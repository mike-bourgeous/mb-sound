# Modulation effects (flanger, rotary speaker)

<!-- summary -->
`sig.flanger(:sweep | :jet | :sheen | :steel | :orbit | :tape_flange | rate, delay:, range:, depth:, feedback:, mix:, spread:, shape:, phase:, law:, through_zero:, sweep:)` (`GraphNode::Flanger`, library family `:flanger`) is a short delay swept by an LFO with signed feedback, built from `#delay`'s node-time DelayLine and feedback loop (no delay engine of its own); settings share names and meanings with `phaser` (rate in Hz or bars, linear mix, spread in cycles).  `sig.rotary(:cabinet | :whirl | :chorale, speed:, ...)` (`GraphNode::Rotary`, family `:rotary`) is a two-rotor rotary speaker (Doppler delays, tremolo, two microphones, rotors gliding between speeds).  Same output at any buffer size.
<!-- /summary -->

## Quick reference

- `sig.flanger` (`:sweep`), `sig.flanger(:jet)`, `sig.flanger(2.bars, feedback: -0.7, spread: 0.25)`, `sig.flanger(:steel, range: 0.3.ms..3.ms)`, `sig.flanger(sweep: env * 2 - 1)`; presets `L.fx.flanger`.
- `sig.rotary`, `sig.rotary(:whirl)`, `sig.rotary(speed: knob(:spin))` (turn :spin 0/1), `rotary(crossover: 1200, spread: 0.5, doppler: 0.5)`; presets `L.fx.rotary`.
- Code `lib/mb/sound/graph_node/flanger.rb` (`Flanger.build`), `rotary.rb` (`Rotary.build`), `modulation_methods.rb`, the shared LFO `modulation_lfo.rb` (`ModulationLfo.tone`); specs `spec/lib/mb/sound/graph_node/flanger_spec.rb`, `rotary_spec.rb`; help `help :effects`.

Built in effects-2 (2026-11-09; the maintainer's "Add effects to the plan including phaser, if time permits", the overnight plan in the workbench's `briefs/overnight-2026-11-08.md`, brief `briefs/effects-2.md`).  phaser-1 built `phaser` in parallel; the two share their settings' names and meanings.

## Flanger

The input plus a copy through a delay of a few milliseconds swept by an LFO.  Mixed equally, the two cancel where the delay is an odd number of half periods: notches at (2k + 1) / (2t) Hz, peaks at k / t, a comb whose teeth all move as t moves (the jet whoosh).  Feedback around the delay (`y = D_t(x + g y)`, output `dry * x + wet * y`) sharpens the peaks at k / t (positive g, 1 / (1 - g) over the wet level) or puts peaks where the notches were (negative g: hollow and metallic, the comb an octave up).  `MAX_FEEDBACK` is 0.95, as the phaser's.

**Built from the library's delay** ("no second delay engine"): one `#delay` per side with a node time in seconds, `smooth: false` (the LFO is smooth already, and the delay's slew limit of 0.5 s/s would bend fast sweeps), the given `interpolation:` (sinc by default); with feedback that is `#delay`'s feedback-loop engine (a FeedbackLoop around a Filter::Delay, a bare loop without compensation), so ring-out, latency, and recipes come with it.  Numeric dry and wet levels mix in C on the loop's output (`FeedbackLoop#output_mix`); feedback 0 is a plain swept delay with its dry/wet in the delay filter.

**Sweep law**: the delay is `delay * 2 ** (range / 2 * depth * sweep)` with the sweep in -1..1: `range` octaves of delay around `delay` (the geometric middle), so the notches move evenly in pitch (`law: :octaves`, the default, the same shape as the phaser's `center * 2 ** (range / 2 * depth * sweep)`).  `range:` may be a Range of delay times for the ends (`0.5.ms..8.ms`, center sqrt(lo hi), octaves log2(hi / lo)), as the phaser's Range of frequencies.  `law: :linear` moves the delay evenly in time between the same ends (around their arithmetic middle), the sweep of plug-ins whose depth is given in ms; it wants a fixed delay and range.  (A third law, notches moving evenly in Hz like a bucket-brigade flanger whose clock follows a triangle, is a question, not built.)

**Through zero** (`through_zero: true`, cheap: one more constant delay per side): the dry signal is delayed by the sweep's center (whole samples, read directly), so the wet passes it twice a cycle; around the crossing the comb's spacing runs off to infinity, the tape-flanging moment.  The output is `delay` later than the input (latency); feedback still runs around the swept delay's absolute time.

**Settings shared with the phaser** (phaser-1's `Phaser.build`, read on its branch 2026-11-09): `rate` (Hz, a Pitch, a musical length per cycle that follows the tempo, a Length per cycle, or a node of Hz), `depth` 0..1, `feedback` signed, `mix` linear (`BlendMethods.gains(mix, :linear)`, multiplying `dry:`/`wet:`; 0.5 gives the deepest notches; a negative wet inverts), `spread` (the right LFO's phase offset in cycles; nonzero makes a mono input stereo; a stereo input is flanged per side), `shape` (:sine, :triangle), `phase`, `sweep:` (a -1..1 node replacing the LFO on both sides).  Its own: `delay` (the center, where the phaser has `center`), `range` (octaves of delay, or a Range of times), `law`, `through_zero`, `interpolation`.

**LFO** (`ModulationLfo.tone`, one helper for `phaser`, `flanger`, and `rotary`: effects-2 moved phaser-1's `Phaser.lfo` into it after phaser-1 merged, as the coordinator asked): the rate as a Tone LFO; a `Sequence::Duration` is a Length and a `NodeDuration` may be a node, so they are matched first, or `1.bar` would freeze to its Hz at build time instead of following the tempo (found here; phaser-1 had the same order and fixed it before merging); `at_rate` only when the Tone's rate differs (with a node rate it reached into the rate node's graph).  `tremolo` (tremolo-1) keeps its own rate handling (Tone.new(frequency:), drawn wavetables, sample and hold): a candidate to build on it.

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

**Cost** (Mac container, YJIT, thread CPU ns per sample after the source's own cost, best of 3 x 4 s on a `110.hz.saw`, while another session's memcheck ran; % of realtime in parentheses): mono presets `:sweep` 292 (1.40%) at 128-sample buffers, 186 (0.89%) at 800; `:jet` 308 / 189; `:steel` 295 / 176; stereo presets `:sheen` 580 (2.78%) / 345 (1.66%), `:orbit` 559 / 336; `:tape_flange` (mono, through zero: one more delay and a Mixer) 494 (2.37%) / 327 (1.57%).

**Older script**: `bin/effects/flanger.rb` (2022) builds its own flanger from a delay, a feedback loop, softclips, and oversampling, with audio-rate LFO examples (to 3300 Hz); it is unchanged (whether it becomes a front end of `flanger` is a question: its examples depend on the softclips in the loop and the oversampling).

## Rotary speaker

The maintainer, 2026-10-24: "We should build a leslie sim in the effects project".  `sig.rotary(preset = :cabinet, speed:, crossover:, horn:, drum:, doppler:, tremolo:, spread:, ramp:, mix:)` (alias `rotary_speaker`; `GraphNode::Rotary`, library family `:rotary`) models the classic two-rotor organ cabinet (the Leslie 122/147 kind; help names no product): one input (a stereo input is averaged), a crossover, a treble horn and a bass drum spinning, two microphones.  Built from library pieces only:

- **Crossover**: Linkwitz-Riley 4th order at `crossover` (800 Hz, the cabinet's passive crossover) as two Butterworth SVFs per side (Q 1/sqrt(2)): flat sum (spec'd: 100 / 800 / 5000 Hz sines within 0.005 of their level with the rotors' effects off).  Not `#bands`: the Crossover's bands must be read in lockstep, and the input's end before the tail (a short read from `and_then`) put one band's Tee a frame ahead, printing "Crossover band 1 sampled again before the other bands" (a latent trap for any `bands` user with a short read upstream and Tee'd bands; recorded, not fixed).
- **Rotation**: each rotor's angle is a Tone LFO whose frequency is the rotor's speed, so the phase stays continuous when the speed changes.  `speed:` is :slow (:chorale, 0), :fast (:tremolo, 1), :stop (both rotors still, at the microphones' angles), a number 0..1, or a node of 0..1 (a knob): mapped to each rotor's slow..fast Hz and glided with `#clip_rate` (linear in Hz, like a motor's roughly constant torque) from the slow speed: horn 0.8 / 6.7 Hz, 1.0 s up and 1.6 s down; drum 0.67 / 5.7 Hz, 5.0 s up and 5.5 s down (`ramp:` scales the times).  UNVERIFIED: speeds and times are the commonly published figures for the cabinet (about 48/400 rpm horn, 40/342 rpm drum; spin-up about 1 s and 5 s), not measured here.
- **Doppler**: per rotor and microphone a `#delay` with a node time `CENTER - depth * cos(angle)` (1.2 ms center; horn +-0.44 ms, a 15 cm radius at the speed of sound; drum +-0.15 ms), sinc reads, `smooth: false`.  At the fast speed a 6 kHz tone wavers by 2 pi f_rot A f = +-111 Hz (+-32 cents; spec'd within 15% from zero crossings).
- **Tremolo**: the level `1 - am/2 + am/2 cos(angle)` (horn am 0.5, drum 0.3 at `tremolo: 1`): loudest pointing at the microphone, when the delay is shortest (spec'd: a 5 kHz tone swings 0.5 to 0.25 at 0.8 Hz, the other microphone opposite at `spread: 0.5`).
- **Microphones** `spread` turns apart (0.25 default: 90 degrees; 0 mono, 0.5 opposite).  Both end together `TAIL` (10 ms) after the input: the input is followed by silence and the delays don't ring out on their own (each would end at its own longest read, a different frame per side).
- `horn:`/`drum:` levels (gains, Decibels, nodes), `mix:` linear (dry is the input's own sides).

Presets: `:cabinet` (slow, the defaults), `:whirl` (fast), `:chorale` (horn 0.9, doppler 0.6, tremolo 0.5, spread 0.4, mix 0.8: gentle and wide).  Not modeled (questions): the horn's directivity filtering (a brighter sound pointing at the microphone), cabinet resonances, the amplifier's overdrive (a `softclip` before it does that), the brake; a stereo input kept per side.
