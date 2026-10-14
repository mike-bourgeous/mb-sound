# Textures: dust, drift, modal resonators

Built on branch textures-1 (2026-10-14) from the persona panel's requests
(Kaede Rowntree, the ambient persona: friction items F2, F9, F10, F19 on
`research-persona-zen` 88580e49; panel transcript on
`research-persona-panel` 0c08a17d).  The ambient patches in
`bin/synths/ambient.rb` had hand-rolled the same three things
(`ambient_dust`, `ambient_walk`, `ambient_bowl` as a sum of pings).

## dust (`GraphNode::Dust`, `FastTexture.dust`)

`dust(rate, bipolar: false, range: nil, seed: nil)`: sparse random
single-sample impulses, SuperCollider's Dust (heights 0..1) and Dust2
(`bipolar: true`, -1..1); `range:` sets any height range (`0.3..1` so
every hit is audible as a trigger, `1..1` for fixed heights).

- One splitmix64 draw per sample (the noise oscillators' generator, same
  constants as `Tone.noise_random`): an impulse when u < p = rate / fs
  (clamped to 0..1), height lo + (hi - lo) u / p, which is uniform over the
  range.  One draw per sample whatever the rate, so the impulses land on the
  same samples at any buffer size and a rate node can swell the density per
  sample.  Bernoulli per sample rather than exponential gaps: simpler, exact
  under moving rates, and ~1.4 ns/sample.
- Rate: Hz (number, Pitch, node), or the average time between impulses as a
  Length or Duration (`10.ms`, `1.beat`; Durations follow the tempo) through
  `Length::Source` (shared with Drift by `GraphNode::TextureRate`).
- Seeds: `seed:` or `MB::Sound.next_seed` at construction; recipes print the
  drawn seed, so documents reload bit-identically.
- As triggers: the impulses are positive single samples (unipolar), so
  `ping`, `resonate`, envelopes' `trigger:`, and `sample_hold(drops)` all
  take them; two impulses on adjacent samples merge into one rising edge
  for edge-triggered consumers (rare at sane rates).

## drift (`GraphNode::Drift`, `FastTexture.drift`)

`drift(rate = 0.2, range: -1..1, smooth: :cubic, walk: nil, seed: nil)`: a
slow random line.  Points (unit values 0...1, mapped to `range` on output)
arrive at `rate` per second through a phase accumulator (phases within 1e-9
of 1 count, as in `FastLofi.decimate`, so 1 Hz at 48 kHz steps exactly every
48000 samples).  The state keeps four points p0..p3; the output moves from
p1 to p2 over a step.

- `smooth:` `:step` (p1; aliases `:hold`, `:sah`, `:sample_hold`),
  `:linear`, `:cosine` (half-cosine, a gentle stop at each point), `:cubic`
  (uniform cubic B-spline over p0..p3: continuous in value, slope, and
  curvature; each output is a weighted average of points, so it never leaves
  the range, but it doesn't pass through the points and wanders a little
  less far: at the knots the weights are 1/6, 4/6, 1/6).  Catmull-Rom was
  the alternative; it overshoots the range by up to ~25% on random points
  and clamping would add flat tops, so the B-spline won.  All modes read the
  same points from the same seed (linear and cosine meet the step values at
  each point), so switching `smooth:` keeps the path.
- `walk:` (0..1 of the range): each new point is p3 + walk (2u - 1),
  reflected at 0 and 1: a bounded random walk (one reflection suffices since
  walk <= 1).  nil: independent uniform points (smoothed noise).
- `range:` takes numbers only; node ranges go through `.at(a..b)`.

## Modal resonators (`GraphNode::ModalResonator < Resonator`, `FastResonator.modes`)

`sig.resonate(preset, freq, decay:, beat:, spread:, normalize: true)`
(preset and frequency in either order).  Every impulse rings all modes of a
struck object: complex one-pole pings as `Resonator` (frequency and decay
may move every sample without changing the ringing level) at freq × ratio
+ offset Hz, each with an amplitude and a decay share, summed in double in
mode order.  One C loop for all modes (up to 128 rows; doublet partners
count).  Modes at or above 0.45 fs (or at or below 0 Hz) are silent, so
high notes lose their top modes instead of aliasing.  The subclass reuses
Resonator#sample's exact ring-out (ends where the summed bound
Σ|amp| |z| falls below -120 dB, on the same sample at any buffer size).

- Mode lists: `[[ratio, amplitude, decay share, beat multiple], ...]`
  (`ModalResonator.expand`): a mode with a beat multiple gets a partner
  `beat × multiple` Hz higher at 0.7 of its amplitude and 0.8 of its decay
  (a doublet: the two nearly equal modes of a slightly uneven object, which
  beat).  `normalize:` scales amplitudes to sum to 1, so a strike of 1 never
  peaks above 1.
