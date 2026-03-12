# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

mb-sound is a Ruby library for sound processing with a fluent DSL for building signal processing chains. It is a companion to an educational YouTube video series about sound. It uses Numo::NArray for numeric operations and includes C extensions for performance-critical paths.

### Folders

- `bin/` - user-facing scripts and experiments
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

System dependencies (apt): `ffmpeg gnuplot-qt libsamplerate0-dev graphviz`

## Architecture

### Core Abstraction: GraphNode DSL

The central pattern is `GraphNode` (`lib/mb/sound/graph_node.rb`), a module mixed into any class that implements `#sample`. It enables fluent chaining to build signal processing graphs:

```ruby
play 123.hz.triangle.at(-20.db).for(0.5)
play 123.hz.fm(369.hz.at(1000)).softclip.filter(150.hz.highpass(quality: 4))
```

Graph nodes maintain input/output relationships and support traversal via the `Traversable` mixin. Key node types live in `lib/mb/sound/graph_node/` (tone, noise, filter, resample, quantize, MIDI, etc.).

### Numeric Mixins

`lib/mb/sound/numeric_sound_mixins.rb` adds methods like `.hz`, `.db`, `.meters`, `.bits` to Ruby's Numeric class, enabling the fluent DSL (e.g. `440.hz.sine.forever`, `-20.db`).

### Method Modules

`MB::Sound` extends several method modules that provide the top-level API available in `bin/sound.rb`:
- `IOMethods` - File read/write via ffmpeg
- `PlaybackMethods` - `play`, `input`, real-time audio
- `PlotMethods` - Terminal/gnuplot visualization
- `FFTMethods` - Spectral analysis
- `GainMethods`, `WindowMethods`, `AnalysisMethods`

### C Extensions (3 native extensions, compiled via rake-compiler)

- `ext/mb/fast_sound/` - Fast waveform generation → `lib/mb/fast_sound.so`
- `ext/mb/sound/fast_resample/` - libsamplerate bindings → `lib/mb/sound/fast_resample.so`
- `ext/mb/sound/fast_wavetable/` - Fast wavetable synthesis → `lib/mb/sound/fast_wavetable.so`

### Filter System

`lib/mb/sound/filter/` contains 16+ filter types (Biquad, FIR, Butterworth, Hilbert, Delay, etc.). Filters implement `#process` / `#reset`. `Filter::Cookbook` provides standard designs (lowpass, highpass, bandpass, etc.).

### MIDI

`lib/mb/sound/midi/` handles MIDI file parsing, real-time input, voice management, and controller mapping. Integrates with the GraphNode DSL for synthesizer control.

### Sibling Libraries

- `mb-math` - Math utilities (GitHub dependency)
- `mb-util` - General utilities (GitHub dependency)
- `mb-sound-jackffi` - JACK audio FFI bindings (GitHub dependency)

## Source Control

- Use branches for feature development
- Use non-fast-forward merge commits when features are complete
- Provide step-by-step commits with detailed commit messages for easy review
- The primary/trunk branch is called `master`

## Key Conventions

- Ruby 3.4 target (supports 2.7+)
- Tests use RSpec (configured in `.rspec`)
- The `bin/` directory contains ~57 example/utility scripts demonstrating synthesis, effects, MIDI, and plotting
- Docker support via `Dockerfile` and `dock.sh` for containerized development
- `Numo::NArray` for all sound data handling (choose numeric precision and real/complex as needed)
