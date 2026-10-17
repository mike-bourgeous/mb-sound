# Racks, typed ports, and the inspection protocol

Branch racks-r1 (2026-10-17): phase R1 of the racks proposal; branch racks-r2 (2026-10-17): phase R2, macros and rack documents (sections "Macros" and "Rack documents" below) (research spike `research-racks`, `research/racks/PROPOSAL.md` + `README.md` + `survey/`; the maintainer approved the design 2026-10-17: "Racks look good; go ahead").  The proposal's section 0 holds the twelve decisions; section 7 the build order (R2 macros and documents, R3 slots and live swaps, R4 MIDI parity, R5-R8 crossings and pitch shifting, V visualization).  CLAUDE.md keeps a summary and points here.  Update both when behavior changes.

## API

```ruby
wobble = mrack { it.arp(:up, 16).echo(3.n16, 2, pitch: 7) }   # anonymous: a value, like a Proc
bg :keys, midi.then(&wobble).synth { |v| v.hz.saw * v.amp_env }
wobble.(clip); clip.stream.through(wobble)                     # other ways to apply

arack :dub, side: :audio do |sig, side:|                      # named, with a sidechain port
  sig.duck(side).delay(3.n16, feedback: 0.4, wet: 0.3)
end
bg :bass, bass_line.then(&rack(:dub).with(side: :drums))      # a bus or track name as a value
rack(:dub).(bass_line, side: kick)                            # or bound at the call

irack(:keys) { |stream| stream.synth { |v| v.hz.triangle * v.amp_env } }   # notes in, audio out
lrack(:level) { |sig| sig.abs.filter(:lowpass, cutoff: 10) }  # audio in, notes or control out (alias amrack)
modrack(:wobble) { |ctl| ctl * 0.5 + 0.5 }                    # control in
rack(:sc, in: :auto) { |sig, keys:| ... }                      # types from parameter names (prints them)

dreamy = wobble >> mrack { it.humanize(1.n64) }               # Proc#>> order
lead.stream + pad.stream                                       # note streams merge with +
racks                                                          # name => "effect audio(sig) + audio(side) -> audio, 1 use (in :bass)"
rack(:dub).to_ruby                                             # its definition
```

Full-word aliases: `note_rack`, `audio_rack`, `instrument_rack`, `listener_rack` (and `amrack`), `mod_rack`.

## Model

- **`MB::Sound::Rack`** (`lib/mb/sound/rack.rb`) is a frozen value: name (or nil), main input port, extra ports, declared output type, bound port values, the block, and the constructor name (for printing).  It answers `call`/`.()`/`[]`, `to_proc`, `>>`/`<<` (composed racks keep their parts and apply them in order), and `with` (a new Rack with ports bound).
- **Kinds** come from the main input and the output: `:note_fx` (notes -> notes), `:instrument` (notes -> audio), `:effect` (audio -> audio), `:listener` (audio -> notes/control; `lrack` always), `:modulator` (control -> anything).  Extra ports never change the kind.  When `out:` isn't declared, a rack's kind is its input's default (`mrack` :note_fx) until a named rack's listing has seen an application's output.
- **Constructors** (`MB::Sound::RackMethods`) fix the main input's type: `mrack` notes, `irack` notes with `out: :audio`, `arack` audio, `lrack` audio as a listener, `modrack` control, `rack(name, in:, out:)` the general form.

## Ports

