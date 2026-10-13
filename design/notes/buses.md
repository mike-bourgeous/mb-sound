# Buses, sends, and bus sidechains

Branch buses-1 (2026-10-13).  The maintainer queued "Buses, sends, bus sidechain" (persona consensus B; Kez Volta asked for `duck(:drums, only: :kick)`; earlier: longer delay and reverb tails should come through "future effect sends" rather than delay discovery).  CLAUDE.md keeps a summary and points here.  Update both when behavior changes.

## API

```ruby
bus :verb { |sig| sig.reverb(:hall, mix: 1) }       # a named bus: its own effect chain, into the master
bus :slap, to: :verb { |sig| sig.delay(1.n8) }       # into another bus (no cycles)
bus :drums { |sig| sig.compress(threshold: -18.db) } # a group bus
track :keys, send: { verb: -12.db } do |c| ... end   # sends (post-fader), per player name
track :kick, to: :drums do |c| ... end               # the track's main out goes into a bus
bg :pad, graph, send: { verb: -6.db, slap: :space }  # bg too; a knob name follows the knob
feed :keys, :verb, -6.db, over: 2, on: :bar          # change a send (journaled, undoable)
feed :keys, :verb, 0                                 # off
bass.duck(:drums)                                    # sidechain from a bus or a track
bass.duck(:drums, only: :kick)                       # one named output inside a track's graph
pad.compress(sidechain: bus(:drums))                 # bus(:name) reads a bus or track anywhere
mute :verb; solo :verb                               # buses are strip names
buses                                                # listing
render 'x.flac', stems: 'stems/' { ... }             # one stem per bus too
```

## Decisions (agent's, open to the maintainer's review)

- **Names.** Buses share the Session namespace with tracks, groups, and knobs (`Names#claim(name, :bus)`), so a bus can't be named like a track; `:master` stays reserved.  `send` is `Object#send` (every object, used all over the library), so the console command is `feed` (alias `send_level`); `send:` stays the keyword on `track`/`bg`.
- **The bus is a master-like chain with its own input.** A bus reuses `Session::Master`'s chain machinery (`Chain`, `build_master`, spill/fade/cut handover): the block gets the bus input as a bundle (one parameter) or per channel, `bus :verb { ... }` again swaps the chain at a launch point with the old one spilling over (or `fade:`), and undo rebuilds the previous chain from its block (`:bus` changes, `BusState`).  Bus chains are installed as plans like players (`Plan.install`): the `MixSource` channels are boundaries, the chain behind them fuses.
- **Routing belongs to names**, like mute flags: a graph replacing `:keys` keeps its sends.  Each player has a main out (the master, or a bus with `to:`) and any number of sends.  Sends are post-fader: after the fade ramps and mute/solo (contract K7's order: fade, gain, mute/solo, then routes), so a muted or faded track sends nothing, and a ringing-out track keeps sending its tail.  Armed monitors (`:"lead/live"`) use their track's routes.
- **Send levels** are linear gains (`-12.db` reads as its gain) or a knob (a name or `knob(:x)`) to follow.  Internally each send is an unregistered `GraphNode::Knob` advanced with the Session's knobs, so ramps land on exact frames at any buffer size, `over:` takes bars, Durations, or Lengths with any `curve:`, and undo restores the level the same way knob turns do.  Ramps are linear in gain, like every fade.  `feed` lands right away (with the knob glide) unless given a launch point.  Negative numbers raise (write `-6.db`).
- **Order.** Each span renders players and buses in dependency order: a player before the buses it feeds, a bus before the bus it feeds, any source before a graph that reads it (`bus(:x)`, `duck(:x)`).  Ranks come from the longest path; equal ranks keep the existing order, so sessions without buses or readers render exactly as before (the same summation order).  A cycle goes through `live_error` when it is made (`bus`, `track`, `bg`, a reader added) and is broken at render time (the reader gets silence) if one appears anyway.
- **Readers** (`GraphNode::BusTap`): `bus(:name)` is a bundle of the Session's channels; `bus(:name, only: :kick)` is mono.  They read the current span's signal of their source: a bus's output (after its mute), a player name's output (after fade and mute, before routing), or with `only:` a node inside the named track's graph (a drum `Voice` named like it, or a node given `.named(:kick)`), read through a spy as the track renders (before the track's fade and mute: it's the voice itself).  Exact at any buffer size (the source renders first in the same span).  A reader outside a Session reads silence.  Readers are plan boundaries for now.
- **Mute and solo.** A muted bus sleeps (its senders' sends are dropped, their direct sound is untouched).  Solo is solo-in-place through the routing: a soloed track keeps the buses it feeds audible (so its reverb stays), and a soloed bus keeps the tracks feeding it audible (dry too: a track's sends and main out are one strip).  Tracks sending to the same bus that aren't soloed are silent as usual.
- **Tails and sleep.** A bus processes while anything is sent to it and rings out after its senders stop, sleep, or ring out, so delays and reverbs on buses finish on their own (no delay discovery).  It sleeps once its input and output have both stayed below `Master::TAIL_THRESHOLD` (-90 dB) for `TAIL_QUIET_SECONDS` (1 s), checked on the 800-frame session grid (`Synth::SKIP_GRID`), and wakes on the exact frame its input reaches the threshold, so output and CPU decisions are the same at any buffer size.  No cap: a frozen reverb rings until muted.  `render` keeps rendering after the last player until buses and master chains are quiet (as before, at most `MAX_TAIL_SECONDS`).
- **Stems.** A track's stem is its main out (what it plays dry, wherever it goes); a bus's stem is its output.  With every main out on the master and every bus into the master, stems still sum to the mix before the master chain; tracks routed `to:` a bus are in their own stem and in the bus's.
- **The master gain** applies to the sum of players' main outs and bus outputs (pre-chain by default), as before.

## Later

- Pre-fader sends; sends from buses (buses have only `to:`); latency compensation for buses with lookahead; scene keys for send levels (sends following knobs cover scenes today); saving buses in set documents (graph-io); per-bus gain faders (the block can scale); bus readers in plans (`p.param`).
