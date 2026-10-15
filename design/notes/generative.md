# Generative music

The generative layer, phase G1 (branch `gen-1`, 2026-10-15), built to the proposal of the research spike `research-generative` (commit be0a9e79, `research/generative/README.md` and `proposal.md`; never merged).  CLAUDE.md keeps a summary and points here.  Update both when behavior changes.

## The shape

A generator is a **looping Clip whose events for each cycle are a pure function of (seed, cycle)**.  Every random choice is a counter-based draw (`dice.rand(:note, i)`: a hash of the seed and the keys), never a call on a stateful `Random`, so cycle 517 comes out the same computed cold (a seek, a take replayed from the middle, a render that starts at hour three) or after cycles 0..516.  Generator clips carry their per-cycle block as the clip's `Clip::Variation` (the hook `humanize(vary:)` and `permute(vary:)` already used), so they play wherever clips play: synths, `tr808`/`tr909`/kits, scenes, `swap`, `rec`, `bake`, MIDI export, takes, graph documents.

Maintainer, 2026-10-15: "Start G1 now"; on the proposal's four design choices, "Accept for now but discuss later after build":

1. Generators are Clips first (a stateful live MIDI source for call and response comes later, phase 5).
2. Generation runs one cycle ahead on the scheduler thread, with the dice in C.
3. Knobs are read at a decision point one beat before each cycle (per-generator `lead:`) — **G3, not built yet**: G1 generators take numbers and lambdas of the cycle.
4. Forms allow the same section name with different lengths — **G3/G4, not built**.

## Pieces (`lib/mb/sound/generative.rb`, `generative/`, `generative_methods.rb`)

