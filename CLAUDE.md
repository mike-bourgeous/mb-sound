# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

mb-sound is a Ruby library for sound processing with a fluent DSL for building signal processing chains. It is a companion to an educational YouTube video series about sound. It uses Numo::NArray (via the `numo-narray-alt` fork) for numeric operations and includes C extensions for performance-critical paths.

### Folders

- `bin/` - user-facing scripts and experiments (`bin/effects/`, `bin/synths/`, `bin/midi/`, `bin/songs/`, plus general utilities at the top level); all but `bin/sound.rb` use the script helpers (see Scripts below)
- `ext/` - C extensions for performance-critical functions
- `lib/` - Ruby code (most functionality lives here)
- `spec/` - Test suite

## Build & Development Commands

```bash
bundle install                    # Install dependencies
bundle exec rake compile          # Compile C extensions (required before running)
bundle exec rspec                 # Run full test suite
bundle exec rspec spec/some_spec.rb        # Run a single test file
bundle exec rspec spec/some_spec.rb:42     # Run a specific test line
bundle exec rake                  # Default task (runs spec)
bin/sound.rb                      # Launch interactive Pry console with MB::Sound context
```

Testing: run affected specs while working, and the full suite (about 2 minutes) before and after each merge, or more often for good reason.  Save suite output to a file and grep it instead of rerunning.  Concurrent spec processes work (per-process temp dirs and coverage files); parallelizing the suite is deliberately postponed, since slow or leaky specs are better fixed than hidden.

Spec conventions (`spec/support/`):
- Temp files: `tmp_path('name.flac')` gives a path in an empty directory per example, inside a random per-process `Dir.mktmpdir` removed at exit (`KEEP_SPEC_TMP=1` keeps it); never write fixed names under `tmp/`.
- Coverage is opt-in: `SIMPLECOV=1 bundle exec rspec` (CI sets it) reports to `coverage/`; it adds ~20% to the suite and ~30% to the smoke specs.  With it, bin/ scripts run by specs get `spec/subprocess_coverage_helper.rb` (via RUBYOPT), which writes plain Ruby Coverage per process, merged into the SimpleCov report after the suite.  If specs of scripts are slow, check `coverage/.resultset.json` isn't huge (old SimpleCov-per-subprocess growth); `rm -rf coverage` is safe.
- `fork_script(script, *args)` runs a bin/ script in a fork of the spec process (skips ~0.7 s of startup); a spec using it must also run its script once as a real process doing real work, so load-order problems still show.
- Before each example spec_helper calls `MB::Sound.close_outputs`, so cached outputs (and NullOutput pacing) don't leak between examples.  Specs that run a Session on the shared transport must `MB::Sound.rewind` afterwards.
- For limits like `Session::MAX_TAIL_SECONDS`, `stub_const` the constant where it's defined (`Session::Master::MAX_TAIL_SECONDS`) instead of rendering 10 s of tail.
- Short inputs: `spec/test_data/arp_a7.flac` is a 0.4 s stereo Am7/Amaj7 triangle arp (made by `make_arp_a7.rb`) for effect and script specs; test MIDI files start within 0.2 s.

The bin/ script smoke tests (`spec/bin/script_smoke_spec.rb`, tagged `:smoke`) run every script with `--help` and a short render; plain `rspec` skips them (they take about 1.5 minutes) and CI runs them as a separate job.  Renders run as real processes; `--help` runs in forks for scripts that also render.  Run them with `bundle exec rspec --tag smoke` before merging changes to bin/ scripts or the script runner, and add new scripts to their tables.

System dependencies (apt): `ffmpeg gnuplot-qt libsamplerate0-dev libjack-dev graphviz`

In the container, `OUTPUT_TYPE=null` is set in the Dockerfile so playback uses `NullOutput`.

## Architecture

### Core Abstraction: GraphNode DSL

The central pattern is `GraphNode` (`lib/mb/sound/graph_node.rb`), a module mixed into any class that implements `#sample`. It enables fluent chaining to build signal processing graphs:

