# Source metadata (`MB::Sound::Meta`)

<!-- summary -->
`MB::Sound::Meta` (`lib/mb/sound/meta.rb`) lets the objects importers make carry what the foreign file said but mb-sound doesn't turn into sound: `meta :bass, source: { ... }` for a Session's named pieces and the set itself (`Meta::Store`, saved as `meta` lines at the end of set documents), `node.with_meta(...)` for graph nodes and bundles (`Meta::Carrier`, printed by `to_ruby`), `sample.with_meta(...)` for Samples (a Sample read from a WAV brings the file's own `meta[:source]`).
Values are plain Ruby (numbers, Strings, Symbols, true/false/nil, Arrays, Hashes); provenance goes under `:source` with shared keys (`Meta::SOURCE_KEYS`: format, file, kind, id, name, at, bytes, records, unread, fields).  Metadata is never part of the sound: renders with and without it are bit-identical.
<!-- /summary -->

## Quick reference

- Console: `meta :a3, source: { format: :acd, kind: :track, at: 0x12340, bytes: 5678, fields: { color: 3 } }` (merges by top-level key), `meta source: { ... }` (the set), `meta :a3` / `meta` (frozen Hashes, `{}` when none), `meta :a3, nil` (forgets), `metas` (one line per name); `help :meta`.
- Objects: `node.with_meta(source: { ... })` and `node.meta` (every GraphNode and `Channels` bundle), `sample.with_meta(...)`, `sample.meta[:source]`.
- Rules: `Meta.check` (plain values, an ArgumentError naming the key path), `Meta.merge`, `Meta.summary`, `Meta.statement` (the saved `meta` lines), `Meta.parse` (text back to values, never run).
- Saved: set documents (`save :gig, set`, `ruby set`), graph documents and recipes (`.with_meta(...)`), a Sample's `:source` in its saved file's `mb_sample_source` tag; takes replay `meta` lines.
- Specs: `spec/lib/mb/sound/meta_spec.rb`, `spec/lib/mb/sound/meta_methods_spec.rb`, `spec/lib/mb/sound/graph_io_meta_spec.rb`, `spec/lib/mb/sound/sample_source_spec.rb`.

Branch `source-meta-1`, 2026-11-10: a design branch, held for the maintainer's decision.  The request (2026-11-10): "Let's add metadata to every mb-sound type that maps from a converter so that understood but ignored fields get consumed.  Also include basic stats about the object like byte count and byte offset, and anything else that seems interesting or useful."  The .acd research converter accounts for every byte of a project file as read, understood-but-unused, or unread; the understood-but-unused facts and the provenance statistics are what this carries.

## What the library had (survey, 2026-11-10)

- `Sample#meta` (`{ why:, smpl_loops: }`, facts read from loop files) and `Sample#meta_source` (where each of `bpm`, `key`, `root`, ... came from): the convention this generalizes.  `with(meta: h)` replaces the whole Hash.
- Graph documents have header keywords (`graph 10, name:, kind:, description:, tags:`; `Document#meta`): facts about the document, not about what it holds.
- `Session::Names`: tracks, mute groups, knobs, buses, and racks share one namespace; scenes, sections, and markers have their own tables.
- Nothing on graph nodes but `named`.

## The value rule

A piece's metadata is one frozen Hash with Symbol keys at the top.  Values are Integers, Floats, Rationals, Strings, Symbols, true, false, nil, and Arrays and Hashes of those (nested keys: Symbols, Strings, or Integers), at most 32 levels deep.  Anything else raises an ArgumentError naming the key path (`meta[:source][:fields][:env] is a MB::Sound::Tone ...`), and nothing changes.  Value objects of the library (Decibels, Lengths, Notes, Ranges) are refused on purpose: metadata is what a foreign file said, in the file's own terms, and every allowed value prints through `RubyValue` and reads back through `Meta.parse` or the document loader as the same value of the same class (Rationals stay Rationals).  Stored values are deep-frozen copies; the caller's objects stay theirs.

Merging is by top-level key: `meta :a3, notes: 'x'` keeps `:source`; a second `source:` replaces the first whole (no deep merge, so what an importer wrote is never half-updated).

## The `:source` convention

Importers put provenance under `:source`; the library reads these keys only for summaries (`Meta.summary`, `metas`, `now`) and enforces nothing inside but the value rule.  `Meta::SOURCE_KEYS`:

| key | holds |
|---|---|
| `format` | the foreign format (`:acd`, `:wav`, `:mod`, `:mid`, `:sf2`, `:sfz`) |
| `file` | the file the object came from (a name or path, as the importer was given it) |
| `version` | the format version the file says it is |
| `kind` | what the object was in the file (`:track`, `:bus`, `:clip`, `:plugin`, `:envelope`, ...) |
| `id` | the object's own ID or index in the file |
| `name` | the object's own name in the file, when mb-sound names it otherwise |
| `at` | the byte offset of the object in the file |
| `bytes` | the object's size in bytes (for the file itself: its size) |
| `records` | how many records, events, or entries the object holds |
| `unread` | what was not understood: bytes (Integer) or the fraction of the object (Float, 0..1) |
| `fields` | understood-but-unused values by name (a Hash) |

Other keys are welcome (a WAV's `chunks`, a tracker's `tracker`); summaries count them (`+ 4 more`).  Top-level keys beside `:source` are free (`notes:`, `tags:`).

## Named pieces and the set (`Meta::Store`, `MetaMethods`)

- `Session#metadata` is a `Meta::Store` (`@metadata`, made in the constructor, so the Session keeps one instance variable layout; `ivar_layout_spec.rb` gives a Session metadata too).  The console's `meta` and `metas` (`lib/mb/sound/meta_methods.rb`; alias `metadata`) read and write it.
- Keyed by name alone: any Symbol, with or without a piece.  A song file may list its metadata first or last, and an importer may carry facts for a piece it didn't make (the listing says `not defined`).  `:master`, structured names (`:"a3/level"`), and names of every `Session::Names` kind work the same.
- Not a Session change: nothing here is read while rendering and nothing here changes what plays, so `meta` has its own lock, lands at once (also from scheduled blocks), journals nothing, and is not an undo step.  The rule "Session changes go through `Session#change`" is about things that land on a sample.
- What it survives: swaps, scene changes, undo and redo (they never touch it), and `untrack`: metadata stays with the name, as the name's knobs, level, mute, and routes do, so `untrack`'s undo and a new track of that name have it; `meta :name, nil` forgets it.  A new Session starts empty.
- `metas` returns `{ name => line }` like `tracks`, `markers`, and `wires` (the set's own under `nil`); a piece without a `file` of its own shows the set's.  `meta` with no arguments is the set's own Hash (the contract), so the listing has its own name.  `now` shows one line when there is any.  Takes replay `meta` lines; `metas` is a listing (`Take::FOREGROUND`).
- `spec/support/session_guard.rb` counts metadata as set state left in the default Session.

## Saved (`GraphIO::SetWriter#meta_lines`, `Loader::SET_COMMANDS`)

Set documents end with the metadata, after the flow, so the song reads first: a comment line, the set's own `meta source: { ... }`, then each name's in the order it was first given.  One line when it fits 120 columns, else `meta(:name,` with a top-level key per line and long Hashes and Arrays opened, their entries filled to the width (`Meta.statement`).  Names without a piece are saved too.  `meta` is a set command for the loader (plain values through the document rules; no block), so a loaded set has the same store and saves the same text; the same set with its metadata forgotten saves the same document minus those lines and plays the same (`graph_io_meta_spec.rb`).  `ruby set` prints the set document (it printed a FIXME for an Arrangement before).

No format bump (`GraphIO::FORMAT` stays 10): documents without metadata are byte for byte what they were, and a new line kind follows `wire` and tracker sets, which didn't bump either.  A reader older than this branch stops at `meta` as an unknown set command.  Open question 4 below.

## Graph nodes and bundles (`Meta::Carrier`)

`GraphNode` and `Channels` include `Meta::Carrier`: `with_meta(values)` merges and returns the receiver (it chains like `named`), `meta` reads.  The Hash lives in `@carried_meta`, declared with `GraphNode::IvarPreset` (and set in `Channels#initialize`), so no node changes shape.  Nothing reads it while sampling: no `#sample`, plan, `plan_describe`, node trait, or allocation budget is involved (`meta_spec.rb` compares a graph with and without metadata bit for bit, unplanned and through `plan_compare`).

`with_meta` is recorded like `named` (`Recipe::Surface.refresh!`), as a configuration call: `to_ruby` prints `.with_meta(source: { ... })`, graph documents save it, and the loader's registry allows it because it is recorded.  Metadata belongs to the object it was given to: a node made from it (`node.lp4(300)`) carries none, and a Tee branch reads its own.

## Samples (`Sample::Source`, `lib/mb/sound/sample/source.rb`)

- `sample.with_meta(values)` returns a copy with the values merged into `#meta` beside the loop-file keys (`:why`, `:smpl_loops`), recorded in the lineage, so documents print `Sample["x.wav"].with_meta(...)`.  Copies, views, and edits already passed `@meta` along.
- `Sample#save` keeps `meta[:source]` as the tag `mb_sample_source` (its `RubyValue` text; at most 32 KB, a larger one is left out with a warning), and `Sample.from_file` reads it back through `Meta.parse`, a Prism walk over literals that runs nothing (a tag is data from a file).  Other top-level keys given with `with_meta` are kept by documents (lineage) but not by a bare `save`.
- A Sample read from a sound file brings the file's own `:source`: `format`, `file` (the name without folders: saved tags and bundles must not carry a machine's paths), `bytes`, `sample_rate` as stored; for a WAV also `container`, `channels`, `bits`, `frames`, `data: { at:, bytes: }`, `chunks` (`[id, offset, size]` rows from `Sample::Riff`, the first 64), `chunk_count`, `skipped` (ids of chunks mb-sound doesn't read), and `unread` (their bytes with headers).  No extra read: `LoopInfo.read(..., riff_out:)` hands over the `Riff::Info` it parsed anyway; the file's size is one `File.size`.  A `:source` the caller gives (`Sample[path, meta: { source: ... }]`) or a saved file's tag wins.
- `strc` counts as read once `Riff::Info` has it (acid-loop-info-1, held): `Source::READ_CHUNKS` plus `riff.respond_to?(:strc)`.

## Measured (2026-11-10, Linux container)

- A four-bar set (patch track, graph track, bus with a send, two scenes, a swap) with metadata given before, between, mid-song from scheduled blocks, and on a node inside the patch: both channels bit-identical to the same set without any, and the journal's changes land on the same positions (`meta_methods_spec.rb`).
- `render_allocations_spec.rb` budgets unchanged (nothing on the render path).

## Open

1. Pieces outside `Session::Names`: scenes, sections, markers, and clips have no place yet.  Today an importer can use a structured name (`meta :"a3/clip7", ...`) or nest under the owner's `fields`.  Options: a kind-qualified form (`meta :scene, :verse, ...`), `Clip#with_meta` (clips print through recipes, so set documents would keep it), both, or neither.
2. `meta` is not an undo step, and stays through `untrack`.  Both follow "metadata is not sound"; either could go the other way.
3. `Sample#save` keeps `:source` only.
4. No format bump (above).
5. The session fuzz has no `meta` command: appending one changes every seed's song for a command the render never sees; the as-if specs and `ivar_layout_spec.rb` cover it instead.
6. The catalog budget went from 17 500 to 17 600 bytes for the `:meta` topic line and `meta`/`with_meta` (17 565 used).
7. The next importers to fill `meta[:source]`, with what each has at hand (none built here):
   - Tracker modules (`mod_import`/`tracker_import`, `mod_samples`): the set: format, file, bytes, `tracker` (the tracker that wrote it), title, channels, pattern and order counts, `Song#problems`, the effects the player skipped (`Tracker::Set#unsupported`); each track: channel index, its pan and volume; each Sample: sample index, the module's name for it, stored rate, bits, finetune, relative note, default volume, and (once the readers keep them) its offset and length in the file.
   - MIDI files (`midi_file`, `midi_clip`, `midi_kit`, `midi_tracks`): the file: format 0/1, division, track count, bytes; each track or clip: track index and name, channel, event count, the meta events mb-sound doesn't play (text, lyrics, cue points, key signature), program and bank numbers when the clip takes another instrument.
   - SoundFonts (`sf2`): the font: its INFO names, version, bytes; each instrument: bank, program, preset name and index, zone count, the generators skipped (`Font#skipped`); each Sample: the sample header's name, index, stored rate, original pitch and correction, link and type, its offset and length in `smpl`.
   - SFZ (`sfz`): the file and its control settings; each region: header index and line, its group's and global's opcodes, the opcodes ignored (already counted for the warning), the sample path as written beside the one found.
   - Loop files (`loops`, `Sample[]`): WAV is done here; next FLAC (its metadata blocks with offsets and sizes, the foreign RIFF chunks kept in APPLICATION blocks) and AIFF chunks, the same shape as the WAV list.
   - The .acd converter (research): its emitted `meta` lines per the contract above.
