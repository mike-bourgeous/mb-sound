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
bundle exec rake memcheck         # C extension specs under Valgrind (full: ~30-45 min, up to 1.3 GB; options in Rakefile)
bundle exec rake memcheck:changed # only the memcheck specs for extensions changed since master-ai (MEMCHECK_DRY=1, FULL=auto)
bundle exec rake memcheck:status  # last full memcheck and whether one is due
bundle exec rake depend:check     # ext depend files against the headers the sources include
```

Testing: run affected specs while working, and the full suite (about 2 minutes) before and after each merge, or more often for good reason.  Save suite output to a file and grep it instead of rerunning.  Concurrent spec processes work (per-process temp dirs and coverage files); parallelizing the suite is deliberately postponed, since slow or leaky specs are better fixed than hidden.

Spec conventions (`spec/support/`):
- Temp files: `tmp_path('name.flac')` gives a path in an empty directory per example, inside a random per-process `Dir.mktmpdir` removed at exit (`KEEP_SPEC_TMP=1` keeps it); never write fixed names under `tmp/`.
- Coverage is opt-in: `SIMPLECOV=1 bundle exec rspec` (CI sets it) reports to `coverage/` (+~20% suite time, +~30% smoke); bin/ scripts run by specs get `spec/subprocess_coverage_helper.rb` (via RUBYOPT), merged into the report after the suite.  If script specs are slow, check `coverage/.resultset.json` isn't huge; `rm -rf coverage` is safe.
- `fork_script(script, *args)` runs a bin/ script in a fork of the spec process (skips ~0.7 s of startup); a spec using it must also run its script once as a real process doing real work, so load-order problems still show.
- Before each example spec_helper calls `MB::Sound.close_outputs`, so cached outputs (and NullOutput pacing) don't leak between examples.  Specs that run a Session on the shared transport must `MB::Sound.rewind` afterwards.
- For limits like `Session::MAX_TAIL_SECONDS`, `stub_const` the constant where it's defined (`Session::Master::MAX_TAIL_SECONDS`) instead of rendering 10 s of tail.
- Load-sensitive specs: a few realtime timing examples can fail under heavy load (concurrent renders, other suites) or Valgrind and pass on a rerun: `spec/lib/mb/sound/device_output_spec.rb:244`, and `live_source_spec.rb`'s JACK "frame plus the latency" example under `rake memcheck` (first note one 256-sample period early).  Rerun once before investigating; under memcheck, Valgrind errors (not timing failures) are what count.
- Short inputs: `spec/test_data/arp_a7.flac` is a 0.4 s stereo Am7/Amaj7 triangle arp (made by `spec/test_data/make_arp_a7.rb`) for effect and script specs; test MIDI files start within 0.2 s.

The bin/ script smoke tests (`spec/bin/script_smoke_spec.rb`, tagged `:smoke`, about 1.5 minutes; plain `rspec` skips them, CI runs them as a separate job) run every script with `--help` (in forks for scripts that also render) and a short render (real processes), with shared-buffer checks raising (see Core Abstraction).  Run them with `bundle exec rspec --tag smoke` before merging changes to bin/ scripts, the script runner, or nodes that touch input buffers, and add new scripts to their tables.

System dependencies (apt): `ffmpeg gnuplot-qt libsamplerate0-dev libasound2-dev libjack-jackd2-dev jackd2 graphviz` (ALSA headers build RtMidi's ALSA sequencer backend; the shared JACK client loads libjack at run time, so `libjack-jackd2-dev` only builds RtMidi's JACK API, which specs use as an outside JACK client; `jackd2` runs a dummy JACK server for the JACK specs, which skip without it).  In the container, the Dockerfile sets `OUTPUT_TYPE=null` so playback uses `NullOutput`.

## Architecture

Each subsystem below is a summary; the full notes (design decisions with dates, measurements, research, render locations) are in `design/notes/<topic>.md`.  Read the topic's note before changing a subsystem, and update both when behavior changes.

### Core Abstraction: GraphNode DSL (`design/notes/graph_nodes.md`)

`GraphNode` (`lib/mb/sound/graph_node.rb`) is mixed into any class with `#sample`, giving fluent chaining:

```ruby
play 123.hz.triangle.at(-20.db)   # oscillators play until Ctrl-C
play 123.hz.fm(369.hz.at(1000)).softclip.filter(150.hz.highpass(quality: 4))
```