```ruby
play 123.hz.triangle.at(-20.db)   # oscillators play until Ctrl-C
play 123.hz.fm(369.hz.at(1000)).softclip.filter(150.hz.highpass(quality: 4))
```

The DSL methods (`#filter`, `#delay`, `#softclip`, arithmetic operators, etc.) live in topic modules included by `GraphNode`, in `lib/mb/sound/graph_node/*_methods.rb`; `graph_node.rb` keeps naming, graph traversal, and shared private helpers.

Every consumer of GraphNodes must call `get_sampler` on the node(s) it stores in its constructor (e.g. `Tone#fixup_source`, `ProcNode`, `Filter::Delay` for delay-time nodes).  That branches a node used in several places through a `Tee`, so each use gets the same samples instead of advancing it twice (verified: one LFO multiplied into two branches gives both the same values).  The user is open to an alternate design later, perhaps with the stereo/multichannel wiring work.

Graph nodes maintain input/output relationships and support traversal via the `Traversable` mixin. Key node types live in `lib/mb/sound/graph_node/` (tone, noise, filter, resample, quantize, MIDI, etc.).

### Numeric Mixins

`lib/mb/sound/numeric_sound_mixins.rb` adds methods like `.hz`, `.db`, `.meters`, `.bits` to Ruby's Numeric class, enabling the fluent DSL (e.g. `440.hz.sine`, `-20.db`).  `440.hz` is a `Pitch` (`lib/mb/sound/pitch.rb`): a light frequency source whose oscillator methods (`sine`, `ramp`, `at`, `fm`, `pm`, `lfo`, `tone`/`hz`, `phasor`) make a new `Tone` each call, which plays as a full-scale sine when used directly as a signal, and which sequences can hold as a fixed frequency (`seq(C4, 440.hz)`).  `Note < Pitch` (C4 = 60) gets its frequency from the session `Tuning` (`tuning b4: 480`, live).  Oscillators run from a `Phasor` (phase in cycles; `lib/mb/sound/phasor.rb`).  `tuning` in a scheduled block changes on the block's time (`Session#at_time`).  `Sequence::NumericDurations` adds musical lengths (`2.bars`, `3.beats`, `3.n16`, `3.sixteenths`, `1.n8.dotted`) returning `Sequence::Duration`s; see Tempo sync below.

### Method Modules

`MB::Sound` extends several method modules that provide the top-level API available in `bin/sound.rb`:
- `IOMethods` - File read/write via ffmpeg
- `PlaybackMethods` - `play`, `input`, real-time audio, plus the background session:
  - `bg` / `stop` / `outro` (alias `fadeout`) / `panic` / `players` / `resume` / `stopped` / `forget` play sounds in the background through one shared `Session` (`lib/mb/sound/session.rb`) that mixes every player in a single render loop locked to the sequence timeline
  - `swap` changes the clips a player plays without rebuilding its graph; `master` (alias `master_fx`) sets master effects on the mix (see Sequences and Master effects below)
  - `visualize` (alias `vis`) plots the mix live; `render` runs a `Session` into a file; `wait` blocks until everything has ended, including master effects tails (use it at the end of scripts)
- `MultichannelMethods` - `channels`, `stereo`, `spread` build multichannel signals and per-channel arguments (see Multichannel below)
- `ScheduleMethods` - `at_bar` (alias `on_bar`) / `after` / `every` / `scheduled` / `cancel` run blocks at bars on the `Session` timeline; `bg`/`stop`/`resume`/`bpm` inside them take effect exactly at the scheduled time (see `bin/songs/scheduled_song.rb`)
- `PlotMethods` - Terminal/gnuplot visualization
- `FFTMethods` - Spectral analysis
- `ScriptingMethods` - `effect_script` / `synth_script` / `song_script` / `script` for standalone scripts in bin/ (see Scripts below)
- `GainMethods`, `WindowMethods`, `AnalysisMethods`

### C Extensions (3 native extensions, compiled via rake-compiler)

