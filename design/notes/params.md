# Params: one declaration record (`MB::Sound::Param`)

Built by param-1 (2026-10-24), phase 1 of the library design's critical path ("Param record only"; the design is in the workbench, `research/library-design/design-draft.md`, Params section, and `typing-survey.md` sections 3-4).  Phase 2 (Presettable, Library::Index, instruments as racks, shelves) builds on it.

## The record

`MB::Sound::Param` (`lib/mb/sound/param.rb`) is a frozen Data: `name, default, range, type, curve, unit, description, cc, implied, types, keyword, primary`.  `Param.declare(name, default, **opts)` is the line form every declaration shares; `ArgTypes::Param` is the same class (Signatures read `types`, `keyword`, `primary`, `default`).

- **Types from values** (`ArgTypes.classify`): 2400.hz is `:frequency`, 2.4.seconds `:seconds`, -12.db `:decibels`, 1.n16 `:duration`, notes `:frequency`; plain numbers `:number`, plus `:boolean`, `:string`, `:name` (Symbols).  `type:` is optional and types plain numbers (`type: :frequency` on 2400.0 means Hz); `unit:` is only for plain numbers.
- **Ranges**: endpoints of one type, going up; the default of the range's type and inside it (checked at declaration; a plain 2400 in a frequency range suggests `2400.hz`).  An Integer range with an Integer (or nil) default is stepped (`#stepped?`; graph documents' loose `20..10000` with a Float default stays continuous); an Array is a list of choices (an enum when Symbols).  Half-open ranges are allowed (script options like `2..`); knobs need both ends.
- **Curves**: canonical `:linear`, `:exp`, `:switch`; aliases `:lin`, `:exponential`, `:log`, `:db` (`Param::CURVES`, shared by Knob and ControlSpec).  Defaults by type: `:exp` for frequencies and times (seconds, samples, durations, tempos), dB-linear for Decibels (which is `:exp` over the gains they stand for), `:switch` for booleans, `:linear` otherwise.  A range touching 0 falls back to `:linear` unless `curve: :exp` is asked for (an error).
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
| detune | 0.cents..100.cents | interval |
| voices | 1..32 | number, stepped |
| attack | 1.ms..10.seconds | seconds, exp |
| decay, release | 1.ms..30.seconds | seconds, exp |

- **Ranged defaults**: `(lo..hi).at(default)` (`Range#at`, the canonical and printed spelling) and `default.in(lo..hi)` (on Numeric and the unit values: Pitch, Seconds, Samples, Interval, Phase, Duration, Tempo) make a `Param::Ranged`, checked when made, which every declaration unpacks.  No collisions: Pitch#at (amplitude) and Curve#in are other classes'; Tempo has no `<=>`, so tempo ranges can't be built yet.
- **Equality** by `Param.value_key`: Pitches are graph nodes compared by identity, so Data's own `==` wouldn't compare two 2400.hz defaults.
- **Checks** run where values arrive, never per sample: declaration (`Param::Error`, an `ArgTypes::ArgumentTypeError` whose suggestions print as did-you-mean), `#check(value, what:)` at load (document param overrides), build (ChannelMixer settings), and `turn` (Session::Knobs#warn_clamp), through `MB::Sound.live_error`: raise in scripts and specs, warn and limit live.
- **Printing**: `#to_ruby` (`param :cutoff, (150.hz..8000.hz).at(2400.hz), description: "..."`), `#document_line(value)` (graph-document format 4, exactly what documents always wrote), `#help_line`.  `#magnitude_range`, `Param.magnitude(v)` (base-unit numbers: Hz, seconds, gains, whole notes, semitones), `#typed(number)` convert.

## The declaration forms

| form | now |
|---|---|
| `ArgTypes::Param` | is `MB::Sound::Param` |
| `Knob::Spec` | builds and carries `#param` (validation, typed values, names-table ranges); keeps its Float fields for the hot paths; typed knobs print typed; `#respec` keeps the declaration when only takeover/smooth change |
| graph-document `param`/`knob` lines | build Params at load (`spec[:param]`, `Document#declarations`); accept `(lo..hi).at(v)`; still written as format 4 (no bump) |
| rack knobs (`knob :space, 0.3, ...` in a rack block; `macro` was renamed in ux-r4b) | through Knob::Spec, description in the Param |
| `ScriptRunner::Param` | carries `#param`; help text and option checks read its range (names-table ranges included); typed defaults parse; `ScriptRunner.declarations_of(path)` reads a script's declarations without running it |
| `MIDI::ControlSpec` | builds and carries `#param` (the mapped value's declaration; canonical curve names, `:exponential` an alias); `.from_param` builds one from a declaration |
| `ChannelMixer` class DSL (`param :position, default: 0, range: -1.0..1.0`) | builds Params; settings checked through `#check` |
| genre template `knob` tuples | still `[default, options]`, covered by the guard through Knob::Spec |

## Guard

`spec/lib/mb/sound/param_guard_spec.rb` (lib: ArgTypes signatures, every ControlSpec, ChannelMixer params, genre knobs, the names table; presets/: every document's param and knob lines) and `spec/bin/param_declarations_spec.rb` (every bin/ script's options, read in forks with `ScriptRunner.declarations_of`; `bin/sound.rb` and `bin/alloc_audit.rb` have no helper) check each Param with `spec/support/param_guard.rb`: default in range, a help line, a knob (numbers with a bounded range or a default inside 0..1), a document line that loads back equal (plain-number defaults), and `to_ruby` that parses.  2026-10-24: 2 ArgTypes params, 23 ControlSpecs, 6 mixer params, 15 genre knobs, 69 preset lines in 47 documents (all knobs and document lines), 521 options in 137 scripts (239 knobs, 195 document lines, 9 with names-table ranges, 239 without a range).

## Not yet

Presettable and the index (phase 2); typed values in documents (a format bump); knob stepping (stepped params are metadata); genre templates building Params directly; a Param-backed help page per node.

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
