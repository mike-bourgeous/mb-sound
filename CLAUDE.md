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

Testing: run affected specs while working, and the full suite (about 6-7 minutes) before and after each merge, or more often for good reason.  Save suite output to a file and grep it instead of rerunning.  Run one spec process at a time; concurrent runs cause spurious failures (maybe SimpleCov or fixed-name tmp files).

System dependencies (apt): `ffmpeg gnuplot-qt libsamplerate0-dev libjack-dev graphviz`

In the container, `OUTPUT_TYPE=null` is set in the Dockerfile so playback uses `NullOutput`.

## Architecture

### Core Abstraction: GraphNode DSL

The central pattern is `GraphNode` (`lib/mb/sound/graph_node.rb`), a module mixed into any class that implements `#sample`. It enables fluent chaining to build signal processing graphs:

```ruby
play 123.hz.triangle.at(-20.db).for(0.5)
play 123.hz.fm(369.hz.at(1000)).softclip.filter(150.hz.highpass(quality: 4))
```

The DSL methods (`#filter`, `#delay`, `#softclip`, arithmetic operators, etc.) live in topic modules included by `GraphNode`, in `lib/mb/sound/graph_node/*_methods.rb`; `graph_node.rb` keeps naming, graph traversal, and shared private helpers.

Graph nodes maintain input/output relationships and support traversal via the `Traversable` mixin. Key node types live in `lib/mb/sound/graph_node/` (tone, noise, filter, resample, quantize, MIDI, etc.).

### Numeric Mixins

`lib/mb/sound/numeric_sound_mixins.rb` adds methods like `.hz`, `.db`, `.meters`, `.bits` to Ruby's Numeric class, enabling the fluent DSL (e.g. `440.hz.sine.forever`, `-20.db`).  `Sequence::NumericDurations` adds musical lengths (`2.bars`, `3.beats`, `3.n16`, `3.sixteenths`, `1.n8.dotted`) returning `Sequence::Duration`s; see Tempo sync below.

### Method Modules

`MB::Sound` extends several method modules that provide the top-level API available in `bin/sound.rb`:
- `IOMethods` - File read/write via ffmpeg
- `PlaybackMethods` - `play`, `input`, real-time audio, plus the background session:
  - `bg` / `stop` / `outro` (alias `fadeout`) / `panic` / `players` / `resume` / `stopped` / `forget` play sounds in the background through one shared `Session` (`lib/mb/sound/session.rb`) that mixes every player in a single render loop locked to the sequence timeline
  - `swap` changes the clips a player plays without rebuilding its graph; `master` (alias `master_fx`) sets master effects on the mix (see Sequences and Master effects below)
  - `visualize` (alias `vis`) plots the mix live; `render` runs a `Session` into a file
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

Two reverb implementations coexist; use `#reverb` in most cases:

- `GraphNode::Reverb` / `#reverb` (`lib/mb/sound/graph_node/reverb.rb`) - the original from the reverb video; presets (`:room`, `:hall`, `:space`, ...).  `[l, r].reverb(:hall)` takes one input per Array element.  Stereo cost: `:hall` ~18% of realtime, `:space` ~55% (too heavy live on the user's laptop).
- `GraphNode::FdnReverb` / `#fdn_reverb` - an experiment (clean-room, by Claude Code) with `room_size`/`decay`/`damping`; ~70% of realtime each, too slow live; may be removed once `#reverb` gets similar parameters.

### Sequences

`lib/mb/sound/sequence/` (`MB::Sound::Sequence`) holds musical sequences: immutable `Clip`s of `Event`s timed in exact Rational whole notes, built with `seq` (e.g. `seq(C4, E4, G4.n4).n8`), `grid` (drum step strings like `'x...x...'`), and note length methods on `Note` (`n1`-`n8`, `n12`-`n128`, `.d`, `.t`, long names). Clips play in node graphs through `ClipNode` outputs (`clip.env`, `clip.tone`, `clip.gate`, `clip.trigger`, `clip.number`) that land edges on exact samples, at the tempo of a shared `Transport` (`bpm 120`). `legato(0.85)` shortens notes without changing the rhythm. `reverse` (alias `retrograde`) mirrors a clip or reverses a Seq's steps; `permute([2, 0, 1])` / `permute(seed: 3)` (alias `shuffle`) moves notes among the same rhythm, repeatably from the clip's seed. In a `Session`, looping clips play in phase with the transport timeline (`seek`, `rewind`), so graphs started at different times stay in sync. See `bin/songs/sequence_demo.rb`.

`swap :bass, bass2` (`Session#swap`, `lib/mb/sound/session/clip_swaps.rb`) changes a player's clips on the next bar via `ClipNode#swap_clip` (exact sample, graph and effect state kept). Transformed clips remember their `source` and transform (`Clip#lineage` / `#rederive`), so clips derived from the old one (`bass.transpose(12)`, `synth` voices) are rebuilt from the new one; pass `old => new` pairs (or `kit => kit2` for `grid` rows) when a player has unrelated clips. See `bin/songs/swap_song.rb`.

### Tempo sync

`Sequence::Duration` (`lib/mb/sound/sequence/duration.rb`) is an exact musical length in whole notes (comparable, `+`/`-`, scaled by numbers, friendly `to_s` like "3 × n16"), accepted wherever lengths are (`at:`, `fade:`, `every`, `after`, `render(bars:)`, `.len`).  `4.bars.lfo` / `1.beat.hz` are Tones driven by a `Sequence::TempoNode` that follows the tempo, with phase locked to the timeline on jumps (start, seeks, resume) plus `with_phase`; they freeze while the timeline is paused unless `.freewheel`.  `sig.delay(1.n8.dotted)` (or `sig.filter(3.n16.delay(...))`, `seconds: 3.n16`, `multitap(1.n8.d, ...)`) follows the tempo; `2.bars.lfo.square.at(3.n16..5.n16)` gives an alternating delay time (`Tone#musical_time?`).  Plain numbers in `delay` are seconds.  Tempo-following nodes include `Sequence::TimelineNode` (shared with `ClipNode`), which `Session` finds in every graph (`timeline_nodes`).  `Tone#lfo` means full range and forever (`or_forever`) plus no MIDI retrigger.  `render(bars:)` counts bars on the timeline, so tempo changes during a render are followed.  See `bin/songs/tempo_song.rb`.

### Master effects

`Session#master` (`lib/mb/sound/session/master.rb`, console `master { |mix| mix.softclip }`) runs the whole mix through a chain built on `GraphNode::MixSource` channels (one param = per channel, N params = all channels; `master nil` bypasses). New chains start at `bg`-style launch points; by default the old chain "spills over" (fed silence from the switch sample so tails ring out, dropped after 1s below -90dB or 10s), `fade:` crossfades, `fade: 0` cuts (also used when the render load is over 60%). Chains keep processing while idle, `panic` rebuilds the chain to clear tails, and `render` adds the tail after the last player (10s cap). Nodes that change the sample count (`resample`, `oversample`) can't be used in a master chain yet. See Reverbs above for which reverbs are light enough for a live master chain.

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

- Ruby 3.4+ recommended (gemspec requires 3.2+); the container uses Ruby 4.0
- Tests use RSpec (configured in `.rspec`)
- Docker support via `Dockerfile` and `dock.sh` for containerized development
- `Numo::NArray` for all sound data handling (choose numeric precision and real/complex as needed)

## Working Notes (lessons learned)

### Verifying audio without speakers

The container has no audio device, so check sound-producing code by rendering it: `MB::Sound.render('file.flac', graph, bars: 4)` or loops of `node.sample(800)`, then look at peak levels, silent stretches, and exact sample offsets of note edges.  Use `NullOutput.new(..., sleep: false)` and `Session.new(realtime: false)` with `#process_buffer` for fast, deterministic tests.  To check that events happened (e.g. a swap landed on its bar), trace internal state from a scheduled block; spectral checks of the mix are easily fooled by other parts.  Leave listening to the user (on a Mac) with copy-pasteable snippets and expected results, and keep good snippets in demo script header comments.

### Gotchas

- `#sample` usually returns a reused buffer; `.dup` each buffer before collecting several of them (several false "bugs" came from forgetting this).
- Oscillators (`Tone`, `noise`) default to amplitude 0.1, and `*` only raises its right operand to full level, so `tone * env` is 10x quieter than `env * tone`.  Use `.at(...)` explicitly in examples and check levels by rendering.
- `Tone.new` (and `Numeric#hz`) defaults to a 5-second duration, so graphs driven by clips or LFOs need `.forever` (`Tone#lfo` now plays forever by default).- `40.hz` is an oscillator, not a constant; use `40.constant` for fixed values in arithmetic.
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