- `ext/mb/fast_sound/` - Fast waveform generation → `lib/mb/fast_sound.so`
- `ext/mb/sound/fast_resample/` - libsamplerate bindings → `lib/mb/sound/fast_resample.so`
- `ext/mb/sound/fast_wavetable/` - Fast wavetable synthesis → `lib/mb/sound/fast_wavetable.so`

### Filter System

`lib/mb/sound/filter/` contains 16+ filter types (Biquad, FIR, Butterworth, Hilbert, Delay, etc.). Filters implement `#process` / `#reset`. `Filter::Cookbook` provides standard designs (lowpass, highpass, bandpass, etc.).

### Delays

`Filter::Delay` (`#delay`) and `GraphNode::MultitapDelay` (`#multitap`) are front ends for one `MB::Sound::DelayLine` (`lib/mb/sound/delay_line.rb`): a circular buffer that grows without losing stored audio, read in C (`MB::FastSound.delay_read` / `.delay_feedback`) with Ruby mirrors (`#read_ruby` / `#feedback_ruby`) that specs check for exactly equal values.  Interpolation (`interpolation:`) defaults to `:sinc` (`DelayLine::DEFAULT_INTERPOLATION`; Kaiser-windowed, cutoff lowered by the read speed when a moving delay raises the pitch, so no aliasing up to 4x); `:cubic` and `:linear` (the old lo-fi sound) are options.  Constant whole-sample delays read directly in every mode; a moving or fractional `:sinc` delay costs ~1.5-2% of realtime per mono delay.  No mode reads samples newer than the current input.  Delay time, `feedback:`, `wet:`, and `dry:` may be numbers or graph nodes; `#delay` smooths delay changes by default (`smoothing:`), `#multitap` only with `smoothing:`.  Tools: `bin/delay_gallery.rb` (null-test cases), `bin/delay_benchmark.rb` (`--interpolation`), `bin/delay_quality.rb` (error and aliasing against an exact sine answer).

### Reverbs

Two reverb implementations coexist; use `#reverb` in most cases:

