---
name: post-merge
description: Steps to finish after every merge into master-ai, unprompted - post-merge tests, merge report with still-open questions, a two-paragraph "did you know" note on a new topic, and cleanup.
---

# After a merge

A merge isn't finished until these are done, in this order, without being asked (the maintainer asked for the note on 2026-09-28 and had to prompt for it once):

1. **Tests:** run `.claude/skills/post-merge/postmerge_tests.sh` in the background (clean compile, suite, smoke, `memcheck:status`; `FULLMC=1` adds the full memcheck when status says it is due).  A clean compile matters after ext/ merges: a stale `.so` passes while the merged C doesn't build.  Load-sensitive examples listed in CLAUDE.md get one rerun before investigating.  Script-only merges run only that script's specs.
2. **Merge report:** what merged (hash), before/after measurements, test results, anything left for the maintainer (cleanup, branches, decisions), and briefly the questions still open from earlier work (they get lost in scrollback).
3. **"Did you know" note:** two paragraphs on something from audio, Ruby, or a nearby field the project apparently doesn't use yet (grep the codebase first), tangential to the project just merged and ideally useful for the next one; something to play with, not a lecture.  For a batch of merges, one note covers the batch.
4. **Record the topic** in the list below (commit it with the next repo change) and in local notes.
5. Remove the merged worktree (after preserving any research, see CLAUDE.md), and update local status notes.

## Topics already used (don't repeat)

- Open Sound Control (OSC), after script-runner (2026-09-28)
- Null tests (polarity-inverted sum, residual in dB, reference renders to guard refactors), after spec-speed (2026-09-29)
- ruby_memcheck (Valgrind for C extension specs, filters Ruby false positives; for the delay reconcile C work), after ext-gc-fix (2026-09-29)
- PolyBLEP (polynomial band-limited step correction on naive phasor oscillators; for tone phase 2 band-limiting), after tone-phase1 (2026-10-01)
- Thiran allpass fractional delays (causal, flat-magnitude tuning for short delays inside feedback loops, e.g. Karplus-Strong), after delay-reconcile (2026-10-03)
- VBAP (vector base amplitude panning: Pulkki's 2D/3D pair/triplet panning for any speaker layout, as a ChannelMixer subclass), after channel-mixer (2026-10-03)
- Ruby Data.define value objects + case/in pattern matching (deconstruct/deconstruct_keys), after lengths (2026-10-03)
- ADAA (antiderivative antialiasing for waveshapers like softclip; Parker/Zavalishin/Le Bivic 2016), after research-valgrind (2026-10-03)
- Chebyshev polynomial waveshaping (T_n(cos x) = cos nx: exact, alias-free harmonic recipes from a sine), after antialiasing (2026-10-04)
- YJIT (Ruby's JIT, off by default: `ruby --yjit` / RUBY_YJIT_ENABLE=1; fm_bass at 32 samples 298% -> 209% on one run), after optimizer stage 1 (2026-10-04)
- Delay-locked loops for audio clocks (Adriaensen 2005: smooth sound card callback timestamps into a stable sample clock; for vis latency compensation and MIDI timestamps), after audio-io stage 1 (2026-10-04)
- Asynchronous sample-rate conversion (ASRC: libsamplerate src_set_ratio steered by a clock-drift estimate, as zita-ajbridge does; for input and output on different sound cards), after audio-io stage 2 (2026-10-04)
- MPE (MIDI Polyphonic Expression: one MIDI channel per sounding note for per-note bend/pressure/slide; zone config via RPN 6), after audio-io stage 3 (2026-10-04)
- MIDI clock sync (24-ppqn 0xF8 ticks + Start/Stop/Continue/Song Position Pointer; follow a DAW or drum machine tempo with a DLL into the Transport; fast_midi currently ignores timing messages), after audio-io stage 4 (2026-10-04)
- MIDI 2.0 Universal MIDI Packet (32-bit controllers, 16-bit velocity, per-note controllers and pitch, attribute data on note-on; MIDI-CI property exchange), after midi-flow round 1 (2026-10-04)
- Polyphonic voice assignment in classic synths (Prophet-5's Z80 keyboard scanner and assigner, rotate vs reset modes, Oberheim OB-X 'cycle', Juno unison; last-note memory), after midi-flow rounds 2-3 (2026-10-05)
- Elektron parameter locks and conditional trigs (per-step parameter values and probability/fill/every-Nth conditions on a sequencer step; fits the MIDI transforms proposal), after midi-checkpoint2 (2026-10-05)
- Direct digital synthesis (DDS: hardware phase accumulators like the AD9833, tuning words, phase truncation spurs and dithering), after tone-consolidation (2026-10-06)
- Counter-based RNGs (splitmix64 lineage; Philox/Threefry in JAX and GPUs: random = hash(seed, counter), so any stream position is computable and parallel voices never share state), after bug-fixes (2026-10-06)
- E-graphs / equality saturation (egg, Willsey et al. 2021: rewrite rules applied non-destructively, cheapest equivalent graph extracted; for as-if graph optimization), after yjit (2026-10-04)
- JACK transport and timebase (jack_transport_query/jack_set_timebase_callback: follow or lead Ardour/Hydrogen/Carla's play position and bar/beat/tick + tempo from the shared JACK client; for MB::Sound Transport sync), after audio-io stage 5 + single-node JACK (2026-10-04)
- ITU-R BS.1770 loudness (LUFS: K-weighting shelf + highpass, 400 ms blocks, absolute -70 LUFS and relative -10 LU gating; for loudness-matched A/B instead of RMS), after ab-listen (2026-10-05)
- Wavetable history (PPG Wave's 1979-81 64-wave tables scanned by an envelope, Waldorf Microwave, Serum's 2048-sample frames + `clm` WAV chunk, Vital's spectral warps; Ensoniq ESQ-1/SQ-80 transwaves), after the 2026-10-06 merge batch (four-pole, unison, gc-fixes, wavetables)
- MinBLEP and hard sync (Eli Brandt, "Hard Sync Without Aliasing", ICMC 2001: minimum-phase band-limited steps via cepstral folding, causal so they fit realtime oscillators; Välimäki's PolyBLEP 2007 as the cheap polynomial version), after wavetable-fixes (2026-10-06)
- THX Deep Note's construction (James A. Moorer, 1982-83, Lucasfilm ASP: ~30 voices of a cello-like digital waveform, random start pitches 200-400 Hz drifting, then gliding to a D-based chord over ~6 octaves; ~20,000 lines of C generating the score; random seeds made each run differ), after the 2026-10-07 merge batch (small-fixes, four-pole-2, unison-3, velocity-fixes)
- Jaffe & Smith's Karplus-Strong extensions (CMJ 1983: allpass tuning, pick-position comb, dynamic-level lowpass, decay stretching/shortening, dispersion allpass for stiff strings), after the 2026-10-08/09 merge batch (808, smoothing, chorus, plan P1/P2, acid), done late on 2026-10-09 when the user asked (the step had been skipped for those merges)
- Jot's FDN absorption filters (Jot & Chaigne 1991: per-line damping filters sized by each delay's length so every line hits the same frequency-dependent RT60; tone-correction filter on the output), after the 2026-10-10 overnight batch (pluck-fix, midi-transforms, plan-p3a, omnibus2, reverb)
