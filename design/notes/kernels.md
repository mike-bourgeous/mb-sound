# Kernel registry (C kernels and their Ruby mirrors)

<!-- summary -->
`MB::Sound::Kernels` (`lib/mb/sound/kernels.rb`, kernels-1) registers every C kernel beside its Ruby mirror, and one switch picks which runs: `MB::Sound.kernels = :c` (default) `| :ruby | :check`, `Kernels.set(fast_plan: :ruby)` per kernel or group, `Kernels.with(:ruby) { ... }`, `MB_SOUND_KERNELS=ruby` (or `check`, `c,fast_ui=ruby`).  `:check` runs the mirror on deep copies, then C on the originals (so results are `:c`'s), and raises `Kernels::Mismatch` on any difference (exact unless the entry's tolerance).  Call sites dispatch through `Kernels.svf(...)` or the owner's method (`Tone#run_kernel`); lib/ calls C only from `*_c` methods.  Guards: `kernels_guard_spec.rb` (every Fast* function registered or in `UNMIRRORED` with a reason), `kernels_check_spec.rb` (check mode over the graph sweep and extra scenes).
<!-- /summary -->

## Quick reference

- Switch: `MB::Sound.kernels = :c | :ruby | :check`, `Kernels.set(fast_plan: :ruby)`, `Kernels.with(:ruby) { ... }`, `MB_SOUND_KERNELS=check` (or `ruby`, `c,fast_ui=ruby`).
- Register a new kernel with its mirror beside it (`Kernels.register :name, c:, ruby:`); lib/ calls C only from `*_c` methods.
- Guards: `spec/lib/mb/sound/kernels_guard_spec.rb`, `spec/lib/mb/sound/kernels_check_spec.rb`.

## Why (kernels-1, 2026-10-30)

The arch-core review (October, finding 6) counted seven ways mirrors were switched in (`MB_SOUND_PLAN=ruby`, `MB_SOUND_REVERB=ruby`, Reverb::Network's `ruby:` keyword, `Envelope#sample_ruby`, `Generative::Dice.mode`, `Plot.native`, `Notes.fast_paths`), plus more found while migrating (`Tone#sample_ruby`, `BusMeter.native`, `MasterMeter.native`, `Smoother.run(c:)`, `Unison::Detune`'s `kernel:` keyword, the per-object `native:` keywords of plots and UI screens), and no way to run everything in Ruby.  The maintainer: "I'd generally prefer avoiding split realities.  Change something once across the board."  So every kernel moved at once (option C of the review), and the old switches are gone (no compatibility aliases).

## API

```ruby
MB::Sound.kernels               # => :c
MB::Sound.kernels = :ruby       # every kernel's Ruby mirror (a full-Ruby reference mode)
MB::Sound.kernels = :check      # both, compared; Kernels::Mismatch names the kernel and first difference
MB::Sound::Kernels.set(fast_plan: :ruby, svf: :check)   # entry names or groups (the extension's name)
MB::Sound::Kernels.with(:ruby) { node.sample(800) }     # scoped; also with(:c, fast_ui: :ruby)
MB::Sound::Kernels.mode_of(:svf)                        # => :c
MB::Sound::Kernels.listing                              # one line per kernel: kind, group, mirror, exact or tolerance
MB::Sound::Kernels.checked / .declined / .nested        # counts from check mode (reset_checked)
```

