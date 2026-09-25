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
- `PlaybackMethods` - `play`, `input`, real-time audio; `bg` / `stop` / `outro` (alias `fadeout`) / `panic` / `players` / `resume` / `stopped` / `forget` / `visualize` (alias `vis`) play and plot sounds in the background through one shared `Session` (`lib/mb/sound/session.rb`) that mixes every player in a single render loop locked to the sequence timeline; `render` runs a `Session` into a file
- `ScheduleMethods` - `at_bar` (alias `on_bar`) / `after` / `every` / `scheduled` / `cancel` run blocks at bars on the `Session` timeline; `bg`/`stop`/`resume`/`bpm` inside them take effect exactly at the scheduled time (see `bin/songs/scheduled_song.rb`)
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
- New worktrees go in `.claude/worktrees/` and need `bundle exec rake compile` before specs run
- Before merging, check which branch the main checkout (`/app`) is on; the user switches branches there

## Key Conventions

- Ruby 3.4+ recommended (gemspec requires 3.2+); the container uses Ruby 4.0
- Tests use RSpec (configured in `.rspec`)
- The `bin/` directory contains ~65 example/utility scripts demonstrating synthesis, effects, MIDI, and plotting
- Docker support via `Dockerfile` and `dock.sh` for containerized development
- `Numo::NArray` for all sound data handling (choose numeric precision and real/complex as needed)

## Working Notes (lessons learned)

### Verifying audio without speakers

The container has no audio device, so check sound-producing code by rendering it: `MB::Sound.render('file.flac', graph, bars: 4)` or loops of `node.sample(800)`, then look at peak levels, silent stretches, and exact sample offsets of note edges.  Use `NullOutput.new(..., sleep: false)` and `Session.new(realtime: false)` with `#process_buffer` for fast, deterministic tests.  Leave listening tests to the user (they test on a Mac) and give them copy-pasteable snippets with expected results.

### Gotchas

- `#sample` usually returns a reused buffer; `.dup` each buffer before collecting several of them (several false "bugs" came from forgetting this).
- Oscillators (`Tone`, `noise`) default to amplitude 0.1, and `*` only raises its right operand to full level, so `tone * env` is 10x quieter than `env * tone`.  Use `.at(...)` explicitly in examples and check levels by rendering.
- `40.hz` is an oscillator, not a constant; use `40.constant` for fixed values in arithmetic.
- Before adding `bin/sound.rb` commands, check for collisions with `MB::Sound` methods and Pry commands (`Pry::Commands`; e.g. `reset` and `watch` are taken).
- macOS playback goes through ffmpeg's audiotoolbox output with `FFMPEGOutput realtime: true` and `BackgroundOutput`; expect about 0.4s latency.

### Process

- In multi-step shell scripts, use `set -euo pipefail` and don't pipe away exit codes; a batch loop that kept going after a failure once produced broken commits.
- Keep command output small (grep/head/tail, Read with offsets); large tool output fills the context quickly.
- Measure before explaining a failure; the first theory for the macOS latency problem was wrong, and a small experiment found the real cause.
- The user often says "note for later": record those in memory and the issue #64 backlog, and implement them only after an explicit go-ahead.
- Run the full suite once per change unless the user asks for affected specs only.
