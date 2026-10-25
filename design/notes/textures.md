# Textures: dust, drift, modal resonators

Built on branch textures-1 (2026-10-14) from the persona panel's requests
(Kaede Rowntree, the ambient persona: friction items F2, F9, F10, F19 on
`research-persona-zen` 88580e49; panel transcript on
`research-persona-panel` 0c08a17d).  The ambient patches in
`bin/synths/ambient.rb` had hand-rolled the same three things
(`ambient_dust`, `ambient_walk`, `ambient_bowl` as a sum of pings).

## dust (`GraphNode::Dust`, `FastTexture.dust`)

`dust(rate, bipolar: false, range: nil, min_gap: nil, seed: nil)`: sparse random
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
- `min_gap:` (textures-2, 2026-10-15; the maintainer: "Some of the bowl hits
  are too close together"): seconds, a Length, or a Duration.  The kernel
  counts samples since the last impulse; none may come before the gap, and
  allowed samples use p / (1 - p d) for the d = ceil(gap) - 1 samples each
  impulse shuts out, so the average rate stays `rate` (a refractory
  Poisson process) up to one impulse per gap, where they come like
  clockwork (`dust(100, min_gap: 1.8.seconds)` is a click every turn of a
  33 1/3 record).  Gaps of a sample or less are bit-identical to none.
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

`drift(rate = 0.2, range: -1..1, smooth: :cubic, walk: nil, hold: nil,
jitter: nil, from: nil, seed: nil)`: a slow random line.  Points (unit
values 0...1, mapped to `range` on output) arrive at `rate` per second on
average through a phase accumulator (phases within 1e-9 of 1 count, as in
`FastLofi.decimate`, so 1 Hz at 48 kHz steps exactly every 48000 samples).
The state keeps four points p0..p3 (plus the step's hold and speed); the
output moves from p1 to p2 over a step.

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
- Any tweening Curve as the step shape (textures-2, the maintainer's
  request: "random walk and hold using an overshoot curve feels like it
  would be a toy/animal-like unpredictability"): a Curve, a curve name other
  than the four above (`:ease_in_out`, `:back`, `:elastic`, `:smoothstep`),
  a Proc, anything `Curve.from` takes.  The kernel evaluates the curve's
  value table (`Curve#value_table`) with the Hermite lookup glides use, now
  shared in `ext/mb/sound/include/mb_curve_lookup.h` (fast_clip and
  fast_texture; `Curve.lookup_ruby` is the mirror).  Overshooting curves
  leave `range:` on purpose: not clamped (the overshoot is the point; clamp
  downstream if something can't take it).  `Curve[:back]`'s `overshoot:` is
  the distance past the target (0..1, default 0.1), not Penner's 1.70158.
  Curves print in recipes and graph documents (`Curve#to_ruby`:
  `Curve[:back, overshoot: 0.4]`, `Curve[30.0]`, bezier lists,
  `.reverse`/`.in`/`.out` variants; Procs and compositions are FIXMEs).
- `hold:` rests on each point before moving: a number is a share of the
  step (0..1; 1 holds it all, like :step), a Length or Duration a time
  (`80.ms`, `1.n16`), a Range of either a random hold per point, a node a
  share read at each point (a knob, live).  The segment position is 0 until
  the phase reaches the hold, then (phase - hold) / (1 - hold).
- `jitter:` (0..1, a number or a node read at each point): step lengths
  (1 - j) + j E in average steps, E exponential with mean 1 (at least
  0.001), so 0 is even spacing, 1 Poisson-like, and the mean rate stays.
- Three splitmix64 streams (the points; holds; spacing; seeds `seed`,
  `seed ^ HOLD_STREAM`, `seed ^ SPACING_STREAM`), so the points are the same
  whatever `hold:`, `jitter:`, and `smooth:` are.  Holds and spacing are
  drawn at each step's first sample (and the very first sample: the state
  holds NaN until then), so they're exact at any buffer size.  Without hold
  and jitter the output is bit-identical to textures-1's.
- `walk:` (0..1 of the range): each new point is p3 + walk (2u - 1),
  reflected at 0 and 1: a bounded random walk (one reflection suffices since
  walk <= 1).  nil: independent uniform points (smoothed noise).
- `from:` starts the line at a value (p0 = p1 = from): exactly for step,
  linear, cosine, and curves, near it for :cubic.  bin/synths/ambient.rb's
  `ambient_drift` (smoothstep, from the middle) is the old hand-made walk's
  shape.
- `range:` takes numbers only; node ranges go through `.at(a..b)`.

## Modal resonators (`GraphNode::ModalResonator < Resonator`, `FastResonator.modes`)

Plan layer (fuse-more-1, 2026-10-25): `Resonator` and `ModalResonator` are `Plan::Op::Resonator` (FastResonator's `ping` and `modes` loops moved into `include/mb_resonator.h`, shared by fast_resonator and fast_plan's `plan_resonator.c`), bit for bit on the node's own state; frequency nodes are described, decay nodes scaled to samples by a Mul; when the input ends the node rings out unfused (`#plan_tail?`), finding its exact end as before.  So drum voices' bodies and struck textures fuse with what plays and follows them.

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
  - `:gong` (textures-2): a free circular plate's modes (2,0) (0,1) (3,0)
    (1,1) (4,0) (5,0) (2,1) (0,2) (6,0) (7,0) (Rossing): 1, 1.73, 2.33,
    3.91, 4.11, 6.3, 6.71, 7.34, 8.95, 11.1, plus a denser cluster to 19.3;
    slow beats on four of them; a 0.8-semitone tension glide over 2.5 s;
    the modes from 3.91 up bloom (twins with rise shares 0.12 to 0.66 of
    the 14 s decay): measured on one strike at 110 Hz, the 400-2400 Hz band
    rises 8 dB over the first half second and stays near that for 2.5 s,
    going from 18 dB under the 80-300 Hz band to even with it by 1.25 s
    (textures-1's gong: falling from the strike, 7 dB under to 19 dB under).
  - `:bell` (textures-2): a minor-third church bell with the prime on the
    note (the maintainer: "Bell and gong are the least realistic"): hum
    0.5, prime 1, tierce 1.2, quint 1.5, nominal 2 (loudest at the strike),
    major tenth 2.5, eleventh 2.67, twelfth 3, double octave 4, upper fourth
    5.33; the nominal, twelfth, and double octave (2 : 3 : 4) put the
    virtual strike note on the prime; the hum rings longest (decay 14 s),
    warbling doublets on hum, prime, tierce, and nominal.  textures-1's bell
    had the nominal on the note, so it sounded an octave below what was
    played.  Ratios from Rossing and the Did You Know note "bell-partials".
  - `:chime` (textures-2): a wind chime, an aluminum tube hanging free:
    free-free beam modes 1 : 2.756 : 5.404 : 8.933 : 13.34, the
    fundamental on the note and the bright second mode loudest, long decays
    (7 s), a slight beat.  textures-1's tubular-bell chime (virtual pitch
    from modes 4-6, "rather bell like") is `:tubular` now.
  - `:bar`: free-free beam 1 : 2.756 : 5.404 : 8.933 : 13.34; `:marimba`
    1 : 3.99 : 9.14 (tuned wood, short); `:vibes` 1 : 4 : 10 (tuned
    aluminum, long).
  - `:glass`: wine-glass rim modes 1 : 2.32 : 4.25 : 6.63 (Rossing), with
    small doublets.  Wine glasses ring at about 400-1000 Hz (the
    maintainer: "octaves too low to be a wine glass unless it's for a
    giant" of textures-1's D4 render); the preset's pitch is 660 Hz.
  - `:plate`: a simply supported rectangular plate, sides 1 : 1.4, modes
    m^2 + (n / 1.4)^2 (12 lowest).
  - `:membrane`: an ideal circular membrane (Bessel zeros) 1 : 1.594 : 2.136
    : 2.296 : 2.653 : 2.918 : 3.156 : 3.501.
- Typical pitches (`Preset#pitch`, textures-2): `resonate(:glass)` with no
  frequency plays 660 Hz (bowl 220, rin 880, gong 110, bell 262, chime 880,
  tubular 440, bar 1760, marimba 440, vibes 440, plate 200, membrane 100).
- Glides (`glide:` semitones or an Interval, `glide_time:`; presets'
  defaults, :gong 0.8 over 2.5 s): the frequency becomes freq (1 + k
  level), k = 2^(glide/12) - 1, level the strikes' sum through a leaky
  integrator (`aabs.ping(0, decay: glide_time, phase: 0.25)`, clipped to
  0..1): a tension glide, larger for harder strikes, settling as the object
  calms.  Membranes at kick pitches take `glide: 7, glide_time: 0.12`.
  Gliding costs ~10 ns per row per sample until the level is below
  float32's resolution of the frequency (about 2.3 glide times).
- Bloom (a fifth mode field, a share of the decay): `.expand` adds a twin
  row of opposite amplitude decaying in that share, so the mode rings A
  (e^(-t/T) - e^(-t/Tb)), from silence to a peak after about Tb ln(T / Tb).
  Twins stay with their modes on a stereo side (`.expand_groups`), and
  normalization ignores them.
- `spread:` (number or node) returns stereo: two banks on the same strike,
  modes alternating (doublet partners stay with their mode), each side
  `own + other × (1 - spread)`.
- Exciters: dust, triggers (velocity = height), a lowpassed strike for a
  softer mallet, a steady quiet noise for a rubbed or bowed object.

## Noise colors (`noise(:pink)`, `Filter::NoiseColor`; textures-4)

`noise(:pink)` and `noise(:brown)` (alias `:red`) are white noise through
`Filter::NoiseColor`, Biquads in C (no new kernel).  Pink: alternating
first-order poles and zeros (poles 2.6x apart from 9.1 Hz, each zero half
a step above its pole, up to 0.49 fs; ratio and first pole from a grid
search for the least ripple), bilinear, paired into biquads (4 at 48
kHz): within +-0.17 dB of -3 dB/octave from 20 Hz to 20 kHz at 48 kHz.
Brown: a one-pole leaky integrator at 5 Hz (matched z; within 1 dB of
-6 dB/octave to 12 kHz; the bilinear form's zero at Nyquist fell 2 dB
short).  Both scaled to RMS 0.2 (-14 dBFS) from `noise`'s uniform white;
peaks pass full scale about once per 35 s.  64 ns/sample at 800-sample
buffers (white 19), ~105 at 128.  TODO (the maintainer: "Fuse later"):
one C call for the whole biquad chain and gain (four `biquad_narray`
calls plus a multiply per buffer now; pink costs ~3x white).  Why pink for placing sounds (the
maintainer, on the restless creature): broadband sound gives the ears
level and timing cues at every frequency, where a steady tone's direction
blurs with a room's reflections.

## Critters: flight sounds (`bin/songs/critters.rb`; textures-4, 2026-10-15)

A house fly and a mouse whose sounds follow drift paths (x, y, z in
meters around the listener).  The maintainer asked for a short review of
fly sound synthesis ("Wing frequency varies with effort"); findings:

- Wingbeat (the buzz's fundamental): house flies about 190 Hz (measured
  180-197 Hz in classic studies; "more than 200 Hz" in a 2025 preprint on
  fly flight control, bioRxiv 10.1101/2025.04.29.651276); Aedes aegypti
  mosquitoes about 450-660 Hz females, 600-1000 Hz males (several studies;
  rising ~8-13 Hz per degree C).  (The brief's ~230 Hz for honeybees was
  not verified.)
- Effort: flies make more force mostly by swinging the wings wider
  (higher wing speed), not by beating faster: in Lehmann & Dickinson's
  Drosophila power study (JEB 1997, abstract) extra force came with
  "an increase in stroke amplitude and a decrease in stroke frequency";
  their kinematics paper (JEB 201:385, 1998) has both changing; honeybees
  in low-density heliox kept "nearly constant wingbeat frequency while
  increasing stroke amplitude by nearly 50%" (Altshuler et al., PNAS
  102:18213, 2005); hawkmoths modulate both (about 32% frequency and 37%
  amplitude around the mean; Gau et al. 2021, abstract as summarized by
  search, not read in full).  So louder and brighter with effort is well supported; pitch
  rising with effort (the maintainer's ear, and a bit of doppler) is an
  artistic choice here, kept small: +1 semitone (the maintainer, 2026-10-15:
  "Smaller (+1 st)", after +2.5 in the first round).
- Spectrum and direction: a tethered blowfly's buzz is a harmonic series
  from ~190 Hz; the fundamental radiates like a dipole (strongest ahead of
  the fly), the second harmonic like a monopole (strongest at the sides,
  relatively), with broadband, wind-like "pseudo-sound" from the wing
  vortices behind the fly (Sueur, Tuck & Robert 2005, JASA 118:530).
- Procedural models: Farnell's Designing Sound (MIT Press 2010) builds a
  housefly from a shaped sawtooth (separate up- and downstroke shapes, a
  "wing resonance" parameter, a 700 Hz one-pole lowpass) with the wing
  frequency (around 220 Hz) and resonance wandering by twice-lowpassed
  noise (4-5 Hz); seen in a SuperCollider port (sccode.org/1-4QB, "Fig
  50.13/50.14").  Amfivolia (the maintainer's memory: right channel) is a
  sound artist who dissects ecosystem sound design on YouTube (Kilohearts
  interview: audio-rate modulation for animal sounds, randomness tied to a
  call's own amplitude or pulse rate; a bird synthesis project); no insect
  tutorial of his was found in a quick search, so none is cited.

What critters.rb does with it: effort = speed / 5 m/s + climbing / 2 m/s
(0..1, smoothed at 4 Hz) sets the wingbeat (190 Hz + 1 semitone at
full effort), stroke level (+7 dB), and brightness (lowpass 1.8-5.8 kHz);
the heading (cosine between the flight and the line to the listener) sets
the fundamental's dipole level (0.3..1; Tone#saw's fundamental is 2/pi of
an in-phase sine, so adding (d - 1) 2/pi of the sine sets it alone), a
second-harmonic sine at 0.25 is the monopole, and pink-noise wind rises
behind the fly with effort.  Measured on the wings alone: effort 0 to 1
raises the RMS 9 dB, the fundamental 190 to 220 Hz (with the first
round's +2.5 semitones; 201 Hz now), and the 2-6 kHz band
18 dB relative to 150-600 Hz; side-on, the fundamental drops 10 dB.
Mouse squeaks (the maintainer: "Squeaks should be longer and have a pitch
envelope; these sound like plucks"): 80-300 ms tonal chirps around 3-6
kHz (4200 Hz +-4 semitones), each with a random slope (-5..+5 semitones)
plus a random arch (-3..+6 at the middle), a 30-45 Hz quarter-semitone
vibrato, a quiet second harmonic; the scurrying ticks are round 3's.
(Audible squeak data is thin: a birch mouse's audible calls are tonal,
6.2-9.9 kHz and ~0.46 s, BMC Res Notes 2019, 10.1186/s13104-019-4719-9.)

Binaural (`--binaural`, optional): Brown & Duda's spherical head (1998):
per-ear Woodworth delays ((a / c)(1 - cos t) facing the ear, (a / c)(1 +
t - pi/2) around the head, a = 8.75 cm) through `aease` with Proc
curves, and a head-shadow high shelf with gain alpha(t) = 1.05 + 0.95
cos(t 180/150) (2x facing the ear, 0.1x at 150 degrees) at 1248 /
sqrt(alpha) Hz; plus a rough rear cue (a -6 dB shelf above 4 kHz behind
the listener: the pinnae shade sound from behind).  No pinna or
elevation model, so front/back stays ambiguous without head movement, as
with any spherical head.  Costs (whole script renders, Ruby graph): fly
~6% of realtime, mouse ~6%, binaural fly ~9%.

textures-5 (2026-10-16, Bench notes on round 4):

- Fly ("Delay changes are a little too extreme in speed"): the distance
  delay goes through a critically damped lowpass (`critter_place(...,
  smooth: 2)`, Hz; `-S`, 0 off).  Unsmoothed, jittered elastic darts
  moved the delay faster than `#delay`'s own 0.5 s/s slew limit (a -12
  semitone dive).  Measured on the binaural fly (seed 5, 32 s, 5x) with a
  1 kHz quadrature tone through the real delay, pitch shift p95/max and
  its rate p95: none 4.1/12.1 st, 144 st/s; 3 Hz 1.6/6.2, 29; 2 Hz
  1.2/4.0, 17; 1 Hz 0.8/1.6, 6.  The help example does the same.
- Mouse ("Scratches only immediately during movement?"): the round 3/4
  path never stopped (under 0.1 m/s 3% of the time, median 1.2 m/s,
  tens of m/s on jittered elastic steps) and the ticks were a steady
  `dust(25)`.  Now one random step gate (`drift(1.5, smooth: :step,
  jitter: 0.8)` above 0, lowpassed at 6 Hz) runs both drifts' clocks
  (a rate node of 0 freezes a drift mid-step), so x and y stop together
  (seed 3: still 24% of the time, median 0.9 m/s, at most 3 m/s); the
  tick rate follows the speed (35/s from 1 m/s, none when still; a 5 Hz
  lowpass on the speed lets a tick or two settle).

A `fly_by`/doppler helper waits for a second use (the maintainer); the
placement lives in critters.rb's `critter_place`.

textures-6 (2026-10-16, Bench notes on round 5):

- Fly: the maintainer picked 1 Hz of 1/2/3 Hz, "1.3 to 1.6 might be
  perfect", so the default is 1.5 Hz (`critter_place`, `critters`, `-S`,
  and the help example).  Same measurement as above, pitch shift
  p95/max and rate p95: 1.6 Hz 1.1/3.1 st, 12 st/s; 1.5 Hz 1.0/2.8, 11;
  1.3 Hz 0.9/2.4, 9.
- Mouse ("Tick density should threshold so there's only brief moments of
  scratching as the mouse darts"): the ticks start above a speed
  threshold (`critter_mouse(..., dash: 1.5)` m/s) and reach 40 a second
  0.7 m/s faster, with no lowpass on the speed, so walking, slowing, and
  standing still are silent.  Seed 3, 32 s: scratching 27% of the time in
  17 bursts (median 0.4 s, at most 1.4 s); textures-5 ticked 71% of the
  time, in bursts up to 5 s.  `dash: 2` scratches 13% of the time (median
  0.26 s).  `critter_velocity` is 0 for its first 20 ms (the delays still
  hold zeros; critters started at tens of m/s, and the mouse scratched).
- Tape: `ambient_tape(..., bits:)` sets the grain's depth directly (wear
  still sets wow and the lowpass), for the Bench's 12 / 10 / 8.2-bit
  comparison with the room-then-tape order and TPDF.  Hiss floor in the
  tail (one harp D4, before the voice gain, 3-4 s after the note): 12
  bits -82 dBFS, 10 bits -71, 8.2 bits -60.

textures-7 (2026-10-16, Bench notes on round 6; the last round):

- Fly: 1.5 Hz doppler smoothing kept (the maintainer: "d 1.5 hz (new
  default)").
- Mouse ("A slightly lower threshold still would be best, maybe 1m/s,
  and we can end there"): `critter_mouse(..., dash: 1.0)`.  Speed over
  the threshold on the default path (seed 3, 32 s, 20 ms differences;
  measured on the speed alone, so 1.5 reads 21% here, not the 27% above):
  1 m/s 33% of the time in 21 bursts (median 0.42 s, at most 2 s);
  1.5 m/s 21% in 16 (median 0.4 s, at most 0.8 s).
- Tape (harp, koto, tape, and tails all picked 12 bits): "12 bit default
  baseline, 10 bit at 0.6, keep 1.0 as is; wear doesn't introduce new
  noise I suppose, only generational copying would, so this is more
  impressionistic than realistic".  Wear now maps to the grain's depth
  through 12 bits at 0, 10 at 0.6 (the default), and 7 at 1: bits =
  12 - 5/6 wear - 25/6 wear^2, the one quadratic through the three points
  (slope -0.83 bits per unit wear at 0, -9.2 at 1: it falls all the way,
  gently at first).  The step is 2^(1 - bits) = 2^(-11 + (5 w + 25 w^2) /
  6); a node wear goes through `aease(->(t) { (2**((5 * t + 25 * t * t)
  / 6.0) - 1) / 31.0 }, out: 2**-11..2**-6)` (literals and its own
  parameter only, so presets load it without trust; within 2e-7 of the
  number path, the float32 lookup).  `bits:` still overrides.  Hiss
  floor in a harp D4's tail (one note, default voice level, 5-6 s): wear 0
  -79 dBFS, 0.6 -70 (was -60 at 8.2 bits), 1 -58 (the lowpass falls with
  wear too, so wear 0 sits 3 dB over a 12-bit grain at wear 0.6's
  lowpass).  It is an impression of an old tape, not a model of
  generational copying.

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
| `dust(300, min_gap: 5.ms)` (textures-2) | 1.6 | 0.01 |
| `drift(3, smooth: Curve[:back])` | 6.1 | 0.03 |
| `drift(3, Curve[:back], walk, hold: 0.2..0.9, jitter: 0.7)` | 5.0 | 0.02 |
| `drift(300, Curve, hold: 1.ms..3.ms, jitter: node)`, 128-sample buffers | 16.1 | 0.08 |
| `resonate(:bell)` 14 rows | 15.8 | 0.08 |
| `resonate(:gong)` 31 rows (glide + bloom twins), fixed pitch (`glide: 0`) | 31.0 | 0.15 |
| `resonate(:gong)` gliding, the 4 s after a strike | 145 | 0.70 |
| `resonate(:gong)` struck every 0.5 s (always gliding), 128-sample buffers (worst case) | 333 | 1.60 |

A gliding pitch costs ~10 ns per mode per sample (cos and sin per mode;
decay factors are recomputed only when the decay changes), so the worst
case is a 128-row bank gliding every sample (~1.3 us/sample, ~6% of
realtime per voice).  Fixed pitches cost ~1 ns per mode per sample.

## Help

`help :textures` and `help :recipes` (`lib/mb/sound/help/content/textures.rb`):
rain, wind, vinyl crackle, tape wow and flutter, bells, a breathing drone, a
noise riser, a sidechain pump; a restless creature (drift with walk, random
holds, jitter, and an overshooting curve); each example within the help
guard's level rules.  textures-2 (Bench notes): the bowl example keeps its
strikes 500 ms apart (`min_gap:`); symmetric ranges are a single number
(`drift(...).at(0.12)`, which equals `.at(-0.12..0.12)` for a -1..1
source, to within float rounding); the vinyl crackle is sparser, darker dust
(14 per second through a 1.4 kHz bandpass) plus a scratch once a turn at 33
1/3 rpm (`dust(100, min_gap: 1.8.seconds)`); the bells sit an octave lower
now that the prime is on the note.  textures-4: the restless creature pans
pink noise (easier to place than the triangle), and the fly's wings follow
its effort (speed from its own path: pitch, brightness, level).
textures-5: the creature is band-limited pink (300 Hz-6 kHz, the
maintainer's pick), the fly's doppler smoothed at 2 Hz (1.5 Hz since
textures-6).

## Ambient tape (`ambient_tape` in bin/synths/ambient.rb)

Wow, a dithered quantizer (12 bits at wear 0, 10 at 0.6, 7 at 1 since
textures-7, above; textures-4 to 6 went 10 to 7 bits, 8.2 at 0.6; 0.6 is
the default since textures-5, the maintainer's pick for harp and koto),
and a lowpass falling with wear.  textures-4's dither was half a
step of uniform noise, which left silence silent: the grain faded with
each tail (the maintainer heard it: "I feel like the noise goes down as
the amplitude goes down").  Measured on a 220 Hz tail falling 9 dB/s at
wear 0.6, the 1-4 kHz grain held -61 dBFS while the tail was above -55
dBFS and fell to -88 below.  textures-5 uses TPDF dither (two uniform
noises, a step either way; the error's power no longer depends on the
signal): a steady -60..-62 dBFS floor, a hiss per channel of a bundle.
The koto and harp now record their room onto the tape
(`ambient_tape(ambient_room(...))`; the room came after the tape), so
the reverb tail is worn and hissy too.  Side effect seen while
comparing: wow ahead of the room made the koto's room tail 6-7 dB
louder than without it (a delay without wow didn't; likely the pitch
wobble spreading a steady tone across more of the reverb's modes, not
verified).

Round 2 (the maintainer's answers, 2026-10-16): the tape stops with the
sound and ends with its source.  `GraphNode#sounding(hold:, fade:)`
(`GraphNode::Sounding`) is a gate: 1 while its source is above
`RingOut::THRESHOLD` (-90 dB) and for `hold` after its last loud sample,
then a linear fade to 0; it starts closed, and when the source ends (nil
or a short last read) it plays on as if the source were silent and ends
on the sample where it closes, the way delays ring out.  Each value
depends only on the samples since the last loud one (vectorized: a
cumulative count of loud samples indexes their positions; when `hold`
is at least a buffer, everything from a buffer's first loud sample is
1), so it is the same at any buffer size.  ambient_tape multiplies every
channel's dither by one gate (`stop: 1` s, fade 0.3 s; `Channels#sounding`
is one gate for a bundle, open while any channel sounds and ending when
all have ended: one tape transport, the maintainer's "One gate for both"), so the
hiss runs through the room's tail and stops a second after the room
falls below -90 dB (about 4.5 s after a harp note, 7 s after a koto
note), and the tape ends with its input: a koto render of
c2_sustain.mid ends on its own at 9.7 s (the 10 s runner cap took 12.4
s with steady hiss).  Cost (Ruby, per channel, incl. a constant or sine
source): 0.09-0.12% of realtime at 800-sample buffers, 0.29-0.40% at
128; a `hold` shorter than a buffer takes the general path (~0.85% at
128).  The ambient genre's `:wear` knob and `:emerge` scene are 0.6 too.

## Not built (ideas)

- Plan ops for Dust/Drift/ModalResonator (plan boundaries now).
- Per-mode strike position (amplitudes from a mode-shape at a strike point),
  mallet hardness as a built-in strike filter.
- A true vibraphone (many long-ringing voices, sympathetic resonance; the
  maintainer, later).