`MB_SOUND_KERNELS` is read at load: a bare word sets the default mode, `name=mode` overrides an entry or group (`MB_SOUND_KERNELS=c,fast_plan=ruby`; names not registered yet apply when they register; `Kernels.unknown_overrides` lists leftovers).  Groups are the extension names (`fast_filter`, `fast_plan`, `fast_loop`, `fast_ui`, `fast_generative`, ...), so the old switches map to `fast_plan=ruby` (was `MB_SOUND_PLAN=ruby`), `reverb_network=ruby` (`MB_SOUND_REVERB`), `fast_generative=ruby` (`MB_SOUND_DICE`/`Dice.mode`), `fast_ui=ruby` (`MB_SOUND_PLOT`/`Plot.native`), `notes_fast=ruby` (`MB_SOUND_NOTES_FAST=0`/`Notes.fast_paths`).  `spec_helper` calls `Kernels.reset!` before every example (back to the environment's modes), so `Kernels.set` inside an example lasts until it ends.

## Registering

Each kernel registers once, beside its mirror (so the guard can load everything and see them all):

```ruby
# a module function: Kernels.svf(...) is FastFilter.svf or SVF.process_ruby (same arguments and result)
Kernels.register :svf, c: FastFilter.method(:svf), ruby: SVF.method(:process_ruby)

# methods of a class (or a module's singleton class): the dispatcher is an alias of the C or Ruby method
Kernels.register :tone, on: Tone, as: :run_kernel, c: :kernel_c, ruby: :kernel_ruby,
  state: %i[kernel_state restore_kernel_state], check_if: :kernel_checkable?, tolerance: :kernel_tolerance,
  covers: %w[FastSynth.oscillate_bl ...]

# a class: Kernels.reverb_network is FastReverb::Network or the mirror class (check mode: a class running both)
Kernels.register :reverb_network, c: MB::Sound::FastReverb::Network, ruby: Reverb::Network::RubyKernel

# a Ruby fast path with a reference path (no C): Kernels.notes_fast? is false only in :ruby
Kernels.register :notes_fast, path: true
```

Options: `tolerance:` (0, a Float, or for methods a receiver method name; complex Tone shapes use 1e-15, the old cookbook coefficients 1e-9, its moving-cutoff biquad 1e-6, fast_sound's logarithms 1e-5), `state:` (instance variables, `%i[@x1 @y1]`, or `[save, restore]` method names: the receiver's state check mode saves, restores between the halves, and compares), `check_if:`, `check: 'reason'` (check mode runs C only: grids that blit into grids, FastSound.shape's rounding at edges), `declines: true` (the C function returns nil for arguments it can't take and the caller falls back to its own Numo code: FastArithmetic, the sync pulse kernels; check mode compares only calls C took), `covers:` (C functions a method or class entry stands for), `group:`.

Function dispatchers are generated methods (`def svf__c(...) = ::MB::Sound::FastFilter.svf(...)`) that `Kernels.svf` aliases, so `:c` costs one Ruby frame and no allocation (`(...)` forwarding; a leading receiver argument would allocate two objects per call, measured, which is why method kernels alias on the owner instead); mode changes re-alias only the entries whose mode changed.  Check mode is generic: arguments are deep-copied (NArrays keeping inplace and frozen flags, Arrays, Hashes, Strings; objects with `#kernel_copy`/`#kernel_state`, like DelayLine and Plot::Raster, copy and compare themselves; identity within the arguments is kept), the mirror runs first on the copies, then C on the originals, and results, every array argument, and the state are compared by value (NaN equals NaN; a zero's sign isn't compared, as the feedback loop check accepted on 2026-10-10).  A kernel called inside another kernel's check runs the half in progress (`Kernels.nested` counts these: compared through the outer kernel).

Mirrors match the C kernels' in-place rules (`Kernels.inplace_result`: an inplace contiguous SFloat is written where it is, as `mb_ensure_inplace_sfloat` does), declines (`Kernels::Arithmetic`'s type and shape checks), and return values; check mode found the places that didn't (below).

## What is registered

114 entries (2026-10-30, after merging omnibus18), by extension:

