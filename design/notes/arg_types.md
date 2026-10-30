# Type-dispatched parameters (`MB::Sound::ArgTypes`)

<!-- summary -->
`MB::Sound::ArgTypes` (`lib/mb/sound/arg_types.rb`) classifies argument values by type (tempo, ratio, seconds, samples, frequency including tagged `v.freq`, name, ...) from one ordered table, matches them against Signatures (keyword > type > position; canonical forms print keywords), and dispatches one method name to meanings by type through per-receiver Dispatch tables (`clip.clocked(x)`, `clip.at(x)`, `clip.over(x)`).  Errors and `help :at`/`:over` pages come from the tables, and a guard spec covers every row; the toolkit methods will adopt it ("Adopting it in a method" below).
<!-- /summary -->

Built by time-automation (2026-10-18) for clocks (`clip.clocked(x)`, `clip.at(x)`, `clip.over(x)`, `clip % x`), designed as a reusable library piece for the toolkit methods to come (maintainer via the Mac, 2026-10-18; notes in `/app/workbench/research/au5-color-bass/toolkit-ideas.md`: `rain.peq(h, midi.freq)` knowing `h` is a partial series and `midi.freq` a frequency; `.resonate`, `.peq`, ...).  The summary block above feeds the generated index (`design/notes/README.md`, `rake docs:index`).

## The classifier

`ArgTypes.classify(value)` names a value's type from one ordered table (`ArgTypes::TYPES`; each row a name, words, an example, a test):

| type | values |
|---|---|
| `:tempo` | `MB::Sound::Tempo` (`138.75.bpm`) |
| `:ratio` | `Rational` (`5/4r`) |
| `:seconds` | `Length::Seconds` (`19.7.seconds`, `250.ms`) |
| `:samples` | `Length::Samples` |
| `:duration` | `Sequence::Duration` (`2.bars`, `1.n8`) |
| `:decibels` | `Decibels` (`-6.db`), before plain numbers |
| `:interval` | `Interval` (`7.semitones`) |
| `:phase` | `Phase` (`0.25.cycles`) |
| `:curve` | `Curve` |
| `:frequency` | `Pitch` (Notes too), `Notes::Frequency` (`v.freq`), nodes tagged `:frequency` (`node.freq`) |
| `:notes` | `Clip`, `Notes`, `MIDI::Stream` |
| `:name` | `Symbol` (presets, clock and knob names) |

Untyped: plain numbers (`:number`) and graph nodes nothing tagged (`:node`) keep their positional meaning.  Partials (a partial series) is the first type the toolkit will add: a row in `TYPES`.

Tags: `ArgTypes.tag(node, :frequency)` marks a node in a weak identity table (`TAGS`, an `ObjectSpace::WeakMap`): no instance variables (shape variations fail specs), nothing printed, nothing kept alive.  `GraphNode#freq` (`SynthesisMethods`) tags its result; `Notes::Frequency` (`v.freq`, `v.hz.freq`, `clip.freq`) is a frequency by class.

## Signatures: keyword > type > position

`ArgTypes::Signature.new(name, receiver:, params: [Param.new(name:, types: { type => meaning }, keyword:, default:, primary:)])` declares a method's typed parameters (maintainer, 2026-10-18: "Keyword args can also disambiguate when types do not"):

1. Keywords place values outright (plain numbers and untagged nodes included).
2. Typed values go to the one open parameter taking their type, wherever they were written; a type two open parameters take raises (`ArgumentTypeError`) with the keywords to write; a type no parameter takes raises with the table.
3. Untyped values fill the remaining parameters in declared order.

`#bind(args, kwargs)` returns `{ param => value, rest: { other keywords } }`.  `#canonical(values)` gives the printed form (maintainer: "Canonical forms should probably use keywords"): the primary parameter positional (a preset, a pattern, a length), the others as keywords in declared order, only when they differ from their defaults: `resonate(:bowl, root: 220.hz, decay: 3.seconds)`.

## Dispatch tables: one name, meanings by type

`ArgTypes::Dispatch.new(name, receiver:, rows: { type => [canonical method, meaning] }, fallback:, fallback_meaning:, note:)` is a preposition whose meaning depends on its argument's type, one table per receiver.  `#call(receiver, value)` sends the row's canonical method (which is what recipes record, so graphs print `clocked(...)`, never `at`/`over`/`%`); a type without a row goes to the fallback (Sample#at's sample offsets) or raises with the table and, for plain numbers, the spellings that would work (`.at(2.bpm)`, `.at(2r)`, `.at(2.seconds)`).  Help pages are generated from the tables (`help :at`, `help :over`; `Help.arg_type_section`).

Every table registers in `ArgTypes::REGISTRY` under `[receiver kind, method]`; the guard spec (`spec/lib/mb/sound/arg_types_spec.rb`) calls every row with an example of its type and checks it reaches its canonical method.

Tables built so far (clocks; see arrangement.md "Clocks"):

| receiver | `at` | `over` | `%` |
|---|---|---|---|
| clip | tempo, ratio, seconds (period), name | seconds (period), name | tempo, ratio, seconds, name |
| sample | tempo, ratio, name; else offsets (as before) | seconds, name | tempo, ratio, seconds, name |

Decibels on clips are not in the table: clip velocities go through each patch's velocity curve, so a dB "velocity gain" would mean different things per patch (the error says to use `.vel` or the patch's gain).

## Adopting it in a method

- Declare the Signature next to the method (`SIGNATURE = ArgTypes.register([:node, :peq], ArgTypes::Signature.new(...))`), bind in the method (`vals = SIGNATURE.bind(args, kwargs)`), and keep a positional fallback for plain numbers so old calls work.
- Print canonically: when a method adopts the classifier, its recipe printing changes to `#canonical`'s keywords in the same branch, keeping round trips exact (recipe and graph-document specs); existing printers change only as each method adopts it.
- Tag new frequency-producing node methods with `ArgTypes.tag(..., :frequency)` (or make their class a frequency in `ArgTypes.frequency?`).
- Add a guard row example in `arg_types_spec.rb` for each new type.

## Lessons

| lesson | mechanism | class ruled out | status |
|---|---|---|---|
| A preposition (`at`) means different things on different receivers; prose docs drift | one declared table per receiver, errors and help printed from it, a guard calling every row | docs and errors out of step with dispatch | adopted |
| Recording an alias records the alias's name | aliases and prepositions call the canonical method unrecorded (they're outside the recorded surface: `Surface.mixin_surface` lists only `clocked`) | graphs printing several spellings of one call | adopted |
| Tagging nodes with ivars would add shape variations | a weak identity table | `:performance` warnings from tags | adopted |

## Params (param-1, 2026-10-24)

`ArgTypes::Param` is `MB::Sound::Param` (`design/notes/params.md`), the one declaration record, widened with range, curve, unit, description, and cc; Signatures read the same `types`, `keyword`, `primary`, and `default` fields, and `types` defaults to the default's type.