- `GraphNode::Reverb` / `#reverb` (`lib/mb/sound/graph_node/reverb.rb`) - the original from the reverb video; presets (`:room`, `:hall`, `:space`, ...).  `[l, r].reverb(:hall)` takes one input per Array element.  Stereo cost: `:hall` ~18% of realtime, `:space` ~55% (too heavy live on the user's laptop).
- `GraphNode::FdnReverb` / `#fdn_reverb` - an experiment (clean-room, by Claude Code) with `room_size`/`decay`/`damping`; ~70% of realtime each, too slow live; may be removed once `#reverb` gets similar parameters.

### Sequences

`lib/mb/sound/sequence/` (`MB::Sound::Sequence`) holds musical sequences: immutable `Clip`s of `Event`s timed in exact Rational whole notes, built with `seq` (e.g. `seq(C4, E4, G4.n4).n8`), `grid` (drum step strings like `'x...x...'`), and note length methods on `Note` (`n1`-`n8`, `n12`-`n128`, `.d`, `.t`, long names). Clips play in node graphs through `ClipNode` outputs (`clip.env`, `clip.tone`, `clip.gate`, `clip.trigger`, `clip.number`) that land edges on exact samples, at the tempo of a shared `Transport` (`bpm 120`). `legato(0.85)` shortens notes without changing the rhythm. `reverse` (alias `retrograde`) mirrors a clip or reverses a Seq's steps; `permute([2, 0, 1])` / `permute(seed: 3)` (alias `shuffle`) moves notes among the same rhythm, repeatably from the clip's seed. In a `Session`, looping clips play in phase with the transport timeline (`seek`, `rewind`), so graphs started at different times stay in sync. See `bin/songs/sequence_demo.rb`.

`swap :bass, bass2` (`Session#swap`, `lib/mb/sound/session/clip_swaps.rb`) changes a player's clips on the next bar via `ClipNode#swap_clip` (exact sample, graph and effect state kept). Transformed clips remember their `source` and transform (`Clip#lineage` / `#rederive`), so clips derived from the old one (`bass.transpose(12)`, `synth` voices) are rebuilt from the new one; pass `old => new` pairs (or `kit => kit2` for `grid` rows) when a player has unrelated clips. See `bin/songs/swap_song.rb`.

### Tempo sync

`Sequence::Duration` (`lib/mb/sound/sequence/duration.rb`) is an exact musical length in whole notes (comparable, `+`/`-`, scaled by numbers, friendly `to_s` like "3 × n16"), accepted wherever lengths are (`at:`, `fade:`, `every`, `after`, `render(bars:)`, `.len`, `until`).  `1.beat.hz` is a Pitch whose frequency comes from a `Sequence::TempoNode` following the tempo, and `4.bars.lfo` a Tone from it; the TempoNode locks the phase of every oscillator made from the pitch (its followers) to the timeline on jumps (start, seeks, resume) plus `with_phase`; they freeze while the timeline is paused unless `.freewheel`.  `sig.delay(1.n8.dotted)` (or `sig.filter(3.n16.delay(...))`, `seconds: 3.n16`, `multitap(1.n8.d, ...)`) follows the tempo; `2.bars.lfo.square.at(3.n16..5.n16)` gives an alternating delay time (`Tone#musical_time?`).  Plain numbers in `delay` are seconds.  Tempo-following nodes include `Sequence::TimelineNode` (shared with `ClipNode`), which `Session` finds in every graph (`timeline_nodes`).  `Tone#lfo` means full range plus no MIDI retrigger.  `render(bars:)` counts bars on the timeline, so tempo changes during a render are followed; `tail: true` adds the master effects tail after the limit.  See `bin/songs/tempo_song.rb`.

### Multichannel

Every GraphNode has `outputs` (`[self]` for one channel) and `channel_count`; nodes with several outputs (stereo file inputs, multi-output reverbs, `MultiOutput`s) act as bundles.  `GraphNode::Channels` (`lib/mb/sound/graph_node/channels.rb`) is the bundle class: `stereo(l, r)`, `channels(a, b, c)`, `[l, r].channels`, `node.stereo`; it is Array-like (`[]`, `each`, `map`, `l, r = bundle`) but deliberately not Enumerable (`Enumerable#filter` is `select`).  `GraphNode::ChannelDispatch` (loaded last in `graph_node.rb`) generates a per-channel version of every `*Methods` module method, so DSL calls on a bundle run per channel and return a bundle; single-channel nodes run unchanged.  Channel counts combine like NumPy broadcasting (1 is reused, N-N per channel, other mismatches raise); per-channel arguments are bundles, `channels(0.010, 0.013)` of plain values, or lazy `spread(a..b)`; filter objects are Marshal-copied per channel.  `reverb` is the deliberate exception: a bundle's channels all feed one reverb.  Conversions: `pan(pos, law: :equal_power)` (mono nodes pan; stereo bundles balance), `mono`/`mixdown`, `left`/`right`, `swap`, `mid_side`/`from_mid_side`, `width(w)`.  `master { |mix| ... }` gets the whole mix as a bundle.  `graphviz` collapses each per-channel call into one box listing per-channel arguments (`expand_channels: true` shows every node).  Deferred: layouts/surround matrices (user's private surround work), `.widen`/`.haas` and ping-pong (effects project), more pan laws, `Mixer` accepting bundles, vectorized N-channel nodes.  See `bin/songs/stereo_song.rb`.

### Master effects

`Session#master` (`lib/mb/sound/session/master.rb`, console `master { |mix| mix.softclip }`) runs the whole mix through a chain built on `GraphNode::MixSource` channels (one param = the mix as a stereo bundle, N params = one per channel; `master nil` bypasses). New chains start at `bg`-style launch points; by default the old chain "spills over" (fed silence from the switch sample so tails ring out, dropped after 1s below -90dB or 10s), `fade:` crossfades, `fade: 0` cuts (also used when the render load is over 60%). Chains keep processing while idle, `panic` rebuilds the chain to clear tails, and `render` adds the tail after the last player (10s cap). Nodes that change the sample count (`resample`, `oversample`) can't be used in a master chain yet. See Reverbs above for which reverbs are light enough for a live master chain.

