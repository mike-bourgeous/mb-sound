# The library: entries, index, shelves, heads

<!-- summary -->
Every named thing (presets at every scale: effects, instruments, kits, clips, masters, sets) is a frozen `Library::Entry` in one `Library.index` (`lib/mb/sound/library.rb` + `library/`), found by name, by `find 'dark bass'`, or through the `L.fx`/`L.inst`/`L.kit` heads.  Classes with presets `extend Presettable` (one `preset` line each); shelves are searched session racks, project, user (a git repository), gems, then built-ins, and the first match wins.  `save` never replaces (`save!`, `bump: true`); library files load through `Library::FileLoader`, never eval; tracks take instrument entries as patches.
<!-- /summary -->

Branch library-core-1 (2026-10-26): phase 2 of the sound-design path, "the library core".  The design conversation is in the workbench (`research/library-design/`: `STATE.md` holds the decisions with dates, `design-draft.md` the draft and the revisions from Teo's critique, `teo-critique/critique.md` the reasoning).  The summary block above feeds the generated index (`design/notes/README.md`, `rake docs:index`).  Update it when behavior changes.

## Quick reference (from CLAUDE.md, 2026-10-30)

- Presettable classes: `extend Presettable`, `preset_family :reverb, kind:, keys:, apply:`, `param`, one `preset :hall, ..., tags:, about:, aliases:` line each; `X.presets`, `.preset_settings(:hall)`, `.preset_entry`.  Migrated: Reverb, Chorus, ModalResonator (`.from_preset`), Envelope (`Envelope.from_preset`, `Envelope::Curves`), Lofi, `DynamicsMethods::Squeeze`, Mastering (`Mastering.from_preset`, `.built_presets`), SQ80; Genre::Patches and tr808/tr909 register entries in code.
- Library files: `library 1`, family lines (`reverb :big_plate, decay: 3.5, tags: %i[bright]`), `instrument :x do |midi| ... end` (irack), `chain :x do |sig| ... end` (arack), `clip :x, seq(...)`.
- Console help: `help :library`.  Curated instrument knobs come from the synth scripts' `*_KNOBS` tables (bin/save_presets.rb).
- Struck instruments: `struck(clip, :bar)`, `L.inst.bar` (every resonator preset by reference), `L.fx.bar.ping(C5)`; auditions: `play L.fx.bar` / `play L.inst.x` (`Library::Audition`).  A playing track given another instrument rebuilds at its launch point, one undo step (arrangement.md, Library instruments).

## What it is

"Presets at every scale" (maintainer, layer 2 of the zoom-out): every named thing is one frozen `Library::Entry` in one `Library::Index` (`Library.index`), found by name, by `find`, and through the heads under `MB::Sound::L`.

```ruby
find 'dark bass'                     # ranked, with why each matched
L.fx.reverb.hall                     # an Entry; .(sig) uses it
220.hz.saw.then(&L.fx.hall)          # the same reverb(:hall)
L.inst.reese                         # dnb_reese and jungle_reese (a Query)
L.kit.tr909.(grid(16, kick: 'x...x...').loop)
shelves                              # where entries come from
save :dark_hall, g, tags: %i[dark big], about: 'A clipped hall'
save :dark_hall, g, bump: true       # :dark_hall_v2
save! :dark_hall, g                  # replaces (git keeps the old one on the user shelf)
collect                              # the presets this song used, into its presets/
promote :dark_hall, to: :user
```

## Entries (`lib/mb/sound/library/entry.rb`)

`Entry = Data(name, kind, family, tags, facets, about, params, shelf, location, settings, builder, source)`:
- `kind` is the scale (`Library::KINDS`: instrument, effect, note_fx, listener, modulator, kit, clip, master, set, envelope, sample_edit); each has a head (`Library::HEADS`).
- `family` is the namespace of the name and the verb that builds it: the Presettable families (reverb, chorus, resonator, envelope, env_curve, lofi, squeeze, mastering, sq80), `machine` (tr808, tr909), `genre_patch` (Genre::Patches), `clip`, and `preset` for everything `preset :x` loads (graph documents, rack documents, library-file instruments and chains, the Session's named racks).  Names are unique per family and shelf.
- `tags` are free words (adjectives and roles; "names nouns"), normalized to lowercase Symbols.  `facets` is an empty Hash reserved for the facet vocabularies (not decided: "tags first").
- `params` are `MB::Sound::Param`s (Presettable declarations with the preset's values as defaults, a library rack's literal `knob` lines, a document's param/knob lines); a Proc that makes them on first read is allowed (class presets declare them while mb-sound loads, before unit values like `2400.hz` exist), cached in a WeakKeyMap.
- `builder` makes the thing: `entry.(sig)`, `entry.(midi)`, `entry.(input: mic)`; `to_proc` for `then(&entry)`; `to_ruby` the family's code form.
- `source` is a library-file statement's text (after the top-level locals it reads): what collect and promote copy.
- Frozen, deep-frozen settings, no setters (the JavaBeans lesson: values, not bags).

## Presettable (`library/presettable.rb`)

The decided "A: class DSL line":

```ruby
module Chorus
  extend MB::Sound::Presettable
  preset_family :chorus, kind: :effect, label: 'chorus mode', keys: %i[rates min max],
    apply: ->(name, input, **o) { input.chorus(name, **o) }, code: ->(e) { "sig.chorus(#{e.name.inspect})" }
  param :rate, ...                                          # optional Param declarations
  preset :juno1, rates: [0.513], min: 0.00166, max: 0.00535, tags: %i[gentle], aliases: %i[juno juno_i], about: '...'
end
Chorus.preset_settings(:juno)     # aliases resolve when no entry has the name
Chorus.presets                    # { name => Entry }, shelves first
```

`preset_entry`/`preset_settings` raise `Unknown chorus mode :x (names)\nDid you mean?  :y` (one form for every family).  Registration is explicit (`Index#register`); a second shipped entry of a family and name, or a name that is another entry's tag or a family word under the same head, raises `Library::Collision` with a rename suggestion.

### Migrated tables (values unchanged; dumped before and after, equal; golden passes)

| was | now |
|---|---|
| `Reverb::PRESETS` (description: inside) | Reverb presets, `about:` |
| `Chorus::MODES`, `ALIASES` | Chorus presets with `aliases:` (`Chorus.mode` kept, reads them) |
| `ModalResonator::PRESETS`, `ALIASES`, `.preset(name)` | presets + `preset_alias`; `.from_preset(name)` gives the Preset struct |
| `Envelope::PRESETS`, `Envelope.preset(...)` | Envelope presets (family :envelope); `Envelope.from_preset(...)` |
| `Envelope::CURVES`, `CURVE_SHAPES` | `Envelope::Curves` (family :env_curve: `curves:`, `shape:`; `.values`, `.shape`) |
| `Sample::Lofi::PRESETS`, `PRESET_READS` | Lofi presets (`read:` a setting) |
| `DynamicsMethods::SQUEEZE_PRESETS` | `DynamicsMethods::Squeeze` presets |
| `Mastering::DEFINITIONS`, `.preset(...)`, `.presets` | Mastering presets (title is `about:`); `.from_preset(...)`; `.built_presets`; library presets take a builtin's chain with `like:` |
| `SQ80::PATCHES` | SQ80 presets (`SQ80.patch`, `.patch_names` unchanged) |
| `Genre::Patches` methods, `tr808`/`tr909` | entries (:genre_patch, :machine) registered in code |

`from_preset` is the builder name wherever a class's `preset` already meant "build from a preset" (Presettable's `preset` is the declaration line).  Knob curves and genre templates are not migrated (curves are aliases, not presets; templates have their own registry).

## Shelves (`Library.shelves`)

Search order (`SHELF_ORDER`), the first match wins: `:session` (the current Session's named racks; listing and heads only, `preset` reads files), `:env` ($MB_SOUND_PRESETS) or else `:project` (the presets/ of the nearest directory up whose Gemfile names mb-sound, `GraphIO.project_dir`, remembered per directory), `:user` ($MB_SOUND_USER_PRESETS, else the data dir: `GraphIO.user_presets_dir`), `:gem` (gems in the bundle whose gemspec has `metadata['mb_sound_shelf'] = 'presets'`), `:builtin` (class presets and mb-sound's presets/).  `GraphIO.preset_dirs` and `find_preset` are unchanged, so `preset :x` and every graph document load exactly as before; the index adds library files to the same order.  The shelf list is remembered until the working directory, those environment variables, $XDG_DATA_HOME, $HOME, or the bundle change, or `Library.reload!` (saves, collect, and promote reload).  Specs point $MB_SOUND_USER_PRESETS at an empty per-process directory (spec_helper).

Collisions (maintainer 2026-10-24, after Teo): user, project, and gem shelves warn once (`Library: reverb :hall from x.rb:1 shadows the builtin shelf's ...; find shows both`) and the first wins; a shadowing entry equal to the one it shadows (a pinned copy) doesn't warn; `Index#conflicts` and find's "(shadows builtin)" show them.  Shipped clashes in files and unreadable files go to `Index#problems` (a lookup never fails because a file is broken); the guard example in `library_spec.rb` checks shipped entries have no problems, conflicts, or name/tag clashes.

## Library files (`library/file_loader.rb`)

Any `*.rb` on a shelf that isn't a graph document or inside a bundle (`presets/fx/reverb.rb`, `presets/ins/keys.rb`): `Library::FileLoader < GraphIO::Loader` parses it with the documents' limits and forbidden-syntax checks and walks it (no eval):

```ruby
library 1                                                    # format, optional
wide = 0.6                                                   # locals may hold shared values
reverb :big_plate, room_size: wide, decay: 3.5, tags: %i[bright big], about: 'A big bright plate'
chain :dub, side: :audio, tags: %i[echo] do |sig, side:|     # an arack (ports like arack's)
  space = knob :space, 0.3, description: 'Echo level'
  sig.duck(side) + sig.delay(3.n16, feedback: space * 0.7, wet: space)
end
instrument :glass_keys, tags: %i[keys] do |midi|             # an irack
  midi.synth { |v| v.hz.triangle * v.amp_env * 0.3 }
end
clip :walk_a, seq(A2, C3, E3, G3).n8.loop, tags: %i[bass walking]
```

Family lines are checked against the family's `keys:` (did-you-mean); rack blocks are build blocks (`build_proc`), so the Rack walks them per application; `preset :glass_keys` gives the Rack (placed in the Session by `GraphIO.place_rack`, as rack documents are) and `preset :glass_keys, midi: riff` applies it; `L.inst.glass_keys.(riff)` does the same.  A library rack's params are its literal `knob` lines (read as document knob lines).  Files are read on the first lookup after the shelves change or a reload, not on every lookup (hot reload by modification time is phase 3's live safety).

## find (`Index#find`, console `find`)

Words from a String, Symbols, or an Array; per word the best of: exact name 100, a name word 40, a tag 30, the family/kind/head word 25, a name prefix 20, a tag prefix 12, a name substring 10, a description word 8.  Hits matching every word come first; when any entry matches every word only those are listed; then by score, shelf order, name.  Results print one line each: head path, kind, shelf, why, what it shadows, the description's start.  `kind:`/`family:` narrow; `L.fx.find(...)` searches within a head.  Graph documents' headers are read for it once per file version (kind from `kind:`/`rack:`, about from the description's first sentence, tags from `tags:` and a genre word starting the name: `dnb_reese` is tagged dnb).

## Saving (`library/saving.rb`)

Maintainer 2026-10-24 (Teo's pick): no REPL prompts.  `save :x, g` never replaces (warns: `Not saved: x exists (...); save! :x, ... replaces it, bump: true saves :x_v2`); `save!` replaces (keeping the old document's tags and description unless given); `bump: true` saves the next free `_vN`.  `tags:` and `about:` go into the header as `tags:` (a new optional meta key: older mb-sound reads it as informational metadata, so no format change) and `description:`.  Knobs the graph reads become knob lines, as before.  Saves go to `Library.save_shelf` (GraphIO.presets_dir: $MB_SOUND_PRESETS, else the project, else the user shelf).  `GraphIO.save` (the API, bin/save_presets.rb, script `--save`) still replaces.

The user shelf's git history (`Library::Git`): every save, collect, and promote into the user shelf commits there (`mb-sound: save :x`); the shelf becomes a repository on first use unless it sits inside another repository (then nothing is committed); git missing or failing warns once.  Project shelves are never committed (the song repository is the user's).

## collect and promote (provisional names)

`Index#uses` records entries looked up by family or loaded by `preset` (graph documents by path).  `collect` copies the used entries from the user and gem shelves into the song's presets/ (the project or $MB_SOUND_PRESETS shelf; `to:` a directory): documents and bundles whole, library statements into the file of the same relative path (creating it with `library 1`), and with `builtin: true` mb-sound's class presets too, as generated library lines (`reverb :hall, channels: 8, ...`, values printed with `Param.literal`).  Equal copies already there are skipped; different ones are not replaced.  The copies come first in search order and, being equal, don't warn.  `promote :x, to: :user | :gem | dir` (and `family: :reverb` for class presets) copies one entry from the project shelf (else wherever it is) onto another shelf; `promote!` replaces a different one (a statement is replaced in place, by its Prism location).  Names: `collect` after Ableton's "Collect All and Save" (Teo; not freeze, which means render-to-audio in DAWs) and `promote`, both provisional.

## Heads (`library/heads.rb`)

S1 with root `L` (maintainer 2026-10-26); the word heads are provisional: `L.inst`, `L.fx`, `L.kit`, `L.seq`, `L.master`, `L.set`, `L.env`, `L.edit`, `L.notes`, `L.listen`, `L.mod`, and `L.all`, `L.find`.  A head is a `Query` (the entries of its kind, read when made).  A word gives the entry named so, else narrows by a family or tag (always a Query), else by a word of the names (an Entry when one is left).  Words are singleton methods of each Query (Tab, did_you_mean); words named like Query's own methods or Object's go through `q[:word]`.  `UI::Completion` completes `L.fx.re<Tab>` by walking the words (`Heads.completions`), never by evaluating the chain.  `Entry#head_path` is the shortest path (the family is added when another family under the head has the name: `L.fx.reverb.plate` vs `L.fx.resonator.plate`).

## Param positions (`Param#position`, `#value`)

The DYK mark "try" (2026-10-25): 0..1 along the param's range and curve, so morph, randomize, and macros can move evenly in pitch and dB.  `:exp` ranges are logarithmic (Decibels: even in dB, since dB-linear is exp over gains), linear and stepped ranges linear (stepped values round), choices by index, booleans at 0.5.  Positions outside 0..1 give values outside the range (`#check` limits them).  Knob::Spec keeps its own Float copies on the hot path (same math).

## Instruments on tracks, preset knobs, struck resonators (library-instruments-1, 2026-10-28)

The maintainer's guesses from his 2026-10-27 take (workbench `research/api-guesses/take_20261027_193645.md`) and his decisions of 2026-10-28: "Params become knobs + curated"; "Yes, plus effects explain, plus make it easy to ping resonant effects as instruments and/or create instruments that reference the resonator effect presets".

**Library entries as a track's patch** (`arrangement/instrument.rb`, `Arrangement::InstrumentPatch`; arrangement.md, Library instruments): `track :bass, L.inst.dnb.dnb_reese`, `track :bass, :dnb_reese`, `track :bass, riff, :dnb_reese` (either order), and `track(:bass, &entry)` are the patch `{ |clip| preset :dnb_reese, midi: clip }` (graph documents) or `{ |clip| entry.(clip) }` (every other family: SQ-80, genre patches, tr808/tr909, struck, library-file instruments).  `track`'s positional values are sorted by type (Arrangement#track_values): a Clip or Kit (or a clip entry) is the track's clip, an instrument or kit Entry or a Symbol naming one its instrument, anything else its graph; a clip alone still plays as a graph.  A Symbol resolves like `preset :x` first (graph documents and library-file instruments in shelf order), else the one instrument or kit of that name in another family (several raise with their head paths).  Effects raise with a runnable example (`track(:bass) { |clip| preset(:dnb_reese, midi: clip).then(&L.fx.hall) }`, or a bus), except resonators, which play as their struck instruments (`track :bells, L.fx.bell` is L.inst.bell).  Graph document entries take their main input positionally (`L.inst.dnb.dnb_reese.(clip)`; `Library.document_builder`).

**Preset params become knobs** (`arrangement/track_knobs.rb`, `Arrangement::TrackKnobs`): a track's patch builds in `TrackKnobs.building(track, session)` (Arrangement.counted wraps every track patch, before its PatchCheck), and `preset` inside it gives each document param the patch leaves out as the Session knob `:"bass/cutoff"` (the Param's range, description, clamp; plain-number params named like a frequency or time take the names table's `:exp` curve), read through the existing knob-param path, so the samples are the same until it is turned (26 shipped presets with params, bit for bit).  Turn, learn, scenes, snapshots, undo, takes, set documents, and the inspector's knob rows work on them as on any knob.  Params the patch gives, and params `bind` made follow a knob, are not knobs.  Struck entries' decay becomes a knob the same way (`TrackKnobs::ENTRY_PARAMS`); other families' params stay numbers (their voices take numbers in places a knob can't follow or would change their sound).
- Two tracks playing one preset have their own knobs (`:"bass/cutoff"`, `:"bass2/cutoff"`).
- `preset` outside a track's patch (bg, plain graphs, scripts) makes none (proposal: knobs per player for `bg :x, preset(...)`; not built).
- `bind :bass, cutoff: :cut` makes the param follow an existing knob (one rebuild at the launch point, one undo step); `bind :bass, :cutoff` names the knob that's already there; the guess `bind :bass, :cut` gets `did you mean bind :bass, cutoff: :cut?` (the params whose range holds the knob's value).

**Curated knobs** (item 3): the synth scripts keep knob tables of each patch's own values (`DNB_KNOBS`, `JUNGLE_KNOBS`, `FUNK_KNOBS`, `AMBIENT_KNOBS`, `ELECTRIC_PIANO_KNOBS`), given to the voices as named Constants (bin/save_presets.rb passes them as options, so `--save` makes them params).  The documents render sample for sample like master-ai 8c7c1c24's.  Values that read through a node in float32 instead of a double (resonances and feedbacks like 0.55, sustain levels: ~4e-7) and nodes that change a voice's structure (a glide time node makes jungle_sub's lane not plan-fusable, so the idle lane sleeps and its free-running sines stop; the rain stick's adsr travel) were left out.

| preset | knobs |
|---|---|
| dnb_reese | cutoff resonance drive glide |
| dnb_sub | cutoff release |
| dnb_neuro | cutoff decay grit |
| dnb_pad | cutoff attack release |
| dnb_pluck | cutoff decay echo |
| dnb_boom | decay drop |
| jungle_breaks | cutoff grit |
| jungle_sub | release |
| jungle_reese | glide release |
| jungle_keys | decay |
| jungle_pad | cutoff attack release |
| jungle_flute | glide attack echo |
| funk_bass | bite decay |
| funk_keys | body decay |
| funk_clav | cutoff decay |
| funk_talkbox | glide echo |
| funk_choir | dub keep attack release |
| ambient_bowl, ambient_rin | space decay |
| ambient_koto | space wear decay |
| ambient_gong | space tune spread (as before) |
| ambient_harp | space wear (as before) |
| ambient_drone | attack release |
| ambient_rainstick | tip |
| tine_piano, tine_crunch | bark pickup decay release amp |
| reed_piano | bark pickup decay release |
| digibrass, organ_reso, square_bass | grit cutoff reso (as before) |
| sq80_* | cutoff reso chop flutter (as before) |
| init (sound-design-2) | wave1 wave2 tune2 mix fm am sync cutoff reso fenv fdecay attack decay sustain release glide (sync a build knob) |
| dnb_drums, funk_beat, funk_perc, jungle_perc | none (kits) |

**Struck instruments** (`lib/mb/sound/struck.rb`, `struck_methods.rb`): family `:struck` (kind :instrument), one entry per resonator preset with settings `{ resonator: name }` only, so the resonator preset (modes, decay, beat, pitch, glide) is the one source; params decay and beat are read from it.  `struck(clip, :bar, decay:, beat:, spread:, voices:, level:)` (a recorded top-level call; documents save `struck(midi, :bar)`) is a synth striking `resonate(:bar, v.freq)` with each note's trigger (velocity the height), at `Struck::LEVELS` (-20.3 LUFS on a 4-bar loop of `Struck.phrase` at 100 BPM; the membrane capped by its peak, about -27 LUFS).  `Entry#ping(*pitches)` strikes once (`L.fx.bar.ping(C5)`; chords; the typical pitch by default) and ends when rung out; `Entry#to_playable` (`Library::Audition`) is what `play entry` plays: a strike for resonator effects, the demo phrase for instruments (struck ones moved toward their typical pitch), a beat for kits; other effects raise with `play 220.hz.saw.at(0.2).for(1).then(&L.fx.hall)`.  Library files: `struck :soft_bell, resonator: :bell, decay: 6, beat: 0.4` (its level is its resonator's), or `instrument :x do |midi| struck(midi, :bell) end`.
- Not built: a mallet (a lowpassed or velocity-shaped strike), beat as a knob (build-time), a ping shorter than the -120 dB ring-out (the bar: ~15 s).

## Not built (phase 3 and later)

- Instrument params as block keywords (`instrument :reese do |midi, cutoff: 2400.hz|`, the draft's long form): rack blocks take ports as keywords, so params would need a value port type, and saving such a rack as a rack document a new `inputs` entry (a format change): library racks use `knob` lines inside for now.
- Facet vocabularies, computed facts, relations (`variation_of` from saves, as Teo suggested), the TUI picker and side panel, auditions on CUE, A/B, dirty?/diff, fav/recent, morph/randomize, hot reload of shelves by mtime, layouts' own store, migrations of saved files, generators.
- Instance readers on Presettable classes (`preset_name`, `param_values`): recipes already print `reverb(:hall, ...)`; Envelope keeps its `preset_name`.

## Lessons

| lesson | mechanism | class ruled out | status |
|---|---|---|---|
| Three classes already used `preset` as their builder (Envelope, ModalResonator, Mastering), and an Envelope subclass inherited it | one declaring macro; builders renamed `from_preset` everywhere | a class method meaning two things by argument shape | adopted |
| Declaring Params while mb-sound loads hits the names table before `.hz` exists | Presettable keeps param lines and builds Params on first read; Entry params may be a Proc | load-order NameErrors from declarations | adopted |
| A lookup that recomputed shelves walked the file system up to / per reverb or envelope (0.25 ms) | shelves remembered by a cheap key; project_dir remembered per directory; built-in fast path | per-build file system cost hidden in lookups | adopted |
| Specs stub `GraphIO.presets_dir`; a cache keyed on the environment doesn't see stubs | `Library.reload!` in those specs' before/after | stale shelves between examples | adopted (spec convention) |
| A file shelf's broken line must not break `reverb(:hall)` at a gig | file errors become Index#problems; shipped ones fail the guard | one bad file disabling a family | adopted |
| Session racks placed from library files shadowed their own richer entries | session entries skip names a library rack has | listings losing tags and params | adopted |
| A value that float32 can't hold differs when read through a Constant (lp4 resonance 0.55 vs 0.55 double: ~4e-7) | knobs/params checked by rendering every preset document against master-ai's, two clips; inexact candidates left out | "same sound" claims from reading code | adopted (library-instruments-1) |
| A node in a voice can change its skip-idle class (a glide time node: the lane isn't plan-fusable and sleeps, stopping free-running sines) | the same render comparison, with a sparse clip of rests | silent behavior changes from "harmless" nodes | adopted |
| Track patches had no name to pass to what they build | TrackKnobs.building around every counted patch (thread-local track and Session) | per-track state reaching nested builders through globals | adopted |

- Find-as-you-type (omnibus15; maintainer, 2026-10-28: "Better yet... find-as-you-type"): `Library::Finder#candidates("L.inst.ree")` ranks the entries left under a head chain by the typed letters anywhere (whole name 100, name prefix 80, name word 60, inside the name 40, tag/family prefix 30, inside 20), each with its chain (`L.inst.dnb_reese`; from the root `L.reese` the entry's head path; the family when two left share a name); nil outside head chains, for an exact entry, or a word that doesn't narrow (~4 ms a call over the shipped library).  `UI::LibraryPopup` (installed by `UI::Completion.install`) is a Reline dialog under the prompt listing them while the word is a head chain: Up/Down pick, Tab or Enter put the chain on the line (Enter runs the line when the pick is what is typed), Esc closes until the word changes; its keys are one-shot bindings held only while the list shows, so Pry's completion and multi-line input are untouched; the plain console and the tiles' REPL share it.  The library picker pane can use the same Finder.
