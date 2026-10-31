# Params: one declaration record (`MB::Sound::Param`)

<!-- summary -->
`MB::Sound::Param` (`lib/mb/sound/param.rb`) is the one frozen declaration record: knob specs, MIDI control specs, script options, graph-document `param`/`knob` lines, rack knobs, ChannelMixer params, and ArgTypes signatures all build one.  Types and units come from the values (`2400.hz`, `-12.db`), names imply ranges, `(lo..hi).at(default)` is the canonical ranged default, Integer ranges are steps; one range mapping, `Param::Scale`, maps positions along range and curve for params, knobs, controllers, ramps, crossfades, and velocity peaks, and `MB::Sound::ValueSource` is the one coercer and reader of values that move (numbers, knob names, knobs, nodes, params; one `value_at(pos, frame:, transport:, stream:)`).  Checks run at declaration, load, build, and turn (never per sample), through `live_error`; a guard spec checks every declaration in lib/, presets/, and bin/.
<!-- /summary -->

## Quick reference

- Declare with `MB::Sound::Param` (knobs, options, document `param`/`knob` lines, rack knobs): units from values (`2400.hz`, `-12.db`), `(lo..hi).at(default)` ranged defaults, `Param::Scale` for positions.
- Read moving values through `MB::Sound::ValueSource` (`value_at(pos, frame:, transport:, stream:)`); checks run at declaration, load, build, and turn, never per sample.
- Guard `spec/lib/mb/sound/param_guard_spec.rb` checks every declaration in lib/, presets/, and bin/.

The summary block above feeds the generated index (`design/notes/README.md`, `rake docs:index`).  Update it when behavior changes.

Built by param-1 (2026-10-24), phase 1 of the library design's critical path ("Param record only"; the design is in the workbench, `research/library-design/design-draft.md`, Params section, and `typing-survey.md` sections 3-4).  Phase 2 (Presettable, Library::Index, instruments as racks, shelves) builds on it.

## The record

`MB::Sound::Param` (`lib/mb/sound/param.rb`) is a frozen Data: `name, default, range, type, curve, unit, description, cc, implied, types, keyword, primary`.  `Param.declare(name, default, **opts)` is the line form every declaration shares; `ArgTypes::Param` is the same class (Signatures read `types`, `keyword`, `primary`, `default`).

