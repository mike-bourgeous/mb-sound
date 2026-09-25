# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

mb-sound is a Ruby library for sound processing with a fluent DSL for building signal processing chains. It is a companion to an educational YouTube video series about sound. It uses Numo::NArray (via the `numo-narray-alt` fork) for numeric operations and includes C extensions for performance-critical paths.

### Folders

- `bin/` - user-facing scripts and experiments (`bin/effects/`, `bin/synths/`, `bin/midi/`, `bin/songs/`, plus general utilities at the top level)
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

Note: run the test suite ONCE per change and save its output for processing, rather than running the test suite repeatedly with different `grep` pipes or options.

System dependencies (apt): `ffmpeg gnuplot-qt libsamplerate0-dev libjack-dev graphviz`

In the container, `OUTPUT_TYPE=null` is set in the Dockerfile so playback uses `NullOutput`.

## Architecture

### Core Abstraction: GraphNode DSL

The central pattern is `GraphNode` (`lib/mb/sound/graph_node.rb`), a module mixed into any class that implements `#sample`. It enables fluent chaining to build signal processing graphs:

```ruby
play 123.hz.triangle.at(-20.db).for(0.5)
play 123.hz.fm(369.hz.at(1000)).softclip.filter(150.hz.highpass(quality: 4))
```

The DSL methods themselves (`#filter`, `#delay`, `#softclip`, arithmetic operators, etc.) live in topic modules included by `GraphNode`, in `lib/mb/sound/graph_node/*_methods.rb` (`RoutingMethods`, `ArithmeticMethods`, `SynthesisMethods`, `ResampleMethods`, `FilterMethods`, `DelayMethods`, `DistortionMethods`, `DebugMethods`, `DurationMethods`); `graph_node.rb` keeps naming, graph traversal, and shared private helpers.

Graph nodes maintain input/output relationships and support traversal via the `Traversable` mixin. Key node types live in `lib/mb/sound/graph_node/` (tone, noise, filter, resample, quantize, MIDI, etc.).

### Numeric Mixins

`lib/mb/sound/numeric_sound_mixins.rb` adds methods like `.hz`, `.db`, `.meters`, `.bits` to Ruby's Numeric class, enabling the fluent DSL (e.g. `440.hz.sine.forever`, `-20.db`).

### Method Modules

`MB::Sound` extends several method modules that provide the top-level API available in `bin/sound.rb`:
- `IOMethods` - File read/write via ffmpeg
- `PlaybackMethods` - `play`, `input`, real-time audio; `bg` / `stop` / `hush` / `panic` / `players` play sounds in the background through one shared `Session` (`lib/mb/sound/session.rb`) that mixes every player in a single render loop locked to the sequence timeline; `render` runs a `Session` into a file
- `PlotMethods` - Terminal/gnuplot visualization
- `FFTMethods` - Spectral analysis
- `GainMethods`, `WindowMethods`, `AnalysisMethods`

### C Extensions (3 native extensions, compiled via rake-compiler)

- `ext/mb/fast_sound/` - Fast waveform generation → `lib/mb/fast_sound.so`
- `ext/mb/sound/fast_resample/` - libsamplerate bindings → `lib/mb/sound/fast_resample.so`
- `ext/mb/sound/fast_wavetable/` - Fast wavetable synthesis → `lib/mb/sound/fast_wavetable.so`

### Filter System

`lib/mb/sound/filter/` contains 16+ filter types (Biquad, FIR, Butterworth, Hilbert, Delay, etc.). Filters implement `#process` / `#reset`. `Filter::Cookbook` provides standard designs (lowpass, highpass, bandpass, etc.).

### Reverbs

Two reverb implementations coexist:

- `GraphNode::Reverb` / `#reverb` (`lib/mb/sound/graph_node/reverb.rb`, `bin/effects/reverb.rb`) - the original from the reverb video; preset-based (`:room`, `:hall`, `:space`, ...), with visualizable internals.
- `GraphNode::FdnReverb` / `#fdn_reverb` (`lib/mb/sound/graph_node/fdn_reverb.rb`, `bin/effects/fdn_reverb.rb`) - a clean-room implementation written with Claude Code; parameterized by `room_size`, `decay`, and `damping`, with seeded non-harmonic delays.

### Sequences

`lib/mb/sound/sequence/` (`MB::Sound::Sequence`) holds musical sequences: immutable `Clip`s of `Event`s timed in exact Rational whole notes, built with `seq` (e.g. `seq(C4, E4, G4.n4).n8`), `grid` (drum step strings like `'x...x...'`), and note length methods on `Note` (`n1`-`n8`, `n12`-`n128`, `.d`, `.t`, long names). Clips play in node graphs through `ClipNode` outputs (`clip.env`, `clip.tone`, `clip.gate`, `clip.trigger`, `clip.number`) that land edges on exact samples, at the tempo of a shared `Transport` (`bpm 120`). `legato(0.85)` shortens notes without changing the rhythm. In a `Session`, looping clips play in phase with the transport timeline (`seek`, `rewind`), so graphs started at different times stay in sync. See `bin/songs/sequence_demo.rb`.

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

## Key Conventions

- Ruby 3.4+ recommended (gemspec requires 3.2+); the container uses Ruby 4.0
- Tests use RSpec (configured in `.rspec`)
- The `bin/` directory contains ~65 example/utility scripts demonstrating synthesis, effects, MIDI, and plotting
- Docker support via `Dockerfile` and `dock.sh` for containerized development
- `Numo::NArray` for all sound data handling (choose numeric precision and real/complex as needed)