- Three types (`GraphNode::Traversable::PORT_TYPES`): `:notes`, `:audio`, `:control`.  Port declarations are `Rack::Port::Notes`/`Audio`/`Control`; each coerces values given to it and explains wrong-domain method calls.
- **Extra ports** are keywords of the constructor call naming their type (`keys: :notes`) and keywords of the block (`|sig, keys:|`).  A keyword on one side and not the other raises when the rack is defined, with did_you_mean (`|sig, key:|` against `keys: :notes`).  A block keyword with a default makes the port optional (`|sig, depth: 0.5|`; listed as `control(depth)?`).
- **Binding**: `with(keys: midi)` returns a new rack; ports passed at the call merge over it.  An unbound required port goes through `MB::Sound.live_error` (scripts and specs raise naming the port; live, the input passes through unchanged).
- **Coercion** (decision of this branch): notes ports take Streams and Notes as they are, Clips as `clip.notes` (so every stream transform and every voice signal works inside; the recipe prints `clip.notes.then(&r)`), and Sources as Streams; audio ports take nodes and bundles, Arrays of nodes as bundles, and Symbols as `bus(:name)` (a bus or track); control ports take nodes, numbers as constants, and Symbols as `knob(:name)`.  A Notes input to a note rack gives a Notes back (a Stream result is wrapped), so console `midi` stays usable as one voice.
- **Stand-ins**: the proposal's typed stand-ins are the bound values themselves, after coercion.  Building happens at each application, when the values are known, so no pass-through node sits at a port: plans fuse across rack edges (proposal 2.9), and `arack { it }.(x)` returns `x`.  The typing shows up where it helps: a NoMethodError on a port's value is re-raised with the port's type (`stream is a notes port: streams carry notes; .synth makes audio, .notes gives one voice's signals`; `sig is an audio port: audio carries samples; arp is a note transform (it needs a notes port)`), with Ruby's own did_you_mean suggestions kept.  Wrong-type values raise TypeError naming the port and the crossing (`notes become audio through .synth`).
- **Output check**: `out:` (given, or implied by `irack`/`lrack`) is checked against the block's result: notes vs. sample streams (audio and control are both sample streams, so an `arack` may return a control-like node).  Failures go through `live_error`.
- **`in: :auto`** (decision 7, opt-in) reads the types from parameter names (`stream`/`midi`/`keys`/`notes`/... notes; `sig`/`audio`/`input`/`side`/... audio; `ctl`/`control`/`mod`/`depth`/... control; `AUTO_TYPES`), prints `# rack :sc inferred audio(sig, keys: notes) -> ?`, and raises for names it doesn't know and for `it`/`_1` blocks (nameless parameters).

## Named racks

- `Session::Racks` (`session/racks.rb`): a name claims the Session namespace as kind `:rack` (`Session::Names`; a collision with a track, bus, or knob goes through `live_error`).  `rack(:x)` looks one up (KeyError with did_you_mean).  Defining a name again replaces the rack for later applications; instances already playing keep their graphs (live swaps of racks and slots are R3).
- `racks` lists name => "kind signature, uses (in :player, ...)": each application is remembered weakly, and "in" names the current players whose graphs hold an instance (a Notes instance is found through its stream).

## Recipes and graph documents