DSL methods live in topic modules `lib/mb/sound/graph_node/*_methods.rb`; node types in `lib/mb/sound/graph_node/`, MIDI nodes in `lib/mb/sound/notes/`; traversal via `Traversable`.
- Every consumer must call `get_sampler` on nodes it stores in its constructor, so a node used in several places branches through a `Tee` instead of advancing twice.
- Tee branches reading in lockstep share one frozen buffer; otherwise the Tee copies through a CircularBuffer (made lazily).  A node processing its input in place copies it first only if `buf.frozen?` (user rule; `GraphNode::FrozenCopy`).  `MB_SOUND_CHECK_SHARED=1` / the `:check_shared` tag verify shared buffers aren't modified; `MB_SOUND_SHARED_TEE=0` turns sharing off.
- Multiplier, Mixer, and Pan have allocation-free C fast paths (`fast_arithmetic`), bit-identical to the general path.
- Measure graph cost with `bin/graph_profile.rb [-n 32,128,800] [--profile] [--plan on|off|ruby|both] script.rb` (worst-case synth input: `spec/test_data/dense_modulated.mid`); compare branches in alternating runs against a master-ai worktree.

### Plan layer (`design/notes/plan_layer.md`)

`lib/mb/sound/plan.rb` + `plan/` (executor `ext/mb/sound/fast_plan`) runs connected regions of a graph as one op list per block in C, an as-if transformation: same samples (bit-exact except the default `:fast` sines and 2^x, within -124 dB), the user's graph untouched, node state kept in the nodes so a plan can drop at any block boundary.
- Installed automatically by `Synth` (per lane) and `Session#add`.  `MB_SOUND_PLAN=0` off, `=ruby` the Ruby mirror; `MB_SOUND_PLAN_CHECK=1` runs every block planned and unfused and compares samples and states.  `MB_SOUND_PLAN_PRECISION=exact` / `Plan.precision = :exact` for bit-exact programs (wiring specs and Tone null-test references set it).
- Node protocol (`Plan::Describable`): `plan_describe(p)` returns the node's output Value built with `Plan::Builder` (`p[handle]`, `p.const`, Value operators, `p.tone`, `p.param`, `p.boundary`), plus `plan_inputs`, `plan_unsupported_reason`, `plan_snapshot`/`plan_restore`.  Ops are `Plan::Op::*` objects with a `#run_ruby` mirror; `Plan::Program` allocates registers and lowers to Int32 words.
- Covered: constants and arithmetic, shapers, Tones (naive and PolyBLEP kernels with FM/PM/width/gain/resets), Notes event nodes and envelopes (event feeds recorded in Ruby, rendered in C), filters (SVF, biquad, four-pole, diode), SQ80 time scaling.  Boundaries for now: curve shapers, delays, SampleHold, TempoNodes, synced tones, ports, timelines, BLIT, clean resets, wavetables.
- `0 * x` folds to 0 for constants of the patch (x's ops still run; warned once per kind).  `Plan.changed(node)` after structural edits; `Plan.explain(graph)` lists regions and why nodes stay unfused.  Plans have no steady-input shortcuts (predictable cost).
- Specs: `spec/lib/mb/sound/plan/` (`plan_compare` runs unplanned, C, and mirror over 21 block sizes), `spec/ext/mb/sound/fast_plan_spec.rb`.

### Feedback loops (`design/notes/feedback_loops.md`)

`sig.feedback { |fb, input| input + fb.delay(5.ms) * 0.8 }` (alias `fb`; `GraphNode::FeedbackLoop`) runs the loop's nodes one sample at a time as ops in C (`fast_loop`, exact Ruby mirror; same output at any block size); everything outside the loop runs per block.  `sig.delay(t, feedback: g) { |fb| insert }` is the tape-echo form; insert pipelines `{ |d| d.fb { ... }; d.wet { ... } }` process only the recirculated or only the output signal.
- Loop ops: arithmetic, shapers, delays (`fb.delay(t)`, no `feedback:` of their own inside a loop), SVF filters.  Not yet: oscillators, envelopes, four-pole/biquad, multitap, loop taps.  Other nodes on the loop go through `MB::Sound.live_error` (raise in scripts/specs; in live mode, block-delayed fallback).
- Latency compensation (default `compensate: true` = `:pitch`): the longest delay reads earlier by the rest of the loop's phase delay at the fundamental, so periods and echo times are exact; `:dc` is the older group-delay mode, `false` off.
- Sustain (default on for loops with gentle lowpass SVFs): a hidden high shelf keeps the loop gain at the pitch as if the filters were wires; `#delay` echo loops pass `sustain: false`.
- Karplus-Strong: write one period of noise into the delay line, output after damping (the snippet is in the note).  Demos: `pluck.rb`, `bin/effects/tape_delay.rb`, `bin/effects/flanger.rb`, `bin/songs/feedback_song.rb`.

### Numbers, lengths, intervals, phases (`design/notes/numbers_lengths_phases.md`)

`lib/mb/sound/numeric_sound_mixins.rb` adds `.hz`, `.db`, `.meters`, `.bits` to Numeric.  `440.hz` is a `Pitch` (oscillator methods make a new `Tone` each call; plays as a sine when used as a signal); `Note < Pitch` (C4 = 60) follows the session `Tuning` (`tuning b4: 480`).
- `Tone` (`lib/mb/sound/tone.rb`) is the one oscillator node; DSL methods configure it before it plays (afterwards `FrozenError`, or a warning in live mode); per-sample state is one `Tone::State`.
- Phases are in cycles everywhere (0.25 = 90°): `with_phase`, `pm` index, `fm_feedback`, `reset(to:)`, unison `phase:`.  `MB::Sound::Phase`: `0.25.cycles`, `1.5.radians`, `90.degrees` (overrides mb-math's `Numeric#degrees` for reals; write `30.degrees.to_f` for radians), `node.radians`.
- Lengths: `2.bars`, `3.beats`, `3.n16`, `1.n8.dotted` (`Sequence::Duration`), `4.seconds`, `250.ms`, `5.samples` (`MB::Sound::Length`); every length-taking method accepts them plus plain numbers in its usual unit (seconds for delays/envelopes, bars for fades/schedules, samples for `with_buffer`).
- `MB::Sound::Interval` (`4.octaves`, `7.semitones`, `50.cents`; plain numbers are semitones for `transpose`) and `MB::Sound::Scale` (`scale(:minor, :a)`; degrees to Notes; `Scale::CHROMATIC` is every transform's default, so `pitch:` is always in scale degrees).

### Oscillators and antialiasing (`design/notes/oscillators.md`)

Tone waveforms are antialiased by default (`lib/mb/sound/band_limit.rb`, `fast_synth`); each shape has a naive `a*` twin (`aramp`, `asquare`, ...) for lo-fi and control signals; `.lfo` fades band-limiting in from 15-30 Hz.  Measure with `bin/aliasing.rb 'p.ramp' 'p.aramp'`.
- `ramp`/`saw`, `square`, `triangle`: PolyBLEP/PolyBLAMP.  `pwm(w)` (alias `skew`) warps any shape.  `complex_*`: closed-form band-limited impulse trains (wavetables with PM/pwm/sync).
- `sync(ratio:)` / `sync(master)` / `softsync`: causal minBLEP kernel, exact naive waveform through a minimum-phase filter (~2.78 samples delay).  `fm_feedback(amount, gain:)` (aliases `fmfb`, `fm_fb`): DX7-style operator self-feedback in cycles, sines only.  `tone.gain(g)` multiplies inside the Tone.
- Phase jumps (resets, timeline jumps) are band-limited steps; `clean` (opt-in, ~2x CPU) makes jumps hard-sync events.  `tone.reset(trig, to:)` jumps at nonzero trigger samples; `.free` never resets; `.rnd` random phases.  Randomness from `MB::Sound.seed(n)`/`next_seed` (restored before every spec); noise has its own splitmix64 state per tone.
- `softclip`, `clip`, `abs`, `quantize` use ADAA plus a half-sample allpass (half a sample of delay); `asoftclip` etc. are exact.  Ports (`tone.wraps`, `.increment`, TempoNode `jumps`): every reader must read each buffer.
- Wavetables (`lib/mb/sound/wavetable.rb`, `fast_wavetable`): `Wavetable` cycle tables and samples, mipmapped (`:half_octave` default), `440.hz.wavetable(t, scan:)` with FM/PM/pwm/sync/resets, `KeyMap` zones, `phase_table`, `waveshape`, `Pitch#harmonics` additive.  Demo `bin/songs/wavetable_song.rb`.
- Unison (`lib/mb/sound/unison.rb`): `pitch.unison(n, detune:, spread:, mix:) { |p, i| p.saw }`; `pitch.swarm(...)` per-copy glides.  Demos `bin/songs/unison_song.rb`, `swarm_song.rb`.  Still aliasing: FM/PM sidebands (use `oversample`), `gauss`, naive shapes.

### Method Modules (`design/notes/method_modules.md`)

`MB::Sound` extends the top-level API used in `bin/sound.rb`: `IOMethods` (ffmpeg file I/O); `PlaybackMethods` (`play`, `input`, the background `Session`: `bg`/`stop`/`outro`/`panic`/`players`/`resume`, `swap`, `master`, `vis`, `render`, `wait` at the end of scripts, `use_output`); `MultichannelMethods`; `ScheduleMethods` (`at_bar`/`after`/`every` on the Session timeline); `PlotMethods`; `FFTMethods`; `ScriptingMethods`; `GainMethods`, `WindowMethods`; `AnalysisMethods` (including BS.1770 `loudness` → `Loudness::Result`, `node.loudness_meter`, `bin/loudness.rb`, `render(loudness: :spotify)`); `LiveMethods` (`live?`, `live_error`).

### C Extensions (`design/notes/c_extensions.md`)

Extensions under `ext/mb/sound/` (plus `ext/mb/fast_sound/`), each building `lib/mb/sound/<name>.so`: fast_sound, fast_resample, fast_wavetable, fast_delay, fast_synth, fast_clip, fast_unison, fast_arithmetic, fast_envelope, fast_control, fast_audio, fast_midi, fast_resonator, fast_plan, fast_loop, fast_reverb, fast_loudness (and fast_filter).  The note lists each one's kernels, shared headers, and compiler flags (several use `-ffp-contract=off` for exact mirrors).
- New C code goes in purpose-specific extensions (user preference), not `fast_sound`.  Shared helpers are `static inline` in `ext/mb/sound/include/mb_ext_helpers.h`; shared kernels in `ext/mb/sound/include/mb_*.h`.
- Every kernel has an exact Ruby mirror that specs compare sample for sample (keep operations identical, including float32 reads of signal inputs).
- `depend` files list each extension's headers (`rake depend:check`); after changing `depend` or removing a source, `rm -rf tmp/<platform>/<extension>`.

### Envelopes (`design/notes/envelopes.md`)

`MB::Sound::Envelope` (`fast_envelope`, mirror `Envelope.process_ruby`) is a state machine over curved segments landing exactly on target at whole samples.  Curves are signed dB (+60 falls like a 60 dB exponential, 0 linear, negative swells; presets `:analog` default, `:linear`, `:snappy`, `:gentle`, `:swell`, `:dx`, `:smooth`, `:pad`); shapes `:exp` or `:s`.  Multi-segment `env([[level, time, curve, shape], ...], release_at:, loop:)`; SQ-80 panel units via `sq80_env`.
- Times/levels/curves take numbers, Lengths, or nodes; inputs `gate:`, `trigger:`, `velocity:` (+ `sensitivity:`), `choke:`, `lift:`; `retrigger: :add` attacks to the energy sum.  Without a gate, notes release after `hold:`; without gate or trigger it's a one-shot.
- Constructors: `adsr`, `env`, `amp_env`, `fm_env`, `filter_env`/`filt_env`.  Kernel "runs" specialize only on constants of the patch (user rule).  `GraphNode#db` is gone: write `10 ** (node / 20)`.  Plot with `bin/plot_envelope.rb`.

### Tweening curves (`design/notes/curves.md`)

`MB::Sound::Curve` (`Curve[:elastic, overshoot:]`, many named easings, `Curve.db`/`Curve.s`, `bezier`, Procs; `#lookup` table in C) is shared by glides (`v.hz.glide(t, shape:)`), `tween([300.hz, 3000.hz], 1.bar, curve:)`, `smooth(t, curve:)`, and the antialiased shaper `sig.ease(curve, ...)` (`aease` exact).  `bounce_hits(2.bars, count:, elasticity:, decay:)` makes bouncing-ball rhythms.  Tween cutoffs as Pitches (biquad DC bumps at very low cutoffs).  Demos `bin/songs/tween_song.rb`, `bin/songs/bouncing_ball.rb`.

### Filters (`design/notes/filters.md`)

`lib/mb/sound/filter/` has 16+ filter types (`#process`/`#reset`); `Filter::Cookbook` has standard designs.
- Graph cookbook filters (`node.filter(:lowpass, cutoff:, quality:, gain:)`, `filter(150.hz.highpass(quality: 4))`, `peq`) build `Filter::SVF` (user decision): cookbook responses, parameters may move every sample without DC bumps.  `structure: :biquad` builds the old Cookbook biquad.
- `sig.lp4(cutoff, resonance:)` (`four_pole`): CEM3379-style 4-pole, `:db` resonance curve, no self-oscillation unless `self_oscillate: true`, `drive:`/`drive_mode:`, `mode:` taps, `quality:`; `v.reso(...)` in voices.
- `sig.diode(cutoff, resonance:)`: TB-303-style diode ladder with lp4's knobs, `normalize: true` (default) matches lp4's level and peak frequency.

### Delays (`design/notes/delays.md`)

`#delay` (`Filter::Delay`) and `#multitap` share `MB::Sound::DelayLine` (C reads, exact mirrors).  Interpolation `:sinc` default (no aliasing up to 4x), `:cubic`, `:linear`.  Delay times are any length or node (`96.samples`, `3.n16`, `lfo.samples`); `feedback:`/`wet:`/`dry:` numbers or nodes; `#delay` smooths time changes by default.  Tools: `bin/delay_gallery.rb`, `bin/delay_benchmark.rb`, `bin/delay_quality.rb`.

### Chorus (`design/notes/chorus.md`)

`sig.chorus(:juno1 | :juno2 | :juno12 | :lush, rate:, depth:, mix:, bbd: false)` (`GraphNode::Chorus`, self-contained for a later effects project): Juno-60-style two-tap chorus returning a stereo bundle; mono in like the Juno; clean by default, `bbd: true` adds the board's filters and hiss.

### Reverbs (`design/notes/reverbs.md`)

`#reverb` (`GraphNode::Reverb`, `fast_reverb` kernel, mirror `MB_SOUND_REVERB=ruby`) is the one reverb (FdnReverb removed).  `[l, r].reverb(:hall)`: inputs → diffusion → FDN (per sample) → output taps; energy-normalized gains.
- Classic presets `:room`, `:hall`, `:stadium`, `:space`, `:default` (kept close to 2026-01's sound); room-size presets `:plate`, `:shimmer`, `:grit`, `:lofi`, `:gated`, `:drone`; friendly form `room_size:`, `decay:`, `damping:` (exact design default), `mix:`.
- `mod:`/`diffusion_mod:` modulation presets; in-loop `lowpass:`, `highpass:`, `drive:`, `crush:`, `shimmer:`, `freeze:`, `stretch:`; after the network `duck:` and `gate:`.  `show_internals: true` builds it as nodes for graphviz.  Not built: an insert block, reverse reverb.

### Drum machines (`design/notes/drums.md`)

`tr808(source, **knobs)` (`lib/mb/sound/drums.rb`, `drums/`): a TR-808-flavored `Drums::Kit` of resonator, metal-bank, and noise voices, driven by a grid `Sequence::Kit` or any MIDI source (`TR808::GM_MAP`); per-voice knob Hashes; `velocity_curve:`/`accent:`; `more_cowbell:`; `outputs: :separate` returns named Channels.  Demo `bin/songs/drums_808.rb`, MIDI script `bin/synths/drums_808.rb`.

### Sequences (`design/notes/sequences.md`)

`lib/mb/sound/sequence/`: immutable `Clip`s of `Event`s in exact Rational whole notes, built with `seq(C4, E4, G4.n4).n8`, `grid('x...x...')`, note length methods (`n4`, `.d`, `.t`).  A clip is a MIDI source: `clip.stream`, and node methods from `clip.notes` (`clip.env`, `clip.tone`, `clip.freq`, `clip.gate`, `clip.trigger`; each call makes its own Notes, so share `n = clip.notes`); `clip.synth(voices:) { |v, i| }`.
- Edges land on exact samples at a shared `Transport`'s tempo; looping clips follow the timeline (`align: :launch` counts from the launch); launches and swaps land on the floor sample of their time.
- Transforms: `legato`, `reverse`, `permute`, `rotate`, `transpose`; feel and chance: `humanize`, `quantize`, `swing`, `chance`/`maybe`, `every`, `Clip::Variation`s (`vary: true`), `bake(fx)`; generators `euclid`, `melody`.
- Note marks: accent `!A1`, slide `~A1`, `up`/`dn`/`oct`; `Rest`/`R`, `Tie`/`T`; `Seq#acid` and `acid(...)` for 303 patterns; voice helpers `v.accent`, `v.accent_sweep`, `v.acid_env`; demo `bin/synths/acid.rb`, `bin/songs/acid_song.rb`.  `!` is overridden only on Note and Step (test with `nil?`, never `!x`).
- `swap :bass, bass2` changes a player's clips on the next bar, keeping graph state; derived clips are rederived.  Demos `bin/songs/sequence_demo.rb`, `swap_song.rb`.

### Tempo sync (`design/notes/tempo_sync.md`)

`Sequence::Duration` lengths work wherever lengths do.  `1.beat.hz` is a Pitch from a `Sequence::TempoNode`; tones from it lock their phase to the timeline on jumps (`.freewheel` to keep running while paused).  `sig.delay(1.n8.dotted)` follows the tempo.  `Session` finds `TimelineNode`s in every graph; `render(bars:)` counts bars on the timeline.  Demo `bin/songs/tempo_song.rb`.

### Multichannel (`design/notes/multichannel.md`)

Nodes have `outputs`/`channel_count`; `GraphNode::Channels` is the bundle (`stereo(l, r)`, `channels(a, b, c)`; Array-like but deliberately not Enumerable).  DSL calls on bundles run per channel (NumPy-style broadcasting; per-channel args via bundles, `channels(...)`, `spread(a..b)`); `reverb` is the exception (one reverb for all channels).  Conversions are `GraphNode::ChannelMixer` nodes: `pan`/`balance`, `width`, `mono`, `swap`, `mid_side`, `matrix`, `place`, `left`/`right`.  Sample all outputs of a mixer in turn.  Demo `bin/songs/stereo_song.rb`.

### Master effects (`design/notes/master_effects.md`)

`Session#master` / console `master { |mix| mix.softclip }` runs the mix through a chain of `GraphNode::MixSource` channels; new chains start at launch points with the old one spilling over (`fade:` crossfades, `fade: 0` cuts); `master nil` bypasses; `render` adds the tail.  `resample`/`oversample` can't be used in a master chain yet.

### Audio I/O (`design/notes/audio_io.md`)

Device I/O through bundled miniaudio (`fast_audio`), plus a small JACK backend (one client per process, ports added any time; user requirement).  `OUTPUT_TYPE`/`INPUT_TYPE`: `device` (default), `ffmpeg` (output), `null`.  `DeviceOutput` writes a lock-free ring drained on the device thread (Ruby never on the audio thread); the card's clock paces the Session.
- Latency profiles `:default` (512/128/50 ms), `:low`, `:video`, `:safe` (`AUDIO_PROFILE`, `-L`, `latency :low`); adaptive queue; live MIDI switches to `:low`.  Graphs stay at 48 kHz and the writer resamples to the card's rate.  Env: `AUDIO_BACKEND`, `OUTPUT_DEVICE`, `AUDIO_SAMPLE_RATE`, `JACK_CLIENT_NAME`, ...
- bin/ scripts set `RUBY_THREAD_TIMESLICE=10` in their shebang (busy threads starve the writer otherwise).  Tools: `bin/audio_check.rb`, `bin/audio_load_check.rb`.

### Scripts (`design/notes/scripts.md`)

Every bin/ script except `bin/sound.rb` uses a `ScriptingMethods` helper (backed by `ScriptRunner`): `effect_script { |input, p| }` (file or live input, rung out with `Ringdown`; `-m` MIDI controls), `synth_script { |midi, p| }` (`midi` is a `Notes`; file renders ring out), `song_script(bars:) { |p| }` (`-b`, `--bpm`), `script(args:) { |args, p| }`.
- Shared options: `-o` render, `-f`, `-g` graphviz, `-P` plot, `-q`, `-L`.  Parameters are options only: `name: [default, 'description', '-x', Type, range]`.  `p.midi_cc(1, :hz, range:)` is a controller when MIDI is open, else a constant.  Graph-building code goes inside the block; guard loadable scripts with `if main_script?(__FILE__)`.
- Shebang `#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby` (checked by `spec/bin/shebang_spec.rb`); live paths call `MB::Sound.warm_up` for YJIT.  `ruby bin/x.rb` and specs run without YJIT.

### MIDI (`design/notes/midi.md`)

`lib/mb/sound/midi/` is pull-based (no callbacks; only live input reads a clock): Sources make Events, Streams share them among readers, `Notes` turns them into signal nodes, `Synth` allocates voices.
- `MIDI::Event` is the one message type (normalized values, 0-based channels, Rational seconds).  Sources: `FileSource`, `ClipSource`, `LiveSource` (`MIDI_TIMING=exact` keeps a constant latency; JACK input is sample-exact).  `MIDI::Stream` fans out with per-reader cursors and makes transform views.
- `MB::Sound::Notes` (`v` in synth code): `gate`, `trigger`, `number`, `velocity`, `freq`, channel-wide controllers (`bend`, `pressure`, `cc(n)`, GM-named `mod`, ...; smoothed by default), envelopes (`amp_env` etc. with GM2 scaling), `v.hz` key-synced NotePitch (`.glide`, `.vibrato`, `.bend_range`), `v.key_trigger` (no reset on energy-adding re-strikes, user rule), `v.cutoff`, `v.reso`, `v.lfo`, `v.mod_sum`/`mod_scale`, `poly_pressure`, `aftertouch`.
- `MIDI::Allocator` lanes with `steal:` chains and `retrigger:` modes; `Synth.new(source, voices:, spares:, retrigger:, skip_idle:) { |v, i| }` (`:string` and `:ring` presets); `ended?` once the source is over and lanes are quiet.
- MIDI transforms on Streams/Notes/Clips: `echo`, `arp`, `chord`, `strum`, `humanize`, `quantize`, `snap`, `transpose`, `select`/`reject`, `split`, `merge`, ...; unattached chains via console `echo(...)` etc. with `stream.through(fx)` / `clip.bake(fx)`.  Demo `bin/songs/midi_transforms_song.rb`.
- Live MIDI uses JACK MIDI ports when a JACK server answers, else bundled RtMidi (CoreMIDI/ALSA); `MIDI_API`, `MIDI_DEVICE`; `bin/midi_check.rb` diagnoses.  JACK specs use a private dummy server (`spec/support/jack_dummy.rb`, one at a time via a lock file).  `MIDI::ControlMap` lists controllers and writes ACID DAW XML (`--acid-xml`).
- Console: `midi` (a Notes on live input), `midi_file(path)`.

### Sibling Libraries

- `mb-math` - Math utilities (GitHub dependency)
- `mb-util` - General utilities (GitHub dependency)

## Collaboration

How the maintainer likes agentic work to go (decisions, questions, honesty, API taste, process) is in @.claude/collaboration.md.  Skills: `post-merge` (steps after every merge) and `agent-brief` (briefing background agents), in `.claude/skills/`.

## Source Control

- Use worktrees (and branches) for feature development; new worktrees go in `.claude/worktrees/` and need `bundle exec rake compile` before specs run
- Commit progress and experimentation incrementally, as step-by-step commits with detailed messages for easy review
- Use non-fast-forward merge commits when features are complete
- The trunk branch is `master-ai` (upstream GitHub trunk is `master`; the old unconnected local history is tagged `local-master-pre-reconcile`)
- Local development; no push to remote
- Before merging, check which branch the main checkout (`/app`) is on; the user switches branches there.  If `/app` isn't on `master-ai`, merge in the feature's worktree (`git checkout master-ai` there) instead of switching `/app`.  Write merge messages to a file for `git merge -F file` (`-F -` doesn't read stdin).

## Key Conventions

- Ruby 4.0+ required (gemspec, CI, `.ruby-version`); Bundler 4 (the lockfile's `BUNDLED WITH`)
- Tests use RSpec (configured in `.rspec`)
- Docker support via `Dockerfile` and `dock.sh` for containerized development
- `Numo::NArray` for all sound data handling (choose numeric precision and real/complex as needed)
- Errors that must not stop a live set go through `MB::Sound.live_error(exception)` (`LiveMethods`): it raises in scripts and specs and warns (returning nil, so the caller skips the change or falls back) in live mode (`bin/sound.rb`).  Use it whenever an error would otherwise interrupt live playback (Tone's build-time settings, feedback loop fallbacks).

## Working Notes (lessons learned)

### Verifying audio without speakers

The container has no audio device, so check sound-producing code by rendering it: `MB::Sound.render('file.flac', graph, bars: 4)` or loops of `node.sample(800)`, then look at peak levels, silent stretches, and exact sample offsets of note edges.  Use `NullOutput.new(..., sleep: false)` and `Session.new(realtime: false)` with `#process_buffer` for fast, deterministic tests.  To check that events happened (e.g. a swap landed on its bar), trace internal state from a scheduled block; spectral checks of the mix are easily fooled by other parts.  Leave listening to the user (on a Mac) with copy-pasteable snippets and expected results, and keep good snippets in demo script header comments.

### Gotchas

- `#sample` usually returns a reused buffer; `.dup` each buffer before collecting several of them (several false "bugs" came from forgetting this).  It may also be frozen (a Tee's shared buffer): copy before modifying a buffer you didn't create.
- A Tee branch that is never read keeps its Tee copying until the branch falls a whole CircularBuffer (1 s) behind, and raises `BranchBufferOverflow` if read later; benchmarks that reuse one node in two graphs sampled separately hit this.
- Oscillators (`Tone`, `noise`) are full scale (-1..1) by default, and the master bus (`Session#master_gain`, `master_gain -6.db`, `render(gain:)`) is -10 dB by default, live and in renders, so mixes of full-scale parts have headroom; effect scripts set it to 0 dB, since they process recordings with their own levels.  Check levels by rendering.
- Oscillators and constants play forever (there is no `.for`/`.forever`); sounds end through envelopes (one-shots without gate or trigger; gated or triggered ones, as in voices and clips, never end by themselves), clips, files, `x.until(seconds)` or `x.until(2.bars)` (`GraphNode::TimeLimit`, a hard cut; musical lengths follow the tempo, counted from the node's first sample), `and_then`, or `MB::Sound.silence(s)` (zeros, then the end; e.g. tails via `and_then(silence(s))`).  `play` of a graph says to press Ctrl-C, `write` caps graphs at `MAX_RENDER_SECONDS`, and `fft`/`plot`/`write` given a bare Tone or Pitch take one second of it.
- `40.hz` is a Pitch that plays as a sine when used as a signal, not a constant; use `40.constant` for fixed values in arithmetic, and `pitch.transpose(n)` or `(f * 2).hz` to change frequencies (`440.hz * 2` doubles the sine's amplitude).
- `Numeric#samples` is a `Length::Samples` (it used to return seconds at 48 kHz), and `#delay`/`#multitap` have no `samples:`/`sample_rate:` options: write `delay(96.samples)` or `delay(lfo.samples)` (counted at the running rate).  A plain node or number is seconds; `smooth(0.1)` and `smooth(4800.samples)` replace `smooth(seconds:/samples:)`.
- Use the `a*` names (`aramp`, `aclip`, ...) or `.lfo` for control signals that must keep exact edges (delay times, gates, phases), and remember that `softclip`/`clip`/`abs`/`quantize` add half a sample of delay (null tests against older renders show a -20 to -30 dB residual; align by half a sample to compare).  An edge landing exactly on a sample is a classic rounding trap in these kernels (phases snap within 1e-9 of an edge).
- The container compiles with GCC, which never warns about unused `static inline` functions; the user's Mac uses clang, which does for functions defined in a `.c` file (not in headers), and `-Werror` makes that a build failure.  After C changes, check that every static function in a `.c` file is still called.
- `Numo::Pocketfft.rfft` (and `ifft` of a complex view) read an NArray view like `x[100..]` from its parent's start; `MB::Sound.fft`/`ifft`/`real_fft`/`real_ifft` copy their input, but `.dup` views before calling Pocketfft directly.
- `node.filter(cookbook_filter)` copies the filter's cutoff and quality into constant inputs (and, by default, into a new `Filter::SVF`), so changing the Cookbook's `center_frequency` from outside (e.g. a MIDI callback) does nothing; pass `cutoff:` a node and change the node.
- `multitap` and other multi-output results are `Channels` bundles, which are deliberately not Enumerable (`.to_a` for `shuffle`, `reverse`, etc.).
- C4 = 60 (C3 = 48).  Derive expected values in specs from note constants or a quick script; hand-computed notes and offsets caused several wrong assertions.
- A realtime Session's render thread runs until `close`; close sessions in spec `after` blocks.  `kill -QUIT <pid>` prints every thread's backtrace (`MB::U.sigquit_backtrace`, set up in spec_helper).
- Before adding `bin/sound.rb` commands, check for collisions with `MB::Sound` methods and Pry commands (`Pry::Commands`; e.g. `reset` and `watch` are taken).

### Process

- In multi-step shell scripts, use `set -euo pipefail`, don't pipe away exit codes, and put commands on separate lines (a failure inside `a && b` doesn't stop the script; a batch loop that kept going after a failure once produced broken commits).
- Use the Edit tool for multi-line code changes; ad hoc Python/sed replacements often failed on indentation or escaping.  Never `sed -i` the Rakefile: on the Mac's case-insensitive `/app` mount it once left a stale lowercase `rakefile` entry that rake loads first (`LoadError ... rakefile`; `rake -f Rakefile` works around it).
- Memcheck (selective by default for branches): run `rake -f Rakefile memcheck:changed` before merging branches that touch `ext/` or code calling extensions; it selects specs from `spec/valgrind/memcheck_map.json` (changed extension dirs, users of changed shared headers, `lib/` files naming a `Fast*` module, changed memcheck specs; the full list for suppressions, `gc_stress_calls.rb`, `mb_ext_helpers.h`, the Rakefile memcheck section, a new extension, or over half the extensions; rules in `spec/valgrind/memcheck_selection.rb`).  Selections range from under a minute (one small extension: fast_resonator's 2 spec files took 0.7 min in Valgrind, 2026-10-09) to most of the full run (fast_sound and fast_arithmetic reach 37 and 31 of the 58 spec files; `lib/mb/sound/tone.rb` names four extensions).  Run the full `rake memcheck` when `memcheck:changed`/`memcheck:status` says it is due (every 3 merges that changed `ext/` since the last full run, or 7 days; `FULL=auto` escalates) and at checkpoint merges; it records `tmp/memcheck_full.stamp` in the main checkout (until one exists the policy counts from `MemcheckSelection::FULL_BASELINE`, the 2026-10-09 feedback-loops tip; per the user, the first full run waits until the policy says it is due) and rerecords the map (commit `memcheck_map.json` afterwards).  Every selection that runs anything also runs `spec/lib/mb/sound/graph_sweep_spec.rb` (`MemcheckSelection::ALWAYS`, "memcheck light": every GraphNode/multi-output/Filter class and every filter type from the filters' own type lists, in small graphs with modulated inputs, MIDI clips and Synths, stereo bundles, and feedback loops, planned and unplanned at 1/128/800-sample buffers, `:check_shared`; ~4 s natively, est. ~2 min under Valgrind; its guard fails for a new node class until the sweep builds it or `GraphSweep::EXEMPT` says why not).  New memcheck specs go in `MemcheckSelection::SPECS` and run in every selective run until the map is refreshed (`rake memcheck:map`, ~5 min natively).
- After merging (or rebasing onto) changes that touch `ext/`, run `bundle exec rake -f Rakefile clean compile` and check that it succeeds before trusting specs: a stale `.so` from before the merge loads fine and lets the suite pass while the merged C doesn't build (2026-10-06: gc-fixes changed `mb_read_signal_input`'s signature, and the four-pole and wavetable kernels from parallel branches still used the old one; git merged them cleanly).  When changing a helper in `mb_ext_helpers.h`, search the other active branches for callers.
- Kill only processes you started, by PID (never `pkill -f`): parallel sessions and agents run their own Valgrind, JACK, and spec processes.  Write commit messages to a file for `git commit -F` (a shell slip once left a title-only commit).
- Benchmarks are noisy when another session is compiling or running specs: alternate runs of the old and new code (e.g. a temporary master-ai worktree) instead of comparing against remembered numbers.
- Keep command output small (grep/head/tail, Read with offsets); large tool output fills the context quickly.
- Measure before explaining a failure; the first theory for the macOS latency problem was wrong, and a small experiment found the real cause.
- The user often says "note for later": record those in local memory (themed idea files), not GitHub, and implement them only after an explicit go-ahead.
- Preserve research side quests (prototypes, measurements, studies by research agents) before their worktree is removed; a gitignored `tmp/` is lost with it.  One study per branch `research-<topic>` off master-ai, never merged (`git branch --list 'research-*'` finds them), with everything in `research/<topic>/`: a `README.md` (the question in the user's words, date, method, result, what was decided, where any proposal lives), the prototypes and measurement scripts, and small results (tables, plots under about 1 MB each).  Leave out large regenerable data and renders, with a line saying how to regenerate them.  Commit once with a detailed message (the usual attribution lines), and point to the branch and commit from the proposal or notes that discuss the study.  Example: `research-scurve`.
