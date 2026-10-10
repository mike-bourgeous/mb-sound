# Graph I/O (recipes and Ruby export)

Graph import/export, phase 1 (branch `graph-io-1`, 2026-10-10).  The study is branch `research-graph-io` (`research/graph-io/README.md`, `proposal.html`); the maintainer's decisions of 2026-10-10 are summarized at the end.  CLAUDE.md keeps a summary and points here.  Update both when behavior changes.


## What it does

Every graph remembers the DSL calls that built it ("recipes"), so it can print itself back as Ruby: `node.to_ruby` (alias `to_rb`; also bundles, Synths, Notes, clips), `node.to_ruby(inputs: { midi: notes }, seeds: false)`, console `ruby node` (also `ruby [l, r]`).  fm_bass prints as its own source (lane locals, operators, `13.db`, `100.ms`) and the printed code renders bit-identically.

```ruby
ruby 220.hz.ramp.filter(:lowpass, cutoff: 800).delay(1.n16.dotted).softclip
# 220.hz.ramp.filter(:lowpass, cutoff: 800).delay(1.n16.dotted).softclip
```

## Recording (`lib/mb/sound/graph_node/recipe.rb`, `recipe/surface.rb`)

- Generated recorder modules are prepended to the DSL surface by `Recipe.install!` (end of `lib/mb/sound.rb`; `Recipe.refresh!` when GraphNode includes a new module): the GraphNode `*Methods` modules plus `#named` (on GraphNode and on every node class that defines a DSL name itself, e.g. `Pitch#tone`, `FourPole#filter`), Tone, Pitch, NotePitch, Notes (plus ModMethods), Channels, Clip/Seq, Note's length methods (`C4.n8`), MB::Sound's top-level graph modules (`Surface::TOP`, plus `file_input`), `Numeric#constant`, `Array#channels`/`#reverb`, `KeyMap.zones`, and `.new` of node classes, filters, Notes, KeyMaps, and drum Kits when called from outside `lib/mb/sound` (`NewRecording` checks the caller; e.g. `GraphNode::Mixer.new(taps)` in a script).
- `Surface::EXEMPT` (per class) and `Recipe::EXEMPT` (GraphNode) list the public methods left out, with reasons (readers, plumbing, things the library calls while sampling); predicates, setters, and `plan_*` are always out.  The guard in `spec/lib/mb/sound/graph_node/recipe_spec.rb` checks that the first method in every node class's ancestry for each DSL name is a recorder, and that every public method of the surface classes and top-level modules is recorded or exempt.
- Outermost calls only: a thread-local depth (`Recipe.state`) means DSL methods calling DSL methods inside the library leave no records.  A call returning a new object stores a `Recipe::Call` (receiver, name, args, kwargs, block, block kind, invocations, scope, seq, seeds, lane, statements) in the object's `@graph_recipe` `Record`; a call returning its receiver appends to the record's configuration list (`Tone#sine`, `#at`, `#named`; not for Pitches, which are values).  An object returned again in another block scope (a channel-wide `v.cc(1)` shared by every lane, a delay pipeline's wet node returned by the delay) gets that scope's call in `Record#scoped`.  The record's owner check ignores records copied by `dup`; `Record#marshal_dump` is nil, so filter objects Marshal-copied per channel carry an empty record.
- Aliases share one recorder (so `instance_method(:additive) == instance_method(:harmonics)` stays true); the recorded name is `__callee__`, the spelling the code used.  `#coerce` only raises the depth (`0.5 * node` records the Constant's `*` and prints as `0.5 * node`).
- Build blocks (`BUILD_BLOCKS`: `synth`, `feedback`/`fb`, `delay`/`feedback_delay` inserts, `unison`, `swarm`, `oversample`, `.new`) are wrapped: each call of the block runs at depth 0 as user code and becomes an `Invocation` (args, result, the block's locals read by a `TracePoint(:b_return)` targeted at the block, whether anything drew a seed, statements).  The wrapper proc answers `arity`, `parameters`, `lambda?`, and `source_location` like the block.  Delay insert pipelines record `d.fb { }`/`d.wet { }` as statements of the delay's block (`PipelineRecording` on `InsertPipeline#set_fb`/`set_wet`).  Runtime blocks (`proc`, `spy`, schedules) are never wrapped.
- Bundle channel access (`bundle[i]`, `left`, `right`, `l, r = bundle`, `map`, `each`, `outputs`, `channels`, ...; `ELEMENT_ACCESS`) notes the channels of a recorded bundle as `bundle[i]` and runs at the caller's depth, so `map` blocks stay user code.
- Seeds: `MB::Sound.next_seed` (`SeedRecording`) adds each seed drawn during a recorded call to the call, and marks the build block invocation it ran in.  Synth lanes draw from `with_seed(seed + lane)`, so calls inside lanes (`Call#lane`) don't print seeds; the synth prints its `seed:` when a lane drew one.
- `Recipe.enabled = false` / `MB_SOUND_RECIPES=0` turns recording off (for measurements).

## Printing (`recipe/ruby_writer.rb`, `RubyWriter`)

- Objects used more than once, named by a block local, captured by a block from an outer scope, or (two or more in a scope) drawing random seeds become variables, in the order of their last recorded touch (seeded objects in creation order); everything else stays a chain.  Variable names come from block locals, else the method name (`filter`, `softclip`), with `_` appended for names that would shadow recorded top-level methods or Kernel methods.
- Operators print with precedence-based parentheses; unary minus literals are parenthesized as receivers.  Unrecorded Constants print as numbers in arithmetic (`0.5 * x`) and as `N.constant` elsewhere, with live values (queued `constant=` changes, Multiplier/Mixer `constant=`) winning over recorded ones.
- Values in their units: `100.ms`, `96.samples`, `lfo.samples`, `1.oct`/`7.st`/`50.cents` (the Interval's own unit, checked to rebuild exactly), Durations (`1.n16.dotted`, `1.n8.triplet`, `3.n16`, `2.bars`; else `k.nN`), Phases, Notes (`A3`) and Pitches (`440.hz`), floats exactly k/10 dB as `k.db`, `per_channel(...)` for ChannelValues/ChannelSpread, `Wavetable[:name]` for library tables, `Klass.new(field: ...)` for Data values (`MIDI::ControlSpec`), class names relative to MB::Sound.
- Build blocks print with their parameter names.  Several invocations (synth lanes, unison copies) print once: each lane is printed with its literal values as numbered slots, and if the skeletons match, slots that differ become `per_voice(a..b)` (when the values spread evenly; synths only) or `per_voice(x, y)` (the shortest repeating list); lanes that differ in structure print lane 0 with a warning (decision 10's "lane 0 + warning"; unrolled per-lane blocks were not built).
- Runtime blocks print as their source text, found with Prism from `source_location` (a call name picks among several blocks on one line); a block that reads local variables of the code around it gets a FIXME naming them (`grain_repeater`'s `p`).
- Seeds print as `seed: N` where the method takes one.  When any call drew a seed that can't be printed (a method without `seed:`, or several seeds: unison copies' phases, chorus hiss, tr808), no seeds print at all and a warning says rebuilds match only in the same order after the same `MB::Sound.seed` (mixing printed and drawn seeds would shift the draw order).
- Free inputs (unrecorded objects that aren't values) are named from `inputs:` or automatically (`midi` for Notes, `clip`, `input`), listed in a `# inputs:` header; their channels print as `input.outputs[i]`, a recorded bundle's as `bundle[i]`.  Inputs of classes defined outside `lib/` get a FIXME.
- Anything unrepresentable prints as `nil` with `# FIXME(graph-io): ...` at the end of its line and in the header (NArray data, sample-made wavetables, procs without source).
- No flow control: the output is literals, unit methods, recorded DSL calls, local variables, and build blocks, the subset phase 2 will read with Prism (no eval).

## Coverage (2026-10-10)

- Graph sweep: 193 of 196 factories rebuild bit-identically from their printed code (after a different root seed unless the code warns about seeds); not representable: `wavetable sample mode reset` (sample-made table), `ArrayInput` (NArray), `MixSource` (a node class defined in the spec).  `spec/lib/mb/sound/graph_node/recipe_spec.rb`.
- bin/ scripts (`spec/bin/recipe_script_sweep_spec.rb`, `:smoke`, each script in a fork with c_major.mid / arp_a7.flac): 22 of 27 synth and effect scripts bit-identical, including drums_808 (ControlSpecs print as Data), multitap_delay (`Mixer.new`), tape_delay (per-channel lambdas print twice, once per channel), reverse_delay's bundle taps; not representable: grain_repeater and reverse_delay (proc blocks reading outer variables), fm_chain (script-local node class), sq80_voice and wavetable_bass (built wavetables).  The prototype's YAML round trip had 20 of 27.

## Cost

Measured 2026-10-10 (container, alternating on/off runs in one process, `Recipe.enabled`; noisy, other work running):
- Graph build, best of 9: fm_bass on c_major.mid (oversample 4, 225 recorded calls) 72.6 vs 72.1 ms (+0.7%; medians +3.5%); sq80_voice on dense_modulated.mid (8 voices, 323 calls) 132.7 vs 130.5 ms (+1.6%); a 16-voice synth of 40-node lanes (2594 calls) 349 vs 329 ms (+6.2%; medians -1%).  The prototype measured ~8% on fm_bass.
- Worst case, a loop of cheap DSL calls on one node (`x.softclip`, `x.aclip(-1, 1)`): +3.6 to +4.9 us per call (+21 to +24%), about half of it GC (with GC off +2.5 us, +19%).  Recording a call allocates a Call (160 B), a Record (80 B), and its args/kwargs (~200 B): ~0.4-1.5 KB per call by `memsize_of_all` deltas (fm_bass +224 KB, sq80_voice +476 KB, the 16-voice synth +1.8 MB), mostly kept alive by the graph anyway.
- Sampling is unchanged (nothing records at sample time): 200 x 512-sample buffers of a 100-node chain built with and without recording, 64.5 vs 63.5 ms (best of 5).  Inner DSL calls made inside the library pay only the recorder's argument splat and a thread-local depth check.
- Rerun by toggling `MB::Sound::GraphNode::Recipe.enabled` around graph builds in one process (alternating), e.g. `MB::Sound.fm_bass(MB::Sound::Notes.new('spec/test_data/c_major.mid'))` after loading `bin/synths/fm_bass.rb`.

## Decisions (maintainer, 2026-10-10)

1. Basis: recorded outermost DSL calls with introspection as fallback, now; long term "both, split at the library boundary" (declared-parameter library nodes plus recorded project builders), a later project.
2. Text format (phase 2): "Ruby for now, with the hope of a declarative diffable graph long term": saved files will be a Prism-parsed Ruby subset (no eval), which `to_ruby` already prints.
3. Saved patches follow library changes.  4. Recording always on.
5. Runtime blocks: safe-subset blocks, a named registry, and opt-in `trust: :code` later (phase 2); phase 1 prints Prism source with FIXMEs.
6. Names: console `ruby node`, `node.to_ruby`; `.mbg.rb` files and save/preset/presets are phase 2.
7. No flow control in printed code; optional repeat/spread syntaxes instead (`per_voice`, `per_channel`).
8. Script params become `params:` in phase 2 (phase 1 prints them as `1.0.constant.named("drive")`).
10. Lanes that differ: `per_voice(list | range)` (built, see MIDI notes) and `per_channel(list | range)`.

## Not yet (phase 2 and later)

- Loading (Prism subset reader, registry of recorded names), `.mbg.rb` files, save/preset/presets, `params:` from script parameters and `p.midi_cc`.
- Per-channel collapse (tape_delay's per-channel lambda prints once per channel), structural lane differences unrolled per lane, wavetable/sample assets, clips as event lists, sessions, state.
