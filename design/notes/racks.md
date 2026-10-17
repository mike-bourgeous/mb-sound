# Racks, typed ports, and the inspection protocol

Branch racks-r1 (2026-10-17): phase R1 of the racks proposal (research spike `research-racks`, `research/racks/PROPOSAL.md` + `README.md` + `survey/`; the maintainer approved the design 2026-10-17: "Racks look good; go ahead").  The proposal's section 0 holds the twelve decisions; section 7 the build order (R2 macros and documents, R3 slots and live swaps, R4 MIDI parity, R5-R8 crossings and pitch shifting, V visualization).  CLAUDE.md keeps a summary and points here.  Update both when behavior changes.

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
- Anonymous racks round-trip through `GraphIO.dump`/`load` bit for bit (spec: an effect, a sidechain-port rack bound with `with`, an optional port, an instrument rack on a clip).  A graph using a named rack prints `rack(:name)`, which loads only where that rack is defined; rack documents themselves (`save :dub, rack(:dub)`, format 4) are R2.

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

## Not in R1

Macros (`macro`, R2), rack documents and format 4 (R2), slots and swaps of racks (R3), zones, Hash matchers, `within`/`sometimes`, MIDI feedback (R4), crossings (R5-R8: `follow`, `onsets`, `pitch_track`, `pitch_shift`), owner groups, the Plot panel registry, `view`/`lanes`, and UI panes (V; panes belong to the UI work).

## Demo

`bin/songs/rack_demo.rb`: an `mrack` (arp + echo) feeding an `irack` (a pluck instrument), an `arack` with a sidechain port pumping a pad from the kick track, and a bass through a named effect rack; `--print` prints the racks and the graph's Ruby.