### Scripts

Every bin/ script except `bin/sound.rb` is built on one of four helpers in `ScriptingMethods`, backed by `ScriptRunner` (`lib/mb/sound/script_runner.rb`, OptionParser):

- `effect_script(input_channels:, live_channels:, **params) { |input, p| graph }` - the input is an audio file (first audio argument or `-i`, rung out with a `Ringdown` node until 1 s of quiet, 10 s cap) or live input (`-c/--input-channels`); `--repeat [COUNT]` loops the file.
- `synth_script(**params) { |midi_input, p| graph }` - `midi_input` is a MIDI file or JACK port name (or nil for live MIDI); pass it to `MB::Sound.synth` / `midi_manager` / `midi_file`.  A MIDI file rings out: after its last channel event (`MIDIFile#music_end`), nodes driven by it (`VoicePool`, MIDI DSL nodes) report `#ended?` and the runner stops after a second of quiet (10 s tail limit), like effect file inputs (`Ringdown#ended?`); the nodes themselves return nil only `MIDIFile::TAIL_SECONDS` later, for players without tail detection.
- `song_script(bars:, **params) { |p| ... }` - the block arranges the song on the current session (`bg`, `at_bar`, `master`); `-b/--bars N` plays or renders N bars (live too), `--bpm` sets the starting tempo and scales the song's tempo changes (`Transport#override_bpm`), `--graphviz` draws the session at the start (`Session#graph_view`).
- `script(args:, **params) { |args, p| ... }` - general scripts (utilities, plots, file processors, benchmarks, MIDI tools): only `-h/--help` is common, positional arguments go to the block (`args:` Integer/Range checks their count; negative numbers stay positional).

Effects, synths, and songs share `-o/--output` (or a positional audio file) to render instead of playing, `-f/--force`, `-g/--graphviz`, `-p/--plot`, `-q/--quiet`, and play through the background `Session`.  Parameters are options only (no positional numbers): `name: default` or `name: [default, 'description', '-x', Type, allowed_range_or_array, :required]` in any order after the default; bad values print the option help.  `p.midi_cc(1, :hz, range: 0.0..6.0)` gives a MidiDsl CC node starting at the parameter value (range relative to it, like `GraphVoice#on_cc`) with live JACK MIDI, else a constant.  Graph-building code belongs inside the block (`--graphviz` runs song blocks twice).  Guard scripts that can also be `load`ed with `if main_script?(__FILE__)`.  Smoke tests: `spec/bin/script_smoke_spec.rb` (see Testing).

### MIDI

`lib/mb/sound/midi/` handles MIDI file parsing, real-time input, voice management, and controller mapping. Integrates with the GraphNode DSL for synthesizer control.

### Sibling Libraries

- `mb-math` - Math utilities (GitHub dependency)
- `mb-util` - General utilities (GitHub dependency)
- `mb-sound-jackffi` - JACK audio FFI bindings (GitHub dependency)

## Source Control