- Presets (`ModalResonator::PRESETS`, aliases in `ALIASES`): ratios from the
  physics (ideal shapes or measurements), amplitudes and decay shares by ear
  within what the physics suggests.
  - `:bowl`, `:rin`: bin/synths/ambient.rb's bowl exactly (1 : 2.77 : 5.15 :
    8.1, doublets b = beat (i + 1)^1.3; beat 0.7 / 1.6 Hz, decay 24 s).
    Equal to the old sum of pings within 1e-4 (float32 sums and frequency
    arithmetic in float32 nodes versus double in the kernel).
  - `:gong`: a free circular plate's modes (2,0) (0,1) (3,0) (1,1) (4,0)
    (5,0) (2,1) (0,2) (6,0) (7,0) (Rossing): 1, 1.73, 2.33, 3.91, 4.11,
    6.3, 6.71, 7.34, 8.95, 11.1; slow beats on four of them.  (The ambient
    gong's glide and shimmer are a different instrument and stay.)
  - `:bell`: a minor-third church bell normalized to the nominal (the strike
    note, 1): hum 0.25, prime 0.5, tierce 0.6, quint 0.75, nominal 1, major
    third 1.25, fourth 1.335, twelfth 1.5, upper octave 2; the hum rings
    longest.
  - `:chime`: a free tube's bending modes (2n + 1)^2 for n = 2..7, scaled so
    modes 4-6 (near 2 : 3 : 4) imply a virtual pitch at ratio 1 that no mode
    plays (the tubular-bell strike note).
  - `:bar`: free-free beam 1 : 2.756 : 5.404 : 8.933 : 13.34; `:marimba`
    1 : 3.99 : 9.14 (tuned wood, short); `:vibes` 1 : 4 : 10 (tuned
    aluminum, long).
  - `:glass`: wine-glass rim modes 1 : 2.32 : 4.25 : 6.63 (Rossing), with
    small doublets.
  - `:plate`: a simply supported rectangular plate, sides 1 : 1.4, modes
    m^2 + (n / 1.4)^2 (12 lowest).
  - `:membrane`: an ideal circular membrane (Bessel zeros) 1 : 1.594 : 2.136
    : 2.296 : 2.653 : 2.918 : 3.156 : 3.501.
- `spread:` (number or node) returns stereo: two banks on the same strike,
  modes alternating (doublet partners stay with their mode), each side
  `own + other × (1 - spread)`.
- Exciters: dust, triggers (velocity = height), a lowpassed strike for a
  softer mallet, a steady quiet noise for a rubbed or bowed object.

## Costs (Linux desktop 7950X, min of 3, 800-sample buffers unless noted)

| node | ns/sample | % of realtime |
|---|---|---|
| `dust(300)` | 1.4 | 0.01 |
| `dust` with a moving rate node (incl. the LFO) | 13.9 | 0.07 |
| `drift(0.3)` cubic / `drift(500, smooth: :cosine)` | 3.6 / 7.8 | 0.02 / 0.04 |
| `ping` (1 mode, for comparison) | 4.0 | 0.02 |
| `resonate(:bowl)` 8 rows, fixed pitch | 9.9 | 0.05 |
| `resonate(:gong)` 14 rows, fixed pitch | 14.6 | 0.07 |
| `resonate(:plate)` 12 rows, gliding pitch (worst case) | 121 | 0.58 |
| `resonate(:gong)` 14 rows, gliding pitch, 128-sample buffers | 153 | 0.73 |
| `resonate(:bowl, spread: 0.6)` stereo | 24.4 | 0.12 |

A gliding pitch costs ~10 ns per mode per sample (cos and sin per mode;
decay factors are recomputed only when the decay changes), so the worst
case is a 128-row bank gliding every sample (~1.3 us/sample, ~6% of
realtime per voice).  Fixed pitches cost ~1 ns per mode per sample.

## Help

`help :textures` and `help :recipes` (`lib/mb/sound/help/content/textures.rb`):
rain, wind, vinyl crackle, tape wow and flutter, bells, a breathing drone, a
noise riser, a sidechain pump; each example within the help guard's level
rules.

## Not built (ideas)

- Plan ops for Dust/Drift/ModalResonator (plan boundaries now).
- Per-mode strike position (amplitudes from a mode-shape at a strike point),
  mallet hardness as a built-in strike filter, nonlinear gong pitch glides
  as a preset option.
- Granular freezes (with the sampler's grains, granular-1).
