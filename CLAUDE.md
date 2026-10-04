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
bundle exec rake memcheck         # C extension specs under Valgrind (~6 min; options in Rakefile)
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

`lib/mb/sound/numeric_sound_mixins.rb` adds methods like `.hz`, `.db`, `.meters`, `.bits` to Ruby's Numeric class, enabling the fluent DSL (e.g. `440.hz.sine`, `-20.db`).  `440.hz` is a `Pitch` (`lib/mb/sound/pitch.rb`): a light frequency source whose oscillator methods (`sine`, `ramp`, `at`, `fm`, `pm`, `lfo`, `tone`/`hz`, `phasor`) make a new `Tone` each call, which plays as a full-scale sine when used directly as a signal, and which sequences can hold as a fixed frequency (`seq(C4, 440.hz)`).  `Note < Pitch` (C4 = 60) gets its frequency from the session `Tuning` (`tuning b4: 480`, live).  Oscillators run from a `Phasor` (phase in cycles; `lib/mb/sound/phasor.rb`).  `tuning` in a scheduled block changes on the block's time (`Session#at_time`).  `Sequence::NumericDurations` adds musical lengths (`2.bars`, `3.beats`, `3.n16`, `3.sixteenths`, `1.n8.dotted`) returning `Sequence::Duration`s; see Tempo sync below.  `MB::Sound::Length` (`lib/mb/sound/length.rb`) adds `Length::Seconds` (`4.seconds`, `250.ms`) and `Length::Samples` (`5.samples`, counted at the sample rate where used, so inside `oversample` too) beside `Duration`, sharing one protocol (`to_seconds`/`to_samples`/`to_whole_notes`); `node.samples` / `node.seconds` mark a node's unit.  Every method that takes a length of time accepts all of them plus plain numbers in its usual unit (seconds for delays, envelopes, `until`, `silence`, `render(seconds:)`; bars for fades and schedules; samples for `with_buffer`), via `Length.seconds`/`Length.samples` or `Duration.bars`/`Duration.whole_notes` (Seconds/Samples at the current tempo).  Changing lengths (delay times) go through `Length::Source`, which keeps the unit and converts per buffer at the current rate.

### Oscillators and antialiasing

Tone waveforms are antialiased by default (`lib/mb/sound/band_limit.rb`, kernels in the `fast_synth` extension); every shape has a naive (aliased) `a*` twin for lo-fi sounds and control signals.  Measure any expression with `bin/aliasing.rb 'p.ramp' 'p.aramp'` (coherent-sampling aliasing table and cost; `--render DIR` writes 100 Hz-8 kHz sweeps with spectrograms).

- `ramp`/`saw`, `square`, `triangle` use PolyBLEP/PolyBLAMP (corrections on the samples either side of each edge, found on the phase plus phase modulation, so FM/PM and through-zero motion work); `aramp`/`asaw`, `asquare`, `atriangle` are naive.  The low-level `Oscillator` is naive unless `band_limit: true`.  `.lfo` fades band-limiting in from 15 to 30 Hz (`BandLimit::LFO_FADE`), so slow LFOs keep exact jumps (delay times, gates) and audio-rate "LFOs" are clean.  `#wavetable` switches a ramp phase to `aramp` (a phase must wrap exactly).
- `pwm(width)` (alias `skew`; width a number or node) warps the phase of any shape: `square` → pulse (`pulse(w)`/`apulse(w)`), `triangle.skew(0.1)` → near-saw, `sine.pwm(w)` → CZ-style phase distortion; DC offset removed by default (`dc: true` keeps it).  The warp's corners are band-limited too.
- `complex_ramp`/`complex_square`/`complex_triangle` are closed-form band-limited impulse trains, integrated (`BandLimit.blit_ruby`): no aliasing or negative frequencies (-153 dB), top octave lifted ~2.6 dB; with phase modulation they fall back to the naive `acomplex_*`.
- `sync(ratio: r)` hard-syncs a tone to a hidden master at its own pitch (playing at pitch × r; r a number or node), `sync(master)` to a Pitch/Tone/Phasor (its `wraps` port) or any trigger node; `softsync` reverses direction instead.  Synced tones use a causal minBLEP/minBLAMP kernel (ramp/square -100 to -108 dB); no phase modulation with sync.
- `Oscillator#reset` (MIDI note-ons), `#phi=`, and `#sync_cycles` (tempo LFO locks) turn the phase jump into a band-limited step over the next 32 samples.
- `softclip`, `clip`, `abs`, numeric `quantize` use antiderivative antialiasing on the excess over the linear part plus a half-sample Thiran allpass on the dry signal (`MB::Sound::Shaper`, `GraphNode::Shaper`, the `fast_clip` extension): flat level, half a sample of delay, aliases below the fundamental 25-56 dB lower; `asoftclip`, `aclip`, `aabs`, `aquantize` are the plain shapers (exact, for control signals).
- Ports (`GraphNode::Ports`): side outputs that aren't audio channels, made on first use: `phasor.wraps`/`tone.wraps` (sync pulses valued 1 - d, where d is the sub-sample position of the wrap) and `.increment`; `node.ports`, `port_info`, `inputs`.  A node with ports computes frames; every reader (main output and ports) must read each buffer, as a Session does.
- Still aliasing: FM/PM sidebands (use `oversample`), wavetables (mipmaps planned), `gauss`, naive `a*` shapes.  Demo and A/B snippets: `bin/songs/antialias_song.rb`.