- **Dice** (`generative/dice.rb`, kernel `ext/mb/sound/fast_generative`): state = splitmix64's finalizer of the seed; each key folds in as `mix(state ^ key)`.  Keys: Integers (low 64 bits, two's complement), Symbols and Strings (FNV-1a; `Symbol#hash` changes per process), Rationals (`mix(key(num)) ^ key(den)`), nil; Floats raise (draws must not depend on rounding).  `Dice.new(seed, *keys)`, `dice[:kick]` (a sub-path: `dice[:a].rand(1) == dice.rand(:a, 1)`), `rand`, `rands(n)` (one C call), `chance(p, ...)`, `int(range, ...)`, `pick(Array | Hash | Field, ...)`, `smooth(t, ...)` (value noise), `shuffle`.  `Dice.index(weights, u)` is the weighted pick everything uses: Array#sum's Kahan-Babuska total, then the first running sum past u * total (the C version reproduces Array#sum exactly).  `Dice.mode = :ruby` / `MB_SOUND_DICE=ruby` runs the exact mirror; `spec/ext/mb/sound/fast_generative_spec.rb` compares them.
- **Weights** (`weights.rb`): 12 pitch-class weights, a value (frozen), not a signal node, so operators are value arithmetic: `+` layers (or adds a number), `*` scales or masks class by class, `-` (floored at 0), `/`, `**` (sharpen), `blur(amount, reach:)` (leaks to neighbors, keeping the total), `blend(other, t)` (each side normalized, so halfway between keys favors the common tones), `floor`, `normalize`, `over(range, around:, width:)` → Field.  Made by `scale(:dorian, :d).weights` (`Scale#weights(*per_degree)`, a module included into Scale), `tones(D3, F3, A3)` (a chord layer; `chord` is the MIDI transform), `weights(12 numbers)`.  `puts w` is a bar chart.
- **Field** (`field.rb`): weights over a contiguous range of note numbers (pitch class × a Gaussian bell around `around:` with `width:` semitones), plus `harmonic` (the class weights inside the bell's 5% register) for `tonal` (the scale notes in register), `home(near)`, `near(target, u)`.  `draw(u)`, `**`.
- **Harmony** (`harmony.rb`): keyframes at clip positions (Durations, or numbers of bars from 0) of Weights, Scales, or note Arrays, blended between (`curve: :linear`, `:step`, or any Curve), `loop:`; `blur` and operators apply to the blend at each moment, and may take other Harmonies (`key.blur(0.15) + chords * 1.5`).  `at(position)` caches by position (512) and caches held keyframes with their operators applied; `over(...)` gives a **FieldTimeline** (`at(position)` → Field, its bell computed once, Fields cached by their weights).  `harmony(0 => a, 12.bars => b)` parses as keywords with non-Symbol keys (`**positions`).
- Every value remembers the expression that made it (`Generative::Value`) and prints it back: `scale(:dorian, D4).weights.blur(0.1) + tones(D3, F3, A3, C4) * 1.2`, parenthesizing equal-precedence right operands so values rebuild with the same rounding.  The recipe writer prints them through the same code (`RubyWriter#leaf`).
- **Generator** (`generator.rb`, `producer.rb`): the Variation block of a generator clip: `events(cycle)` computes once per cycle (a Mutex-guarded cache of 32 cycles), normalizes rows (`[start, length, value, velocity, { marks }]`, starts in exact whole notes or Durations; Floats raise) and checks `reach` (latest end from the cycle's start, 2 cycles by default; it sets the clip's note-off lookback), and keeps `stats` (cycles, notes, thread CPU, worst cycle).  `Producer` marks variations that replace events: `Clip#map_clip` (transpose, legato, reverse, stretch, rotate, vel, ...) wraps them with its map (`Mapped`), so transforming a generator transforms what it generates (before G1, `melody(vary: true).transpose(12)` silently played untransposed variations).
- **Ahead** (`ahead.rb`): reading cycle N queues N+1 on a runner: `Session::Scheduler#background(&block)` on a realtime session (the scheduler thread, priority -3; the scheduler attaches itself when its thread starts and detaches on close).  Renders and specs have no runner: cycles are computed where they're read, with the same events.
- **Clip.generate** (`clip_generate.rb`, console `generate`): `generate(1.bar, values: notes, seed:, reach:) { |cycle, dice| rows }`.  Cycle lengths must be lengths (`2.bars`, `1r/2`): a plain Integer raises (it would be a note division, the spike's friction 2).  `dice` is `Dice.new(seed, cycle)`; `Dice.new(dice.seed)` for draws shared across cycles.  The clip's own events are cycle 0's (what it plays without looping, what listings and `first_note` see).
- **Clip#values**: the notes a clip may play (`values:` for generator clips, else its events' values); drum kits (`Drums::Machine`, `TR808`, `Kit#plays_clip?`) choose voices from it instead of base events (the spike's placeholder events are gone).
- **strikes** (`strikes.rb`, console): candidates on each step of `every:` with `chance:` (a number or a lambda of the cycle), keyed by the **global** step, so the cycle `length:` only sets caching; a candidate within `gap:` steps after another candidate is dropped (a look-back rule: any cycle needs only `gap - 1` steps before it); the note is drawn from the field at the strike's position, sharpened by `sharpen:`.
- **melody** (`SequenceMethods#melody`, `generative/melody.rb`): with a Scale, the same notes as before G1 (`vary: true` is now a generator clip; each cycle still draws from `Random.new(Clip.cycle_seed(seed, cycle))`, and the walk's pick goes through `Dice.index`, the same arithmetic: 0 mismatches over 1000 seeds × parameter sets).  With Weights, a Harmony, a Field, or a FieldTimeline: a walk over the notes with weight (`leap:` of them at most), by weight / move size, from the strongest note nearest `start:`, reading the field where each note starts; counter-based dice.

## Seeds, takes, documents

- Seeds default to `MB::Sound.next_seed` (recorded as drawn seeds, `seed: drawn_seed(N)` in documents).  Takes replay generator tracks bit for bit at other buffer sizes, through scene changes, transposed generators, and seeks (`generator_spec.rb` "takes").
- Graph documents: `tones`, `weights`, `harmony` are top-level values (`Registry::TOP_EXTRA`); `Scale#weights` and the Weights/Harmony/Field methods are in `Registry::VALUES`; `strikes`/`melody`/`generate` are recorded DSL calls.  `generate` blocks print as their source and load with `trust: :code` (or a `named_proc`).  Limits: `LIMITS[:steps]` (4096) for melody counts; strikes check 4096 steps per cycle; Fields 128 notes; blur reach 1..6.
- `Clip#event_at` (chases after seeks and launches) now takes the previous cycle's last note before a cycle's first note (it took the same cycle's last note, which differs for varying clips).

## CPU (i9-9880H container, Ruby without YJIT, 2000 cycles each, thread CPU)

| generator | notes/cycle | mean | p99 | worst | per note | cold at cycle 10^6 |
|---|---|---|---|---|---|---|
| melody(Scale, 8, vary: true) | 8 | 103 us | 349 us | 9.5 ms (GC) | 12.9 us | 95 us |
| melody(harmony, 8, vary: true) | 8 | 152 us | 510 us | 1.2 ms | 19.1 us | 131 us |
| melody(harmony, 32 sixteenths) | 32 | 522 us | 1.3 ms | 2.1 ms | 16.3 us | 536 us |
| strikes(harmony.over, 1.n8) | 1.9 | 42 us | 137 us | 0.8 ms | 21.9 us | 133 us |
| strikes(1.n16, chance 0.9, gap 1) | 14.4 | 171 us | 497 us | 1.3 ms | 11.9 us | 105 us |
| generate (16 rows × 16 steps) | 77 | 372 us | 1.3 ms | 2.6 ms | 4.8 us | 468 us |

- Cost per cycle is bounded by the generator's shape (slots × leap, steps × gap, rows × steps), never by search or retries; there are no memo chains in G1, so a cold jump costs one cycle.  The worst cycles are GC pauses or a harmony's first visit to a blend position (blend + operators + a Field: ~35-40 us per new position, then cached); a looping harmony costs that once per loop position.
- A dice draw is ~0.3-0.5 us from Ruby (the C hash is a few ns; the rest is the method call), against ~150 us per note in the spike's Ruby-only dice.
- Live, cycles are computed a cycle ahead on the scheduler thread, so the render thread reads cached cycles; the first cycle after a launch or a cold seek is computed where it's read (one cycle's cost, above).

## Not built yet (later phases)

- G2: evolving rhythms (`beats`, energy, holds, Euclidean mutation, groove velocity curves, fills).
- G3: phrase memory (`phrases`: letters, answers, mutation), knob steering at decision points (`Knob#value_at`, per-generator `lead:`).
- G4: long form (`markov`, `lsystem`, `flow { generate ... }`, per-occurrence section lengths).
- Unattached `chord(...).weights`: `chord` is the MIDI transform; `tones(...)` makes chord layers.
- `ghost_chords` on a generator clip reads its base events (cycle 0) only.

## Demo and renders

`bin/songs/generative_demo.rb` (32 bars at 84 BPM: a key harmony blending D dorian ↔ F major with a stepped chord layer; a koto lead from `melody` on the probability scale, rin from `strikes`, low bowls from `strikes`, a sine pad from a plain `generate` block; `-l old` plays the older `melody(vary: true)` lead for A/B, `-u` sets the blur, `-s` the seed, `-p` one part).  Renders: `/app/tmp/listening/generative-g1/` (Listening Bench set `generative-g1-2026-10-15`, `bench_set.py` there).