- **Types from values** (`ArgTypes.classify`): 2400.hz is `:frequency`, 2.4.seconds `:seconds`, -12.db `:decibels`, 1.n16 `:duration`, notes `:frequency`; plain numbers `:number`, plus `:boolean`, `:string`, `:name` (Symbols).  `type:` is optional and types plain numbers (`type: :frequency` on 2400.0 means Hz); `unit:` is only for plain numbers.
- **Ranges**: endpoints of one type, going up; the default of the range's type and inside it (checked at declaration; a plain 2400 in a frequency range suggests `2400.hz`).  An Integer range with an Integer (or nil) default is stepped (`#stepped?`; graph documents' loose `20..10000` with a Float default stays continuous); an Array is a list of choices (an enum when Symbols).  Half-open ranges are allowed (script options like `2..`); knobs need both ends.
- **Curves**: canonical `:linear`, `:exp`, `:switch`, `:fader` (session-2, the maintainer's "dB curve" for level knobs: `lo + (hi - lo) * pos * |pos|`, so a 0..4 level is 0 dB mid-travel, silence at the bottom, +12 dB on top, 12 dB per halving of the position; level and key level knobs always use it; ramps and crossfades move evenly in position, in Ruby only); aliases `:lin`, `:exponential`, `:log`, `:db` (dB-linear), `:enum` (of `:switch`; maintainer, 2026-10-24) (`Param::CURVES`, shared by Knob and ControlSpec).  Defaults by type: `:exp` for frequencies and times (seconds, samples, durations, tempos), dB-linear for Decibels (which is `:exp` over the gains they stand for), `:switch` for booleans, `:linear` otherwise.  A range touching 0 falls back to `:linear` unless `curve: :exp` is asked for (an error).
- **Names imply ranges** (`Param.names`, `NAME_KEYS`): without a `range:`, a param named like a common control takes the table's range and curve when its default has the entry's type.  Plain numbers never take typed entries (their unit is unknown: scripts use `gain:` in dB and `rate:` for sample rates) unless `type:` says the unit.  An explicit range always wins; `#implied` marks the rest, and printed forms leave implied ranges out.  Rack knob names look up their last segment (`:"dub/mix"` is `mix`).

| name | range | type |
|---|---|---|
| cutoff, frequency (freq) | 20.hz..20000.hz | frequency, exp |
| rate | 0.01.hz..50.hz | frequency, exp |
| resonance (reso) | 0.0..1.0 | number (lp4 scale) |
| quality (q) | 0.1..20.0 | number, exp |
| drive | -24.db..36.db | decibels |
| gain | -60.db..12.db | decibels |
| threshold | -60.db..0.db | decibels |
| mix, depth, sustain | 0.0..1.0 | number |
| pan, feedback | -1.0..1.0 | number |
| width | 0.0..2.0 | number |
| detune | 0.cents..150.cents | interval |
| voices | 1..32 | number, stepped |
| attack | 0.1.ms..10.seconds | seconds, exp (also on MIDI CC) |
| decay, release | 0.1.ms..30.seconds | seconds, exp (also on MIDI CC) |

- **Ranged defaults**: `(lo..hi).at(default)` (`Range#at`, the canonical and printed spelling) and `default.in(lo..hi)` (on Numeric and the unit values: Pitch, Seconds, Samples, Interval, Phase, Duration, Tempo) make a `Param::Ranged` (its types checked when made; the declaration checks the default against the range), which every declaration unpacks.  No collisions: Pitch#at (amplitude) and Curve#in are other classes'; Tempos compare (`Tempo#<=>`, omnibus15), so tempo ranges build (`0.5.bpm..2.bpm`).
- **Units once** (omnibus15; maintainer, 2026-10-28: "I'd like to specify the unit only once as long as it's not ambiguous or contradictory"): `Param.unify_units` (in `Ranged#initialize` and `Param#initialize`, so every entry point: knobs, document lines, script options (their `allowed` range too), macros, ChannelMixer params, ArgTypes signatures) gives plain Integers and Floats the one unit type among the range ends and the default: `(100..8000).at(150.hz)`, `(100.hz..8000).at(150)`, `150.hz.in(100..8000)`, `declare(:cut, 2400, range: 150.hz..8000.hz)` are all Hz; Rationals count as plain beside a non-ratio unit (`(1/16r..1).at(1.n8)`); plain numbers beside Decibels are linear gains (the db rule; 0 or below raises: write it in dB).  Two unit types raise naming both (`100.hz..8000 with 2.seconds mixes a frequency (100.hz) and a length in seconds (2.seconds)`); `type:`/`unit:` disagreeing with a typed value raise as before.  Printed forms stay fully typed.  (`retype` of a Duration now makes a Duration, not a Rational.)
- **Equality** by `Param.value_key`: Pitches are graph nodes compared by identity, so Data's own `==` wouldn't compare two 2400.hz defaults.
- **Checks** run where values arrive, never per sample: declaration (`Param::Error`, an `ArgTypes::ArgumentTypeError` whose suggestions print as did-you-mean), `#check(value, what:)` at load (document param overrides) and build (ChannelMixer settings), and at `turn` the Session's own range check (`Session::Knobs#warn_clamp`, not `Param#check`: it names the knob's range and the `knob ..., range:` line that widens it; checked 2026-10-30), all through `MB::Sound.live_error`: raise in scripts and specs, warn and limit live.  Defaults outside their range go the same way (limited live; maintainer, 2026-10-24).
- **`clamp: false`** (on any declaration: `knob :wild, (0.0..1.0).at(0.5), clamp: false`, `param ..., clamp: false`) lets defaults, turns, follows, `#mod`, and checked values leave the range ("sometimes going out of bounds is interesting"); the range still scales MIDI controllers and the TUI.  Printed as `clamp: false`.
- **Printing**: `#to_ruby` (`param :cutoff, (150.hz..8000.hz).at(2400.hz), description: "..."`) from `#declaration_args` (the argument texts; `Knob::Spec#call_args` is it with the knob's name, learned `cc:`, `takeover:`, `smooth:`, and the description only when asked, printers-1: one declaration printer), values through `Param.literal` (`MB::Sound::RubyValue` with `gains: true`, no writer state), `#document_line(value)` (graph-document format 5: the same canonical spelling, typed as declared, at the document's value), `#help_line`.  `#magnitude_range`, `Param.magnitude(v)` (base-unit numbers: Hz, seconds, gains, whole notes, semitones), `#typed(number)` convert.

## The declaration forms