### Method Modules

`MB::Sound` extends several method modules that provide the top-level API available in `bin/sound.rb`:
- `IOMethods` - File read/write via ffmpeg
- `PlaybackMethods` - `play`, `input`, real-time audio, plus the background session:
  - `bg` / `stop` / `outro` (alias `fadeout`) / `panic` / `players` / `resume` / `stopped` / `forget` play sounds in the background through one shared `Session` (`lib/mb/sound/session.rb`) that mixes every player in a single render loop locked to the sequence timeline
  - `swap` changes the clips a player plays without rebuilding its graph; `master` (alias `master_fx`) sets master effects on the mix (see Sequences and Master effects below)
  - `visualize` (alias `vis`) plots the mix live; `render` runs a `Session` into a file (or any output object); `wait` blocks until everything has ended, including master effects tails (use it at the end of scripts); `use_output` sets the background session's output (see Audio I/O below)
- `MultichannelMethods` - `channels`, `stereo`, `spread` build multichannel signals and per-channel arguments (see Multichannel below)
- `ScheduleMethods` - `at_bar` (alias `on_bar`) / `after` / `every` / `scheduled` / `cancel` run blocks at bars on the `Session` timeline; `bg`/`stop`/`resume`/`bpm` inside them take effect exactly at the scheduled time (see `bin/songs/scheduled_song.rb`)
- `PlotMethods` - Terminal/gnuplot visualization
- `FFTMethods` - Spectral analysis
- `ScriptingMethods` - `effect_script` / `synth_script` / `song_script` / `script` for standalone scripts in bin/ (see Scripts below)
- `GainMethods`, `WindowMethods`, `AnalysisMethods`

### C Extensions (compiled via rake-compiler)

- `ext/mb/fast_sound/` - Fast waveform generation → `lib/mb/fast_sound.so`
- `ext/mb/sound/fast_resample/` - libsamplerate bindings → `lib/mb/sound/fast_resample.so`
- `ext/mb/sound/fast_wavetable/` - Fast wavetable synthesis → `lib/mb/sound/fast_wavetable.so`
- `ext/mb/sound/fast_delay/` - Delay line read/feedback kernels (`DelayLine`) → `lib/mb/sound/fast_delay.so`
- `ext/mb/sound/fast_synth/` - Band-limited oscillators (`FastSynth.oscillate_bl`, `.blit`, `.oscillate_sync`; see Oscillators and antialiasing) → `lib/mb/sound/fast_synth.so`
- `ext/mb/sound/fast_clip/` - Antialiased waveshapers (`FastClip.shape`) → `lib/mb/sound/fast_clip.so`
- `ext/mb/sound/fast_audio/` - Sound card I/O through bundled miniaudio (`DeviceOutput`; see Audio I/O) → `lib/mb/sound/fast_audio.so`