- A rack's constructor isn't recorded (a Rack prints itself: `Rack#to_ruby` gives its constructor call and block source).  An application is: `Rack#call` records a Call `src.then` with the rack as its argument and the rack's block as a build block (`Recipe.call(..., kind: :build)`; build block wrappers now pass keyword arguments, recorded after the positional ones).  `RubyWriter#rack_text` prints it as `src.then(&rack(:dub))` for named racks and `src.then(&arack { |sig| ... })` for anonymous ones, the block printed from the application's recorded body with parameters named after the ports (so `it` blocks print with names), bound ports as `.with(side: ...)`.
- The constructor names are in `Recipe::BUILD_BLOCKS` (so the graph document loader builds their blocks as document code) and in `GraphIO::Registry::TOP_EXTRA`; the registry allows `then` on graph values, Notes, Clips, and Streams, and `with`/`>>`/`<<` on racks; `Loader#call_block` takes a Rack as a block argument (`to_proc`); build blocks in documents may take keywords (required, or with defaults evaluated in the block's scope).
- Anonymous racks round-trip through `GraphIO.dump`/`load` bit for bit (spec: an effect, a sidechain-port rack bound with `with`, an optional port, an instrument rack on a clip).  A graph using a named rack prints `rack(:name)`; since R2 graph documents also carry the rack's definition, and rack documents save racks themselves (below).

## Note streams merge with `+`

`MIDI::Stream#+` and `Notes#+` are `merge` (decision 4: `&` stays free for a later meaning; `Clip#&` already layers clips, so Clip has no `+`).  `Notes#+` is recorded and prints as `a + b`.

## Typed ports on every Traversable (the inspection protocol, proposal 5.3)

- `port_info` => `{ in: [{ name:, type:, role:, source:, active: }], out: [{ name:, type: }] }` on every Traversable.  `port_type` is the output type: `:audio` for graph nodes, `:notes` for MIDI streams, sources, transforms, allocators and their lanes, `:control` for constants, knobs, knob readers, and Notes nodes (gate, number, velocity, ...).  `Traversable.port_type_of` covers numbers (control), Clips, Seqs, and Notes (notes), which aren't Traversable.
- Roles: `:main` (inputs named input, channel_N, voice_N, stream, ..., `MAIN_INPUT`; and every edge from a multi-output node to its own output), `:side` (`side`, `sidechain_N`), `:param` (everything else), `:feedback` (`feedback_sources`).  A parameter edge is `:control` whatever feeds it (an audio node read as a parameter); a notes source makes a `:notes` edge.  Drum kits read every voice as a main input.  `port_role(name)` and `port_active?(name)` are the hooks classes override.
- Multi-output nodes list `:out_1`, `:out_2`, ...; nodes with side outputs (`GraphNode::Ports`: Tone `wraps`/`increment`, TempoNode `jumps`) add them after the main output as `:control` ports with descriptions and `in_use` (Ports#port_info used to return only these, as an Array).
- `#sources` and `#inputs` keep their return values.  `port_info_spec` checks every node of every graph sweep factory.
- `params` (generic, for graph code on the build thread): a node's `:param` inputs by name, constants as numbers, other nodes as given (through Tees to the node itself).  ChannelMixer keeps its own `params` and adds declared ranges.  Dynamics' and Limiter's kernel setting vectors were also called `params`; they are `kernel_params` now, so `params` means one thing.
- For painters and other threads (the Mac UI owner's contract, `/app/tmp/briefs/ui-rack-contract.md`, 2026-10-17): `param_info` is a frozen Hash `{ name => ParamValue }` and `param_snapshot` one deep-frozen (Ractor-shareable) `Params`; both read settings only (no sampling, no render lock), so UI::Poll can take them about 4 times a second.  Shapes:

  ```ruby
  GraphNode::Traversable::ParamValue = Data.define(:value, :type, :unit, :range, :label, :detail)
  #   value:  Numeric for constants and knobs (the knob's current value); nil when another node drives it
  #   type:   :control (or :notes for a notes edge)
  #   unit:   frozen String or nil ("Hz", " Q"); range: frozen Range or nil
  #   label:  a knob's name (Symbol) or a named node's name (String), else nil
  #   detail: frozen String describing the driving node or knob, or nil
  GraphNode::Traversable::Params = Data.define(:node_class, :name, :values, :preview)
  #   node_class: the node's Class; name: frozen String or nil (unnamed)
  #   values: frozen { Symbol => ParamValue }; params[:cutoff] is values[:cutoff]&.value
  #   preview: frozen Hash of what a preview needs (#preview_data) or nil
  ```
- Previews: `Plot::Panels.preview(klass, params, chart)` is a pure function of a `Params` snapshot (`Plot::Panels.register('Class::Name') { |params, chart| ... }`, inherited by subclasses), drawing through the chart layer (ChartBuilder marks and scales; every renderer, text cells included; never preformatted ANSI).  `node.plot_preview(chart)` is the convenience that takes the snapshot and calls it; `Plot.preview(node)` returns a Chart or nil.  Registered: filter nodes (`Filter::SampleWrapper` over an SVF or cookbook biquad; `preview_data` gives structure, type, sample rate, and cutoff/quality/gain with constant and knob inputs at their current values; the dB response on a log frequency axis) and shapers (mode and parameters; the transfer curve over -2..2).
- `spy(snapshot: true)`: `:post` spies get `buf.dup.freeze` of each buffer (the NArray class the node returns, usually Numo::SFloat; one buffer long; one copy shared by the node's snapshot spies; nil when the node ends), for planned nodes too (`Plan::Op::Tap` calls the same spies).  No frame number rides along (a spy inside a Session render can read `Session.span`).
- `MIDI::Stream#spy { |event, stamp| }` (with `handle:`, `clear_spies`): every event the stream reads, once however many readers it has.  `event` is the `MIDI::Event` the readers share (frozen Data: `type, channel, note, value, velocity, raw, bytes` (frozen String), `time` (Rational stream seconds), `bend_range, legato, pitch, flam, length_hint` (a Duration or nil); not `Ractor.shareable?` only because Durations aren't frozen); `stamp` is a `Session::Stamp` (frozen Data: `frame` Integer, `pos` Rational whole notes, `bar_length, meter_pos, meter_bar`; `#bar`, `#beat`, `#to_s` "bar:beat") of the frame it lands on while a Session renders, nil outside one.  Sessions publish the span being rendered on the render thread (`Session.span`, a reused `Session::Span` with `frame`, `pos`, `per_sample`, `moving`, `sample_rate`, and `#stamp(offset)`); a stream counts offsets from the first stream time it reads in each span (readers read whole spans).  Taps stamp with the Session clock, never with draw time (proposal 5.4).

## Agreed follow-ups for phase V (the UI owner's contract)

- Taps as data: `Session#tap(node_or_stream, kind: :audio|:control|:notes, window: frames)` returning a handle with `#close`; the render thread fills bounded per-tap rings inside the render lock, and UI::Feed copies them into the frozen Snapshot only when the painter took the last one (records: id, type, first_frame, a frozen SFloat or frozen Events with exact frames and positions).
- Static vs. dynamic: `Plot.graph` and the lanes Figure split into a layout built once (ranks, boxes, wire paths, scale domains, time window) and per-frame updates from snapshot data; a `structure_version` counter (Session/graph/rack epoch) bumps on graph and rack changes.
- Rack pane data: a frozen `RackInfo` per instance through UI::Poll (name, ports from `port_info`, latency, macros, slots); pane actions only through public commands.
- `Mark::Notes` and every panel draw through Plot's cell layer; changes to `Plot::Live`, `UI::Feed`, or `UI::Snapshot` go to the UI branch owner as a struct/API or a patch.

## Macros (R2)

```ruby
arack :dub do |sig|
  space = macro :space, 0.35, description: 'Echo level and feedback'
  tone = macro :tone, 2400, range: 600..8000, curve: :exp, unit: 'Hz'
  sig + sig.delay(3.n16, feedback: space * 0.7, wet: space, dry: 0).filter(:lowpass, cutoff: tone.mod(0.13.hz.lfo, depth: 0.15))
end
turn :"dub/space", 0.7, over: 2.bars
rack(:dub).snap :wide; recall :"dub/wide", over: 1.bar, only: [:space]
```

- `macro(name, default, range:, curve:, unit:, cc:, takeover:, smooth:, share:, follow:, description:)` (`RackMethods#macro`) works only inside a rack block: it makes a `GraphNode::Knob` carrying a `Rack::MacroInfo` (rack, macro name, the `Rack::Application` of this `Rack#call`, share, follow, description).  `Rack#call` runs the block inside a thread-local Application (`Rack.applying`/`Rack.application`), so macros know their instance.  Asking again by name (`macro(:space)`) or with the same definition returns the same knob (printed racks repeat `macro(...)` at each use); a different definition raises.
- Being knobs, macros get `turn`/`over:`/`learn`/`cc:`/snapshots/takes/undo/plan params (`p.param`)/ACID XML unchanged.  `Knob#mod(source, depth:)` (any knob) is baseline plus modulation in the knob's scale (octaves for exp knobs; depth in fractions of the range), limited to the range, built from graph arithmetic and `aclip`, so plans fuse it; recorded and allowed in documents.
- Names (maintainer decision 8): macros are standalone knobs until a graph using them is adopted (`Session::Knobs#adopt_knobs(sound, player:)`; `bg` and `Session#add` pass the player name).  `Session::Racks#macro_names` keys each instance `[player, ordinal]` (ordinal among applications of that rack in one graph): `:"dub/space"` while one key uses the rack; from the second key on, every instance is per player (`:"bass/dub/space"`, `:"bass/dub.2/space"`; without a player `:"dub.1/space"`), and the first key's knobs are renamed (`Knobs#rename_knob`: value, readers, and snapshot entries kept; live mode prints the rename).  The same player playing the rack again joins its own knobs (keeping the value; the rack's current range and curve).  Anonymous racks' macros belong to the player (`:"bass/space"`, without a player `:"rack/space"`).  Once per instance, the short name (`:"dub/space"`) is a group (`Session::Names` kind `:macro_group`, `Racks#macro_group?`/`#group_members`): `turn :"dub/space", 0.6` turns every instance's knob (one journaled turn each, one undo step; round 2, maintainer 2026-10-17).  Instances of players that are gone (forgotten: not playing, not stopped for `resume`, not queued to start, not an arrangement track) are dropped when graphs join and on `forget` (`Knobs#prune_macros`, `Racks#prune_macro_instances`): their knobs leave the session and its names; a rack left with no instances goes back to plain names and its groups are released.  Stopped players keep theirs (resume, scene relaunches).
- `share: true` makes the macro knob `:space` itself, joined to (or becoming) the Session knob through the usual adopt rules (another range or curve: `live_error`).  `follow: :space` starts `Knob#follow` of that Session knob when the macro joins, mapped position to position (`Spec#positions`, clipped to 0..1) into the macro's range and curve; a missing knob is a `live_error`.  Turning the macro ends the follow, like any knob.
- Snapshots: `rack(:dub).snap :wide` is `snap :"dub/wide", knobs: <the rack's macro knobs, every instance>` (`Session#snap(knobs:)`, `KnobMethods#snap(knobs:)`); `recall` takes `only:`/`except:` with knob names or macro names (`:space` matches any knob whose last path part is `space`; a name in `only:` matching nothing raises); `Rack#recall`, `Rack#macros`.
- Printing: a macro knob prints as `macro(:space, 0.35, ...)` (its held value) wherever it is used (`RubyWriter#macro_text`, `RubyWriter.knob_args`), never as a document knob line, so graphs with anonymous racks round-trip bit for bit.

## Rack documents and format 4 (R2)

- `save :dub_echo, rack(:dub)` / `GraphIO.dump(rack)` (`GraphIO::RackWriter`) builds the rack once on stand-ins for its ports (`Rack#build_on_stand_ins`: a zero Constant for audio and control ports, an empty-clip Notes for notes ports; the block's calls are recorded as top-level calls, not as an application) and prints:

  ```ruby
  graph 4, name: "dub_echo", kind: :effect, rack: :arack, saved: ..., description: ...
  inputs sig: :audio                  # main port first; optional ports [type, default]
  outputs :audio
  knob :space, 0.35, description: "Echo level and feedback 0..1"   # the macros (share:/follow: allowed here only)
  knob :tone, 2400.0, range: 600.0..8000.0, curve: :exp, unit: "Hz", description: "Echo lowpass"

  sig + sig.delay(3.n16, feedback: space * 0.7, wet: space, dry: 0).filter(:lowpass, cutoff: tone.mod(0.13.hz.lfo, depth: 0.15))
  ```
  Optional ports' defaults come from the block's source (`Rack#port_defaults`, Prism; R1 printed them as nil).  Composed racks aren't saved (DumpError).
- `GraphIO.load` of a rack document (`Loader#load_rack`) returns a Rack named after the document, whose block walks the body per application with the ports and the knob lines' macros (made with `macro`, so named and shared like any rack's) bound through `Scope#bindings`; given inputs, the Rack applied to them.  It re-saves to the same text and applies bit-identically to the original.  The Document is remembered per Rack (`GraphIO.rack_document`).
- `preset :dub_echo` returns the Rack, defined in the Session under its name; `preset :dub_echo, sig: mic, side: :drums` the applied instance (its macros join the session).  `presets` lists racks with typed inputs and macros.
- Graph documents carry the definitions of the named racks they apply (`RubyWriter` option `define_racks:`, used by `GraphIO::Writer` and `RackWriter`; `RubyWriter.rack_definition` prints a rack from a stand-in build: every port a parameter (optional ones with their defaults), macros as `macro(...)` at their defaults, seeds left out so each application draws its own (round 2: definitions used to print from the first application's body, which baked in unbound optional ports' defaults); nested racks first, before the graph): `arack(:dub, side: :audio) { |sig, side:| ... }`.  The same rack always prints the same definition, which is how loading compares (`GraphIO.place_rack`, round 2, maintainer 2026-10-17; no subgraph namespaces): no rack of that name in the session defines it; the same printed definition uses the session's silently; a different one is a `Rack::Conflict` (name, both racks, source, `rename_to`, `options` `[:session, :saved, :rename]`) settled by `racks:` (`GraphIO.load`, `preset`), else by the choice a replaying take recorded (`Take.note_choice`/`.replay_choice`; take lines save `choices: [[:rack, :dub, :rename]]`), else in live mode by `GraphIO.rack_conflict_handler` (default: `Conflict#ask`, a one-line console prompt when stdin is a terminal; the tiled UI's picker can replace it), else `live_error` (scripts, specs, renders raise; live without an answer keeps the session's).  `:session` keeps the session's rack, `:saved` replaces it (`Session::Racks#replace`, one undo step through `note_undo_extra`; later applications everywhere use it, instances playing keep theirs until R3), `:rename` defines the saved copy as the next free name (`:dub_2`, `Racks#free_name`) and points only this document's `rack(:dub)` at it (printing the name).  A bare `rack(:name)` with no definition in the document resolves to the session's rack, else a rack document of that name among the presets (`Loader#rack_reference`), else a LoadError.  `preset :dub` of a rack document settles the same way.  Bundles hold the definition the same way (inline only; maintainer 2026-10-17).
- Format 4 for every document: typed inputs (`inputs midi: :notes`; old `inputs :midi`/`:input` load unchanged as notes/audio, `Document#input_types`), optional `outputs`.  The library presets were saved again (only the graph and inputs lines changed).

- Exact reloads (round 3, maintainer 2026-10-17): each application builds under its own seed (`Rack#call` draws one from the root generator, bypassing the recorder, unless `Rack#using(seed:)` gives it, and runs the block in `MB::Sound.with_seed`), and graph documents print each named rack's use as `rack(:dub).using(seed: drawn_seed(N), space: 0.7)`: the seed (drawn ones as `drawn_seed`, so `seeds: :fresh` redraws them; left out in synth lanes, whose seeds derive from the lane's, and without seeds) and the instance's macros' current values where they differ from the definition's defaults (`RubyWriter#using_args`; a macro that joined a session knob reads it through `Knob#joined`; shared and following macros belong to their session knobs and aren't saved).  `using` macro values start the instance's knobs there (`Knob.new(initial:)`, the Spec's default unchanged).  The definition itself keeps defaults and no seeds.  A turned, randomized rack (noise, drift, unison) saved and loaded into a fresh session renders bit for bit (`rack_documents_spec.rb`).  Instances without a player (`preset :dub, sig: mic`, graphs loaded or built outside `bg`) are never pruned: their knobs live and die with their graph (maintainer: fine as is).

## Inspection data (R2)

- `Rack::RackInfo` (deep-frozen Data, Ractor-shareable): `name, path, kind, signature, ports` (frozen `{ name:, type:, role: :main/:side, required: }`), `latency` (samples: the longest path through nodes reporting `#latency`, e.g. dynamics lookahead and limiters, summed with `GraphNode.longest_path` (the edges `GraphNode.graph` takes, through Tees and node outputs; a guard spec checks it reaches every node of every graph sweep factory), from a stand-in build, remembered per Rack in `Rack::LATENCIES`), `macros` (the instance's knob names), `macro_specs`, `slots` (empty until R3).  `Rack#info`, `Session::Racks#rack_info` (`{ name => [RackInfo per instance with macros] }`, no render lock), `#uses`, `#output_of`.
- `help rack(:dub)` (`Help::RackPage`): kind and signature, ports, macros with ranges and their knobs, latency, uses, source.  `racks` lists macros (`macros space 0.35 (0..1), tone 2400 Hz (600..8000 exp)`).

## Not in R2

`rack(:dub).turn`-style shortcuts, separate rack files in bundles (inline only, maintainer), plan-transparent port wrappers (maintainer: ports bind values directly; a later follow-up may add wrappers), the tiled-UI conflict picker (the Mac's UI sweep, through `GraphIO.rack_conflict_handler`).

## Not in R1

Slots and swaps of racks (R3), zones, Hash matchers, `within`/`sometimes`, MIDI feedback (R4), crossings (R5-R8: `follow`, `onsets`, `pitch_track`, `pitch_shift`), owner groups, the Plot panel registry, `view`/`lanes`, and UI panes (V; panes belong to the UI work).

## Demo

`bin/songs/rack_demo.rb`: an `mrack` (arp + echo) feeding an `irack` (a pluck instrument) through the `:dub` rack (macros `:space`, opened over bars 4-6 with `turn :"dub/space"`, and `:tone` with `.mod`), an `arack` with a sidechain port pumping a pad from the kick track, and a bass through a named effect rack; `--show` prints the racks and their Ruby.  The dub rack is the library rack preset `:dub_echo` (`bin/save_presets.rb`, `LIBRARY_PRESET_RACKS`).  Listening set: `/app/tmp/listening/racks-r2/` (bench id racks-r2-2026-10-17).