| form | now |
|---|---|
| `ArgTypes::Param` | is `MB::Sound::Param` |
| `Knob::Spec` | builds and carries `#param` (validation, typed values, names-table ranges) and its `#scale` (`Param::Scale` over its Float range: the hot paths' numbers; 0..1 and linear when the declaration has no range, :switch read as linear); adds only takeover and smooth; typed knobs print typed through `Param#declaration_args`; `#respec` keeps the declaration when only takeover/smooth change |
| graph-document `param`/`knob` lines | build Params at load (`spec[:param]`, `Document#declarations`; `spec[:value]` the base-unit number); format 5 writes the canonical spelling with typed values (`knob :cut, (150.hz..8000.hz).at(2400.hz)`), format 4 `range:` lines still load |
| rack knobs (`knob :space, 0.3, ...` in a rack block; `macro` was renamed in ux-r4b) | through Knob::Spec, description in the Param |
| `ScriptRunner::Param` | carries `#param`; help text and option checks read its range (names-table ranges included); typed defaults parse; `ScriptRunner.declarations_of(path)` reads a script's declarations without running it |
| `MIDI::ControlSpec` | builds and carries `#param` (the mapped value's declaration; canonical curve names, `:exponential` an alias); `.from_param` builds one from a declaration |
| `ChannelMixer` class DSL (`param :position, default: 0, range: -1.0..1.0`) | builds Params; settings checked through `#check` |
| genre template `knob` tuples | still `[default, options]`, covered by the guard through Knob::Spec |

## Format 5 and the repo's knobs (param-1 round 2, 2026-10-24)

GraphIO::FORMAT is 5: `param`/`knob` lines print as Params do, typed as declared.  `bin/save_presets.rb` rewrote all 47 presets (`graph 5`, `(lo..hi).at(v)`); every graph preset renders the same as its format-4 file (60 buffers of 800, md5 per preset), and set/rack presets' knobs have the same numbers.  Continuous knobs written with Integer ranges were migrated (maintainer: "Floats for continuous"): cutoffs and highpasses to typed Hz (`(150.hz..8000.hz).at(2400.hz)`), 0..1 sends and levels to Float ranges, in songs, genres, help, and three scripts' cutoff options; truly stepped values (seeds, voices, counts) keep Integer ranges.

## Positions (library-core-1, 2026-10-26)

`Param#position(value)` and `#value(position)` map values to 0..1 along the range and curve and back (the DYK mark "try": morph, randomize, and macros will work in position space, so a cutoff moves evenly in pitch): `:exp` logarithmic (Decibels: even in dB), linear and stepped linear (stepped values round), choices by index, booleans at 0.5; outside 0..1 gives values outside the range.  Presettable classes declare Params with `param` (built on first read; see library.md), and each preset entry carries them with the preset's values as defaults.

## One range mapping (`Param::Scale`, knobs-1, 2026-10-30)

arch-session (section 1) counted nine copies of the exp/linear range math; a knob, a controller, and a param on one range could answer differently.  `Param::Scale` (`lib/mb/sound/param/scale.rb`) is the one: a span `lo..hi` (may fall: inverted controllers, falling velocity ranges) along `:exp` or linear.  Class functions `.value(pos, lo, hi, curve)` and `.position(v, lo, hi, curve)` (Floats or DFloats, no allocation) serve hot paths; a Scale adds `#ramp_terms(from, to)` (`[k, a, b]`: the value `t` of the way is `exp((t * k + a) + b)` or `t * k + a`; what `FastArithmetic.knob_ramp`, `Knob#ramp_values`, and `Knob#value_at` compute, now once per ramp, `Knob::Ramp#terms`), `#between(a, b, t)` (crossfades, `xfade` crossfaders, `Gesture#value_at`, rack follow maps), and `#shift(x, by, amount)` (`Knob#mod`, numbers or nodes).

| user | through |
|---|---|
| `Param#position`/`#value` | `Scale.position`/`.value` (choices, booleans, steps, and typing on top) |
| `Knob::Spec#position`/`#value` | its `#scale` (`#positions` folded into `#position`, which takes DFloats) |
| `MIDI::ControlSpec.map`/`#position`/`.from_param` | `Scale.value`/`.position`; a centered controller is two scales from its center |
| knob ramps (C and Ruby), `Knob#value_at` ramps | `#ramp_terms` |
| crossfades, gestures | `#between` |
| `Knob#mod` | `#shift` |
| `Envelope.velocity_peak` (the C `env_peak`'s mirror) | `Scale.value` |

Formulas are the ones the kernels and the controller map used: `value` is `lo * (hi / lo) ** pos` on `:exp` (the controller map's and `env_peak`'s), `lo + (hi - lo) * pos` linear; `position` `log(v / lo) / log(hi / lo)` or `(v - lo) / (hi - lo)`.  Ramps, controller values, and velocity peaks kept their bits.  `Knob::Spec#value` and `Param#value` used `lo * exp(pos * log(hi / lo))` before: CC moves and UI steps on exp knobs, exp crossfades, and gesture points moved by an ulp or so (and position 1 now lands exactly on the range's end; the exp form missed 8000 by 3e-12).  `spec/lib/mb/sound/param/scale_spec.rb` sweeps seeded ranges through Param, Knob::Spec, ControlSpec, and velocity peaks (the same values at the same positions) and checks the C ramp against `#between`.

## Values that move (`ValueSource`, knobs-1)

`MB::Sound::ValueSource` (`lib/mb/sound/value_source.rb`) replaced the checkers that each took "a number, a knob name, a knob, a Reader, or a node" their own way (turn values, send levels, scene and section knob values, rack control ports, document params bound to caller values, clock speeds, followed tempos):

- `.coerce(value, what, read: :sample | :decision, numbers: (Range, Proc, or false), number_hint:, names: :keep | :check | :knob | false, knobs: session, channels:)`: numbers real, finite, and within `numbers`; knob names kept, checked, or resolved through `Session#knob!` (so aliases, track levels, primary controls, and did-you-mean come along); Knobs and Readers as they are; nodes followed per sample (`:sample`), or wrapped by `MIDI::Param.wrap` (`:decision`: knobs, tempo LFOs, constants, sums and products, clips, params; audio-rate nodes raise `NotAParam` with the follow-a-knob hint).  One message: `turn :cut takes a number, a knob name, knob(:x), or a node (got nil)`.
- `.value_at(x, pos, frame:, transport:, stream:, knobs:, now:)`: the one reader (`MIDI::Param.value_at` is gone).  Symbols are plain values (lock styles, modes) unless `knobs:` names a Session whose knobs they are; `now: true` reads knobs at their current value (`Clock::Free`, a clock outside a Session).
- One signature for everything that moves: `value_at(pos, frame: nil, transport: nil, stream: nil)` (Knob, Knob::Reader, every `MIDI::Param` class, `Clip#value_at`); `Param::Graph` passes `frame:` to the knobs in its tree, so `knob(:x) * 2` as a clock speed reads its knob at the exact frame like a bare knob.
- Not folded in: the per-node "must be a number or a node" checks inside DSL methods (their messages name the method's own argument) and `Knob::Reader` unwrapping outside these readers (`ValueSource.knob_of` for new code).

## Guard

`spec/lib/mb/sound/param_guard_spec.rb` (lib: ArgTypes signatures, every ControlSpec, ChannelMixer params, genre knobs, the names table, and every literal `knob` call in lib/ and bin/ (song blocks, racks, help; `ParamGuard.source_knobs`, 49 checked, 2 skipped for variables); presets/: every document's param and knob lines) and `spec/bin/param_declarations_spec.rb` (every bin/ script's options, read in forks with `ScriptRunner.declarations_of`; `bin/sound.rb` and `bin/alloc_audit.rb` have no helper) check each Param with `spec/support/param_guard.rb`: default in range, a help line, a knob (numbers with a bounded range or a default inside 0..1), a document line that loads back equal (numbers and unit values), and `to_ruby` that parses.  2026-10-24: 2 ArgTypes params, 23 ControlSpecs, 6 mixer params, 15 genre knobs, 69 preset lines in 47 documents (all knobs and document lines), 521 options in 137 scripts (239 knobs, 195 document lines, 9 with names-table ranges, 239 without a range).

## Not yet

Knob stepping (stepped params are metadata); genre templates building Params directly; a Param-backed help page per node.

## Lessons

| lesson | mechanism | class ruled out | status |
|---|---|---|---|
| Six declaration forms disagreed (`:exp` vs `:exponential`, units in descriptions, unchecked defaults) | one record built by every form, one curve table | drifting schemas and curve names | adopted |
| Pitches are identity-compared graph nodes | Param/Ranged compare `value_key`s | equal declarations comparing unequal | adopted |
| Data#with re-runs initialize with every member, including the carried Param | pass changes as arguments (`to_control_spec(cc)`), `Spec#respec` rebuilds | stale nested records after `with` | adopted |
| Marked strings from documents carry ivars that `Ractor.make_shareable` deep-freezes | copy with `String.new` before freezing | freezing the loader's state through a description | adopted |
| Names applied to plain numbers would misread units (`gain:` in dB, `rate:` a sample rate) | typed table entries only for typed values or `type:` | silent unit mistakes from names | adopted |
| Declarations made while mb-sound loads (ControlSpecs, mixer classes) | fast paths before ArgTypes, `NAME_KEYS` before building the table | load-order NameErrors | adopted |
| Every declaration needs a reader check | guard spec over lib/, presets/, bin/ | params that can't become knobs, help, or document lines | adopted |
| Silent clamps hid a wrong default (moving_params `:hits` 0 in 1..3) | defaults checked where declared, through live_error | wrong starting values | adopted |
| Knobs declared inside song blocks never reach a script-option guard | Prism scan of every literal `knob` call in lib/ and bin/, read as a document knob line | bad knob declarations outside script options | adopted |
| A nil default with an Integer range printed values as Integers (stepped) | documents declare params with their value; continuous ranges written as Floats | Integer drift through saved documents | adopted |