- Use worktrees (and branches) for feature development
- Commit progress and experimentation incrementally as you work
- Provide step-by-step commits with detailed commit messages for easy review
- Use non-fast-forward merge commits when features are complete
- The primary/trunk branch is called `master-ai` (upstream GitHub trunk is `master`; the old unconnected local history is tagged `local-master-pre-reconcile`)
- Local development; no push to remote
- New worktrees go in `.claude/worktrees/` and need `bundle exec rake compile` before specs run
- Before merging, check which branch the main checkout (`/app`) is on; the user switches branches there.  If `/app` isn't on `master-ai`, merge in the feature's worktree (`git checkout master-ai` there) instead of switching `/app`.  Write merge messages to a file for `git merge -F file` (`-F -` doesn't read stdin).

## Key Conventions

- Ruby 4.0+ required (gemspec, CI, `.ruby-version`); Bundler 4 (the lockfile's `BUNDLED WITH`)
- Tests use RSpec (configured in `.rspec`)
- Docker support via `Dockerfile` and `dock.sh` for containerized development
- `Numo::NArray` for all sound data handling (choose numeric precision and real/complex as needed)

## Working Notes (lessons learned)

### Verifying audio without speakers

The container has no audio device, so check sound-producing code by rendering it: `MB::Sound.render('file.flac', graph, bars: 4)` or loops of `node.sample(800)`, then look at peak levels, silent stretches, and exact sample offsets of note edges.  Use `NullOutput.new(..., sleep: false)` and `Session.new(realtime: false)` with `#process_buffer` for fast, deterministic tests.  To check that events happened (e.g. a swap landed on its bar), trace internal state from a scheduled block; spectral checks of the mix are easily fooled by other parts.  Leave listening to the user (on a Mac) with copy-pasteable snippets and expected results, and keep good snippets in demo script header comments.

### Gotchas

- `#sample` usually returns a reused buffer; `.dup` each buffer before collecting several of them (several false "bugs" came from forgetting this).
- Oscillators (`Tone`, `noise`) are full scale (-1..1) by default, and the master bus (`Session#master_gain`, `master_gain -6.db`, `render(gain:)`) is -10 dB by default, live and in renders, so mixes of full-scale parts have headroom; effect scripts set it to 0 dB, since they process recordings with their own levels.  Check levels by rendering.
- Oscillators and constants play forever (there is no `.for`/`.forever`); sounds end through envelopes (an envelope nothing triggers is a one-shot that ends; voices and clips mark theirs `retriggerable!`), clips, files, `x.until(seconds)` or `x.until(2.bars)` (`GraphNode::TimeLimit`, a hard cut; musical lengths follow the tempo, counted from the node's first sample), `and_then`, or `MB::Sound.silence(s)` (zeros, then the end; e.g. tails via `and_then(silence(s))`).  `play` of a graph says to press Ctrl-C, `write` caps graphs at `MAX_RENDER_SECONDS`, and `fft`/`plot`/`write` given a bare Tone or Pitch take one second of it.
- `40.hz` is a Pitch that plays as a sine when used as a signal, not a constant; use `40.constant` for fixed values in arithmetic, and `pitch.transpose(n)` or `(f * 2).hz` to change frequencies (`440.hz * 2` doubles the sine's amplitude).
- `node.filter(cookbook_filter)` re-applies the filter's original cutoff and quality every buffer, so changing `center_frequency` from outside (e.g. a MIDI callback) does nothing; pass `cutoff:` a node and change the node.
- `multitap` and other multi-output results are `Channels` bundles, which are deliberately not Enumerable (`.to_a` for `shuffle`, `reverse`, etc.).
- C4 = 60 (C3 = 48).  Derive expected values in specs from note constants or a quick script; hand-computed notes and offsets caused several wrong assertions.
- A realtime Session's render thread runs until `close`; close sessions in spec `after` blocks.  `kill -QUIT <pid>` prints every thread's backtrace (`MB::U.sigquit_backtrace`, set up in spec_helper).
- Before adding `bin/sound.rb` commands, check for collisions with `MB::Sound` methods and Pry commands (`Pry::Commands`; e.g. `reset` and `watch` are taken).
- macOS playback goes through ffmpeg's audiotoolbox output with `FFMPEGOutput realtime: true` and `BackgroundOutput`; expect about 0.4s latency.

### Process

- In multi-step shell scripts, use `set -euo pipefail`, don't pipe away exit codes, and put commands on separate lines (a failure inside `a && b` doesn't stop the script).  A batch loop that kept going after a failure once produced broken commits.
- Use the Edit tool for multi-line code changes; ad hoc Python/sed replacements often failed on indentation or escaping.
- Keep command output small (grep/head/tail, Read with offsets); large tool output fills the context quickly.
- Measure before explaining a failure; the first theory for the macOS latency problem was wrong, and a small experiment found the real cause.
- The user often says "note for later": record those in local memory (themed idea files), not GitHub, and implement them only after an explicit go-ahead.