New C code goes in purpose-specific extensions (the user's preference) rather than growing `fast_sound`; helpers shared between them (`mb_wrap`, `mb_ensure_inplace_sfloat`, `mb_read_signal_input`, ...) are `static inline` in `ext/mb/sound/include/mb_ext_helpers.h`, added to the include path by each `extconf.rb`.  Each kernel has an exact Ruby mirror that specs compare sample for sample (keep the operations identical, including float32 reads of signal inputs).  `depend` files list an extension's headers (rake doesn't rebuild on header changes otherwise); after changing `depend` or removing a source file, `rm -rf tmp/<platform>/<extension>` so the Makefile is regenerated.

### Filter System

`lib/mb/sound/filter/` contains 16+ filter types (Biquad, FIR, Butterworth, Hilbert, Delay, etc.). Filters implement `#process` / `#reset`. `Filter::Cookbook` provides standard designs (lowpass, highpass, bandpass, etc.).

### Delays

`Filter::Delay` (`#delay`) and `GraphNode::MultitapDelay` (`#multitap`) are front ends for one `MB::Sound::DelayLine` (`lib/mb/sound/delay_line.rb`): a circular buffer that grows without losing stored audio, read in C (`MB::Sound::FastDelay.read` / `.feedback`, the `fast_delay` extension) with Ruby mirrors (`#read_ruby` / `#feedback_ruby`) that specs check for exactly equal values.  Interpolation (`interpolation:`) defaults to `:sinc` (`DelayLine::DEFAULT_INTERPOLATION`; Kaiser-windowed, cutoff lowered by the read speed when a moving delay raises the pitch, so no aliasing up to 4x); `:cubic` and `:linear` (the old lo-fi sound) are options.  Constant whole-sample delays read directly in every mode; a moving or fractional `:sinc` delay costs ~1.5-2% of realtime per mono delay.  No mode reads samples newer than the current input.  Delay times are any length (`0.01`, `250.ms`, `96.samples`, `3.n16`, nodes, `node.samples`) held as `Length::Source`, so they keep their unit when the sample rate changes and rate changes rebuild nothing (no new Tee branches); fractional constant delays are kept (snapped within 1e-9 of whole samples).  `feedback:`, `wet:`, and `dry:` may be numbers or graph nodes; `#delay` smooths delay changes by default (`smoothing:`), `#multitap` only with `smoothing:`.  Tools: `bin/delay_gallery.rb` (null-test cases), `bin/delay_benchmark.rb` (`--interpolation`), `bin/delay_quality.rb` (error and aliasing against an exact sine answer).

### Reverbs

Two reverb implementations coexist; use `#reverb` in most cases:

- `GraphNode::Reverb` / `#reverb` (`lib/mb/sound/graph_node/reverb.rb`) - the original from the reverb video; presets (`:room`, `:hall`, `:space`, ...).  `[l, r].reverb(:hall)` takes one input per Array element.  Its diffusion and feedback network runs as one fused stage (`Reverb::FusedStage`; `show_internals: true` builds the old node graph, which specs check gives identical samples) with C matrix mixing (`MB::FastSound.matrix_mix`, also used by `ChannelMixer` for real numeric gains).  Stereo cost (2026-10-03): `:hall` ~4% of realtime, `:space` ~6.5% (were ~18% and ~55%).
- `GraphNode::FdnReverb` / `#fdn_reverb` - an experiment (clean-room, by Claude Code) with `room_size`/`decay`/`damping`; ~7% of realtime in stereo (2026-10-03, after the matrix kernel; was ~20-70%); may be removed once `#reverb` gets similar parameters.

### Sequences

`lib/mb/sound/sequence/` (`MB::Sound::Sequence`) holds musical sequences: immutable `Clip`s of `Event`s timed in exact Rational whole notes, built with `seq` (e.g. `seq(C4, E4, G4.n4).n8`), `grid` (drum step strings like `'x...x...'`), and note length methods on `Note` (`n1`-`n8`, `n12`-`n128`, `.d`, `.t`, long names). Clips play in node graphs through `ClipNode` outputs (`clip.env`, `clip.tone`, `clip.gate`, `clip.trigger`, `clip.number`) that land edges on exact samples, at the tempo of a shared `Transport` (`bpm 120`). `legato(0.85)` shortens notes without changing the rhythm. `reverse` (alias `retrograde`) mirrors a clip or reverses a Seq's steps; `permute([2, 0, 1])` / `permute(seed: 3)` (alias `shuffle`) moves notes among the same rhythm, repeatably from the clip's seed. In a `Session`, looping clips play in phase with the transport timeline (`seek`, `rewind`), so graphs started at different times stay in sync. See `bin/songs/sequence_demo.rb`.

`swap :bass, bass2` (`Session#swap`, `lib/mb/sound/session/clip_swaps.rb`) changes a player's clips on the next bar via `ClipNode#swap_clip` (exact sample, graph and effect state kept). Transformed clips remember their `source` and transform (`Clip#lineage` / `#rederive`), so clips derived from the old one (`bass.transpose(12)`, `synth` voices) are rebuilt from the new one; pass `old => new` pairs (or `kit => kit2` for `grid` rows) when a player has unrelated clips. See `bin/songs/swap_song.rb`.

### Tempo sync

`Sequence::Duration` (`lib/mb/sound/sequence/duration.rb`) is an exact musical length in whole notes (comparable, `+`/`-`, scaled by numbers, friendly `to_s` like "3 × n16"), accepted wherever lengths are (`at:`, `fade:`, `every`, `after`, `render(bars:)`, `.len`, `until`).  `1.beat.hz` is a Pitch whose frequency comes from a `Sequence::TempoNode` following the tempo, and `4.bars.lfo` a Tone from it; the TempoNode locks the phase of every oscillator made from the pitch (its followers) to the timeline on jumps (start, seeks, resume) plus `with_phase`; they freeze while the timeline is paused unless `.freewheel`.  `sig.delay(1.n8.dotted)` (or `sig.filter(3.n16.delay(...))`, `multitap(1.n8.d, ...)`) follows the tempo; `2.bars.lfo.square.at(3.n16..5.n16)` gives an alternating delay time (`Tone#musical_time?`).  Plain numbers in `delay` are seconds; `delay(96.samples)` / `delay(lfo.samples)` count samples at the running rate (there is no `samples:` or `sample_rate:` option).  Tempo-following nodes include `Sequence::TimelineNode` (shared with `ClipNode`), which `Session` finds in every graph (`timeline_nodes`).  `Tone#lfo` means full range plus no MIDI retrigger.  `render(bars:)` counts bars on the timeline, so tempo changes during a render are followed; `tail: true` adds the master effects tail after the limit.  See `bin/songs/tempo_song.rb`.

### Multichannel

Every GraphNode has `outputs` (`[self]` for one channel) and `channel_count`; nodes with several outputs (stereo file inputs, multi-output reverbs, `MultiOutput`s) act as bundles.  `GraphNode::Channels` (`lib/mb/sound/graph_node/channels.rb`) is the bundle class: `stereo(l, r)`, `channels(a, b, c)`, `[l, r].channels`, `node.stereo`; it is Array-like (`[]`, `each`, `map`, `l, r = bundle`) but deliberately not Enumerable (`Enumerable#filter` is `select`).  `GraphNode::ChannelDispatch` (loaded last in `graph_node.rb`) generates a per-channel version of every `*Methods` module method, so DSL calls on a bundle run per channel and return a bundle; single-channel nodes run unchanged.  Channel counts combine like NumPy broadcasting (1 is reused, N-N per channel, other mismatches raise); per-channel arguments are bundles, `channels(0.010, 0.013)` of plain values, or lazy `spread(a..b)`; filter objects are Marshal-copied per channel.  `reverb` is the deliberate exception: a bundle's channels all feed one reverb.  Conversions are `GraphNode::ChannelMixer` nodes (`lib/mb/sound/graph_node/channel_mixer/`): one N-in/M-out gain-matrix node per call, a subclass per mixing law declaring its channel counts, `param`s (numbers or nodes read every sample; numeric gains are computed once) and `option`s, with `#params`/`#gains`/class-level `.params` for introspection.  `pan(pos, law:)` (`ChannelMixer::Pan`; laws `:equal_power` default, `:minus_4_5db`, `:linear`; stereo bundles balance, the common DAW default, also `balance`), `width(w)`, `mono`/`mixdown`, `swap`, `mid_side`/`from_mid_side`, `matrix(rows)` (any N->M, entries numbers, complex, or nodes; replaced `MatrixMixer`), `place(x:, y:)` (alias `position`; phase-amplitude Lt/Rt positioning, replaced `ComplexPan`), plus `left`/`right`.  Complex gains send every input through the same Hilbert stage (`ChannelMixer::Analytic`) and output real parts unless an input was complex.  Mixer outputs advance to a new frame when an output is sampled again, so sample all outputs of a mixer in turn (as a Session does).  `master { |mix| ... }` gets the whole mix as a bundle.  `graphviz` collapses each per-channel call into one box listing per-channel arguments (`expand_channels: true` shows every node).  Deferred: layouts/surround matrix presets (research report in local notes; user's private surround work), encoder-aware `place` laws, dual/stereo pan modes, `.widen`/`.haas` and ping-pong (effects project), `Mixer` accepting bundles, mixer fusion (waits for the graph optimizer), vectorized N-channel nodes.  See `bin/songs/stereo_song.rb`.

### Master effects

`Session#master` (`lib/mb/sound/session/master.rb`, console `master { |mix| mix.softclip }`) runs the whole mix through a chain built on `GraphNode::MixSource` channels (one param = the mix as a stereo bundle, N params = one per channel; `master nil` bypasses). New chains start at `bg`-style launch points; by default the old chain "spills over" (fed silence from the switch sample so tails ring out, dropped after 1s below -90dB or 10s), `fade:` crossfades, `fade: 0` cuts (also used when the render load is over 60%). Chains keep processing while idle, `panic` rebuilds the chain to clear tails, and `render` adds the tail after the last player (10s cap). Nodes that change the sample count (`resample`, `oversample`) can't be used in a master chain yet. See Reverbs above for which reverbs are light enough for a live master chain.

### Audio I/O

Device I/O is being replaced by miniaudio in stages (the user's plan, 2026-10-04: 1 output, 2 device sample rate, 3 input, 4 MIDI via RtMidi, 5 switch defaults and remove JackFFI/JackOutput/JackInput/AlsaOutput/AlsaInput and the jackffi gem; ffmpeg stays for files and other ffmpeg outputs).  `MB::Sound::DeviceOutput` (`lib/mb/sound/device_output.rb`, `OUTPUT_TYPE=device`, opt-in until stage 5) writes into a lock-free ring that a C callback on miniaudio's device thread drains (`FastAudio::Playback` in `fast_audio`); Ruby never runs on the audio thread.  `#write` keeps at most `AUDIO_LATENCY` seconds queued, then waits without the GVL until the device has played half of it, so the sound card's clock paces the Session.  Latency profiles (`DeviceOutput::PROFILES`, `AUDIO_PROFILE` or `profile:`; chosen with `bin/audio_load_check.rb` on the user's old Mac): `:default` write 512 / period 128 / queue 50 ms (45-56 ms, clean with fm_bass, stereo_drone, and both), `:low` 256 / 128 / two writes (16-19 ms, light patches only), `:video` 400 / 128 / 50 ms (120 fps frames at 48 kHz; about 8-10 points more load than `:default`, so 512 stays the default per the user), `:safe` 800 / miniaudio's 480 / 85 ms (about 110 ms; 60 fps frames).  Offline renders take their own `render(buffer_size:)`.  Rerun `bin/audio_load_check.rb` (loads fm_bass, stereo_drone, oscillators, both) after big performance changes.  `AUDIO_BUFFER`, `AUDIO_PERIOD`, and `AUDIO_LATENCY` override a profile's settings.  Environment: `AUDIO_BACKEND` (e.g. `jack,pulseaudio`; on Linux JACK first only if a server runs, then PulseAudio/PipeWire, then ALSA; CoreAudio on macOS), `OUTPUT_DEVICE`/`DEVICE` (index or part of a name), `AUDIO_SAMPLE_RATE` (the rate written, 48000 by default), `JACK_CLIENT_NAME` (default: the script's name).  JACK servers are never started, ports are connected to the physical outputs once at startup, and later rewiring by qjackctl/qpwgraph/session managers is left alone.  Mono outputs open two channels.  Sample rates (stage 2, user's option C): graphs and Sessions stay at 48 kHz, and when the sound card runs at another rate (e.g. 44.1 kHz on the Mac after jackd changed it) the C extension resamples the mix with libsamplerate in the writer (`AUDIO_RESAMPLE`/`resample:` fastest sinc by default, ~0.8% CPU for stereo; medium, best, linear, zoh, or off to run at the card's rate); `#sample_rate` is the written rate, `#device_rate` the card's; `AUDIO_DEVICE_RATE` forces a card rate (the specs use it with the null device); `AUDIO_SET_DEVICE_RATE=1` lets CoreAudio switch the card's system-wide rate (miniaudio's allowNominalSampleRateChange).  `Session#sample_rate` is the output's; `Session#add` sets graphs at another rate to it, or resamples nodes that can't change rate (file inputs, raw Biquads); filenames open at it.  Most filters now have `sample_rate=` (FirstOrder, Butterworth, HilbertIIR, FIR from a gain Hash, Gain, FilterBank, envelope followers; specs in `filter/sample_rate_setters_spec.rb`), and DSL methods use the node's rate instead of 48000.  `AUDIO_BACKEND=null` uses miniaudio's null device (a timer-driven fake sound card, used by the specs).  `bin/audio_check.rb` lists devices and measures latency, underruns, and clock drift (`--busy` adds GVL contention).  A busy Ruby thread can starve the writer for a whole time slice (100 ms by default, longer than the queue; 131 underruns in 10 s on the user's Mac), so bin/ scripts set `RUBY_THREAD_TIMESLICE=10` in their shebang (user's choice; read only when Ruby starts, so `ruby bin/x.rb`, irb, and `fork_script` don't get it; 0 underruns measured).  A priority of -3 on the busy thread also works.  `use_output(obj_or_type)` gives the background session another output (refuses while players run); `render` accepts an output object; `OUTPUT_TYPE=ffmpeg` is any live ffmpeg output (`OUTPUT_FORMAT`, `OUTPUT_CODEC`, `OUTPUT_DEVICE` as the name or URL).

### Scripts

Every bin/ script except `bin/sound.rb` is built on one of four helpers in `ScriptingMethods`, backed by `ScriptRunner` (`lib/mb/sound/script_runner.rb`, OptionParser):

- `effect_script(input_channels:, live_channels:, **params) { |input, p| graph }` - the input is an audio file (first audio argument or `-i`, rung out with a `Ringdown` node until 1 s of quiet, 10 s cap) or live input (`-c/--input-channels`); `--repeat [COUNT]` loops the file.
- `synth_script(**params) { |midi_input, p| graph }` - `midi_input` is a MIDI file or JACK port name (or nil for live MIDI); pass it to `MB::Sound.synth` / `midi_manager` / `midi_file`.  A MIDI file rings out: after its last channel event (`MIDIFile#music_end`), nodes driven by it (`VoicePool`, MIDI DSL nodes) report `#ended?` and the runner stops after a second of quiet (10 s tail limit), like effect file inputs (`Ringdown#ended?`); the nodes themselves return nil only `MIDIFile::TAIL_SECONDS` later, for players without tail detection.
- `song_script(bars:, **params) { |p| ... }` - the block arranges the song on the current session (`bg`, `at_bar`, `master`); `-b/--bars N` plays or renders N bars (live too), `--bpm` sets the starting tempo and scales the song's tempo changes (`Transport#override_bpm`), `--graphviz` draws the session at the start (`Session#graph_view`).
- `script(args:, **params) { |args, p| ... }` - general scripts (utilities, plots, file processors, benchmarks, MIDI tools): only `-h/--help` is common, positional arguments go to the block (`args:` Integer/Range checks their count; negative numbers stay positional).

Effects, synths, and songs share `-o/--output` (or a positional audio file) to render instead of playing, `-f/--force`, `-g/--graphviz`, `-P/--plot`, `-q/--quiet`, and play through the background `Session`.  Parameters are options only (no positional numbers): `name: default` or `name: [default, 'description', '-x', Type, allowed_range_or_array, :required]` in any order after the default; bad values print the option help.  `p.midi_cc(1, :hz, range: 0.0..6.0)` gives a MidiDsl CC node starting at the parameter value (range relative to it, like `GraphVoice#on_cc`) with live JACK MIDI, else a constant.  Graph-building code belongs inside the block (`--graphviz` runs song blocks twice).  Guard scripts that can also be `load`ed with `if main_script?(__FILE__)`.  Every script starts with `#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby` (checked by `spec/bin/shebang_spec.rb`; see Audio I/O).  Smoke tests: `spec/bin/script_smoke_spec.rb` (see Testing).

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
- `Numeric#samples` is a `Length::Samples` (it used to return seconds at 48 kHz), and `#delay`/`#multitap` have no `samples:`/`sample_rate:` options: write `delay(96.samples)` or `delay(lfo.samples)`.  A plain node or number is seconds; `smooth(0.1)` and `smooth(4800.samples)` replace `smooth(seconds:/samples:)`.
- Shapes and shapers are antialiased by default; use the `a*` names (`aramp`, `aclip`, ...) or `.lfo` for control signals that must keep exact edges (delay times, gates, phases), and remember that `softclip`/`clip`/`abs`/`quantize` add half a sample of delay (null tests against older renders show it as a -20 to -30 dB residual; align by half a sample to compare).  An edge landing exactly on a sample is a classic rounding trap in these kernels (phases snap within 1e-9 of an edge).
- The container compiles with GCC, which never warns about unused `static inline` functions; the user's Mac uses clang, which does for functions defined in a `.c` file (not in headers), and `-Werror` makes that a build failure.  After C changes, check that every static function in a `.c` file is still called.
- `Numo::Pocketfft.rfft` (and `ifft` of a complex view) read an NArray view like `x[100..]` from its parent's start; `MB::Sound.fft`/`ifft`/`real_fft`/`real_ifft` copy their input, but `.dup` views before calling Pocketfft directly.
- `node.filter(cookbook_filter)` re-applies the filter's original cutoff and quality every buffer, so changing `center_frequency` from outside (e.g. a MIDI callback) does nothing; pass `cutoff:` a node and change the node.
- `multitap` and other multi-output results are `Channels` bundles, which are deliberately not Enumerable (`.to_a` for `shuffle`, `reverse`, etc.).
- C4 = 60 (C3 = 48).  Derive expected values in specs from note constants or a quick script; hand-computed notes and offsets caused several wrong assertions.
- A realtime Session's render thread runs until `close`; close sessions in spec `after` blocks.  `kill -QUIT <pid>` prints every thread's backtrace (`MB::U.sigquit_backtrace`, set up in spec_helper).
- Before adding `bin/sound.rb` commands, check for collisions with `MB::Sound` methods and Pry commands (`Pry::Commands`; e.g. `reset` and `watch` are taken).
- macOS playback goes through ffmpeg's audiotoolbox output with `FFMPEGOutput realtime: true` and `BackgroundOutput` by default (about 0.4s latency) until the audio I/O work makes `OUTPUT_TYPE=device` the default (see Audio I/O).

### Process

- In multi-step shell scripts, use `set -euo pipefail`, don't pipe away exit codes, and put commands on separate lines (a failure inside `a && b` doesn't stop the script).  A batch loop that kept going after a failure once produced broken commits.
- Use the Edit tool for multi-line code changes; ad hoc Python/sed replacements often failed on indentation or escaping.  Never `sed -i` the Rakefile: on the Mac's case-insensitive `/app` mount it once left a stale lowercase `rakefile` entry that rake loads first (`LoadError ... rakefile`; `rake -f Rakefile` works around it).
- Benchmarks are noisy when another session is compiling or running specs: alternate runs of the old and new code (e.g. a temporary master-ai worktree) instead of comparing against remembered numbers.
- Keep command output small (grep/head/tail, Read with offsets); large tool output fills the context quickly.
- Measure before explaining a failure; the first theory for the macOS latency problem was wrong, and a small experiment found the real cause.
- The user often says "note for later": record those in local memory (themed idea files), not GitHub, and implement them only after an explicit go-ahead.