- fast_filter: `svf`, `four_pole`, `diode_ladder`, `formant`, and the curve helpers exposed for specs (`filter_tan`, `filter_tanh`, `filter_secant`, `resonance_curve`, `self_osc_gain`, `tuning_scale`, `diode_*`).
- fast_sound: `osc`, `fast_shape` (C only in check mode), `biquad`, `biquad_complex`, `biquad_process` (Filter::Biquad#process), `cookbook` and `cookbook_dynamic` (Cookbook#set_coefficients, #dynamic_process), `number_to_freq`, `matrix_mix`, `narray_log`/`log2`/`log10`, `smoothstep_buf`, `smootherstep_buf` (mirrors in `Kernels::Buffers`); Tone's `phasor`/`oscillate` through `tone`.
- fast_synth: `tone` (Tone#run_kernel, every shape kernel), `sync_pulse_edges`, `sync_running_phases`, `jump_queue` and `jump_add` (Tone::State#queue_jump, #add_jump: mb_jump_step.h, omnibus18; mirrors #queue_jump_ruby, #add_jump_ruby).
- FastSound::ComplexSynthesis: `csc_int`, `csc_int_int`, `cot_int` (mirrors mb-math's, within 1e-12).
- fast_arithmetic: all 21 functions (mirrors in `Kernels::Arithmetic`, the Numo operations the C was written to match).
- fast_envelope `envelope`; fast_resonator `ping`, `modes`; fast_texture `dust`, `drift`; fast_lofi `decimate`; fast_dynamics `compand`, `limit`, `crossover`; fast_control `smooth`, `smooth_adaptive`, `smooth_curve`, `smooth_reset_run`, `slew`; fast_clip `shape`, `shape_curve`, `curve_lookup`; fast_unison `unison_exact`/`interp`/`scale`; fast_delay `delay_read`, `delay_network`; fast_sampler `sampler_play`, `grains`; fast_wavetable `wavetable_*` (Wavetable#oscillate, #sync, #lookup, #play, #shape_at), `harmonic_spectra`, `half_means`; fast_loudness `true_peak`, `meter_block`, `sum_squares`, `peak_sumsq`; fast_generative `dice_*`; fast_reverb `reverb_network`; fast_plan `plan` (Region#run_program), `plan_lanes` (LaneGroup#run_lanes); fast_loop `loop` (FeedbackLoop#run_program), `loop_pitch`; fast_ui `plot_decimate`, `plot_monotonic`, `plot_polyline`, `plot_area`, `plot_project`, `cell_grid` (NativeCells or MB::Term::Cells, also driving mb-term's `Grid.native`); mb-term's fast_term `term_vt` (MB::Term::NativeVT or RubyVT, driving `MB::Term::VT.native`; registered in `ui.rb`); fast_latency `latency_bucket`, `latency_bucket_floor`, `latency_percentile`; the `notes_fast` path.

Without a mirror (`Kernels::UNMIRRORED`, with reasons): FastAudio (device and JACK I/O; its concealer runs on the device thread, compared with `Concealment::Reference` by its spec), FastMIDI, FastResample (libsamplerate), FastLatency's probe and clocks, FastUI::GVLProbe, FastRecipe.frame_binding (the VM debug inspector; the TracePoint alternative, `Recipe.locals_mode :trace`, is a different behavior, not a mirror), the plan/loop enum tables, and FastSound.fast_math=/? (the last uncalled scalar helper, FastSound.smoothstep, went in cleanup-2, 2026-10-31, after omnibus18 removed the others).

## Guards

- `spec/lib/mb/sound/kernels_guard_spec.rb` (`spec/support/kernels_guard.rb`): loads lib/, lists every C function and class of every Fast* module (MB::FastSound, MB::Sound::Fast*, MB::Term::FastTerm), and fails for one neither covered by an entry nor in UNMIRRORED (and for stale names in either); walks lib/ with Prism and fails for a C call outside a method named `*_c` (the C path of a registered kernel, or a helper it calls: Program#run_c, Wavetable#oscillate_c, ...); requires every kernel the check sweep doesn't reach to name the spec that compares it (`KernelsGuard::COMPARED_ELSEWHERE`).
- `spec/lib/mb/sound/kernels_check_spec.rb`: every graph sweep factory, planned and unplanned, at 128-sample buffers (7 and 800 in the slow tier) under `Kernels.with(:check)`, plus scenes the sweep doesn't build (a session with buses, plots of every mark kind, the UI meters, dice, wavetable sync and sample playback, unison detune modes, biquad steps); then that every checkable kernel was compared (`checked`, `declined`, `nested`) or is listed.  About 25 s on the Mac container (the plain graph sweep: 10 s at its three buffer sizes).
- `spec/valgrind/memcheck_selection.rb` maps `Kernels.<name>` in changed lib/ lines to the extension behind the kernel (`MemcheckSelection.kernel_modules`, read from the registrations without loading lib/), since call sites no longer name the Fast* module.

## What check mode found (kernels-1)

- In-place semantics: the SVF, four-pole, diode, shaper, curve shaper, curve lookup, slew, delay read, and biquad mirrors returned new buffers where the C kernels filter an inplace input where it is (now `Kernels.inplace_result` and the same rule in each mirror).
- `Cookbook#set_parameters_ruby` kept only the first of quality/bandwidth/slope and dropped the others, where the C path keeps all three (the coefficients were the same; the derived `#quality` differed).
- `Tone::State.new` restored a complex tone's jump residual as a DFloat (raised `RangeError`): a real bug in `plan_restore` for complex tones with a pending phase jump (Session::Carry), fixed.
- The tone kernel also consumes a pending clean reset target (`@sync_reset`), now part of its check state.
- Mirrors that returned values the C side doesn't (plot polylines and areas returning the last assignment) now return nil like C.
- A check-mode run of the node, session, UI, and extension specs (2753 examples): `Plot::Scale::Log#forward` wrote NaNs into the caller's data (a real bug, also on master-ai), the wavetable mirrors wrote into non-inplace outputs (`Kernels.inplace_buffer`), the sync mirror skipped the kernel's ring check, `Kernels::Arithmetic.accumulate` compared an NArray with a Symbol, and `harmonic_spectra`'s mirror is within 1e-16, not exact, for most phases.  What else failed there is timing and allocation budgets, which check mode changes by design.

## Costs

Measured 2026-10-30 on the Mac container (i9-9880H, under the heavy-run lock, other agents running):

- `:c` mode is the old code path plus one Ruby frame per function-kernel call: every graph sweep factory, planned and unplanned, at 128- and 37-sample buffers (1020 cases) gives bit-identical samples on the branch and on master-ai 61eb4353; `bin/graph_profile.rb` objects per buffer are identical (fm_bass 88.1 at 128 frames, 394.8 at 800; dnb 84.2 / 365.8) and CPU within run-to-run noise in alternating runs (fm_bass at 128 frames 24.4-28.3% of realtime on master-ai, 21.3-25.1% on the branch; dnb 5.4-7.1% vs 5.6-5.9%).
- Over the graph sweep factories at 128-sample buffers, three buffers, planned and unplanned (CPU seconds): `:c` 1.46, `:ruby` 6.4-7.0 (4.6x), `:check` 10.8-11.1 (7.5x).  Fine for specs, sweeps, and debugging, not for playing.
- The relation fuzz's `:kernel_check` relation over 80 more seeds (1000-1079): no mismatches.

## Found with the full-Ruby mode

`MB_SOUND_KERNELS=ruby` over the graph sweep failed one factory, "drums kit builder" at 1-sample buffers, planned: `Tee::SharedBufferModified` downstream of a Notes trigger, also with `notes_fast` alone.  Fixed in cleanup-2 (2026-10-31): not the Notes reference path itself but `Drums::Voice::Tap`, which handed the voice graph its source's reused buffer.  The Voice samples its inputs (the trigger rewrites its buffer, as the reference path does every block where the fast paths hand out frozen constants) before its graph's Tees reach their next frame, so a Tee over a Tap saw its shared buffer change under it (harmless in lockstep, wrong data for a lagging branch).  The Tap now copies unfrozen buffers into its own when sampled (frozen ones pass as they are; drums.md).  The graph sweep runs every factory with Notes nodes (30 of 255) once more on the Notes reference path at 1-sample buffers (`GraphSweep::NOTES_REFERENCE`), so the case stays covered.  The full-Ruby sweep now passes except its coverage guard, which misses Notes::EnvelopeInputs in that mode (only the fast path builds it; 61 s on the Mac container against 14 s for `:c`).
