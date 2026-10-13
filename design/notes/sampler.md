# Sampler

Sampler and audio capture, stage 1 of "Sampler + second drum machine" (maintainer, 2026-10-13; the persona panel's second request after exact takes: Nev Ashdown (jungle) and Tiko (looper) wanted it most, Kez (DnB) for resampling).  Branch `sampler-1`.  Stage 2 (`drums-2`: kit builder + TR-909) builds on the `Sample` type.

The panel's asks, in their words (`research-persona-panel` 0c08a17d, jungle friction F1-F6): "`rec = bounce(drums, 2.bars, bpm: 138.75)` for the record, `rec.slices(16)` to cut it, slice and pitch kept as separate things, `rec.at(7.n16)` for tracker 9xx offsets, and reverse per hit"; "`node.bounce(1.bar, root: F1)`, then reverse and slices on top"; "build the sampler like a tracker, with slices you can see, offsets you can type, and pitch kept separate from slice, because in jungle the chop is the instrument"; S950-style lofi and a cyclic timestretch as the first effects; `help :sampler` and a chop lesson.

## API sketch

```ruby
# Samples: immutable values (MB::Sound::Sample), mono or multichannel float32 at 48 kHz
kick = Sample['sounds/kick.flac']                     # files (GraphIO FileGuard rules), a root of C4
pno  = Sample['piano_c4.flac', root: C4, loop: 0.5.seconds..1.2.seconds]
s    = Sample[narray]                                 # Numo arrays (one per channel, or 1D)
rec  = bounce(2.bars, bpm: 138.75) { tr808(grid(16, kick: 'X...', ...)) }   # any graph, offline, private tempo
rec  = bounce(drums, 2.bars, bpm: 138.75)             # a graph built elsewhere
bass = reese.bounce(1.bar, root: F1)                  # GraphNode#bounce
cap  = capture_audio(4.bars, on: :bar)                # live: the master bus (or from: mic) from a launch point; cap.sample once done

# Sample edits return Samples
s.reverse (rev)  s.trim(0.1..0.4)  s[1000...9000]  s.fade(in: 1.ms, out: 5.ms)  s.gain(-3.db)  s.normalize
s.bits(12)  s.lofi(:s950)  s.stretch(1.25, cycle: 25.ms)  s.looped(0.5..1.0, mode: :ping_pong)  s.at(7.n16)  s.mono

# Slices: regions of one sample (no copies)
brk = rec.slices(16)                 # equal parts (a Slices: brk[3], brk[4..7] joins, brk.length)
brk = rec.slices(at: [0, 2.n16, 7.n16])  /  rec.slices(:onsets)   # times or detected transients
brk = brk.name(k: 0..1, h: 2..3, s: 4..5, sk: 4..7, g: 7)          # names for ranges of slices; brk[:sk]
brk[:s].rev  brk[3].at(0.25)         # a slice is a Sample too

# Instruments: regions mapped to keys, velocities, round robins
inst = brk.keymap(from: C2)                            # one key per slice, played at its own pitch
inst = Sampler::Instrument.new { |i| i.region pp, keys: C1..B3, vel: 1..63, root: C3; i.region ff, ..., seq: 2 }
inst = sfz('piano/piano.sfz')                          # SFZ import

# Playing: a GraphNode::Sampler voice
synth(midi) { |v| pno.play(v) * v.env(0.002, 0.3, 0.8, 0.4) }
synth(midi, voices: 1) { |v| inst.play(v, transpose: 3) }
clip.sampler(inst, voices: 1) { |v, s| s * v.env(0.0005, 0.01, 1, 0.006) }
amen = brk.chop(:k, T, :h, :g, [:s, 2], brk[:s].rev, R, ...)   # a Clip; slice and pitch separate
bg :breaks, amen.sampler(brk)
```

## Decisions

- **One value type, `Sample`**, separate from `Wavetable` (the persona's workaround was sample-mode Wavetables in a KeyMap).  A Sample holds the sound (one SFloat per channel), `root` (a Note; C4 by default), `loop` (a Range of source samples, a mode), `start`/`stop` (its region of the data: slices and `at` are views on the parent's data and its band-limited levels, so slicing a break costs nothing), `reversed?`, `fade` lengths, and a lineage (parent, method, arguments) for printing.  Playback quality reuses the sample-mode Wavetable levels (half-octave mipmaps, 4x oversampled, `:optimal` interpolation; see oscillators.md): built once per Sample data on first play (`Sample#table(channel)`), shared by every slice and voice.  Measured: a 3 s mono sample builds in 0.28 s into 7.9 MB of levels (13.7x the data); `mips: :octave` halves that for big multisample sets.
- **Kernel `fast_sampler`** (new purpose-specific extension; exact Ruby mirror `Sampler::KernelRuby`, `-ffp-contract=off`) reads those levels through `mb_wavetable.h` (`wt_read_table`, `wt_select`, `wt_value_sel`) without the Wavetable's own loop levels: the sampler does its own position, direction, and loop logic per sample (one-shot, forward, ping-pong, release loop) and jumps at loop points like a hardware sampler.  Positions are doubles in source samples; level selection follows |speed|.
- **Note-ons inside the kernel**: at each nonzero trigger sample it picks a region from the note number and velocity (first match; lokey..hikey, lovel..hivel, round robins), so starts are sample-exact and the output is the same at any buffer size.  One region per note (SFZ layering would multiply the per-note cost; layer by adding a second sampler).  A voice re-struck while sounding keeps the old note as a tail faded out linearly over `declick:` (64 samples, 1.3 ms by default), so truncating mono voices (the jungle chop) don't click.  Worst case per sample per channel: two interpolated reads of two levels each (the tail and the new note); otherwise one.
- **Pitch**: speed = 2^((key - root) * keytrack / 12 + tune / 12) * source rate / output rate * freq / note_hz(key), where `freq` is the voice's frequency node (`v.freq`: bend; or a NotePitch with glide/vibrato) relative to the note's own frequency, so modulation is relative and keytrack 0 (drums, slices) still bends.  `transpose:` adds semitones.
- **Slice and pitch separate (chop hits)**: chop clips encode a hit as a note number above the MIDI range, 128 × (code + 1) + 64 + semitones, code = 2 × slice + reversed (`Sampler.chop_note`), decoded by the kernel.  Note numbers are Floats in Notes, so nothing else needs to know; `clip.transpose(2)` pitches every hit up a tone without changing slices (the persona's `swap :breaks, amen.transpose(2)`), and the keyboard keys 0..127 keep their normal regions (`keymap`).  Notes' frequency nodes compute nonsense pitches for these numbers, which the sampler doesn't read.
- **Round robins** are per voice (lane): sequential counters per key (SFZ seq_length/seq_position) and random draws (lorand/hirand) from a splitmix64 seeded per voice with `MB::Sound.next_seed` (recipes print one seed).  A shared counter across lanes would depend on lane order inside a buffer, so not buffer-size invariant.  For polyphonic round robins prefer random.
- **Velocity**: the trigger's value (Notes#trigger is valued at the velocity), scaled per region by `veltrack` (0 by default for `play`; SFZ's amp_veltrack 100 = (vel/127)²).  Velocity layers pick regions.
- **Envelopes stay in the graph** (`* v.env(...)`), as for every other voice; SFZ ampeg_* becomes the envelope `Instrument#play` multiplies in.  One-shot voices register with the Notes (`Notes#register`) so a Synth doesn't reuse the lane until the sample ends.
- **Bounce** renders offline through `render`'s private Transport and Session (`bounce(graph, 2.bars, bpm:)`, master gain 0 dB, no master chain, exact length from the transport), so the session tempo never changes (F7).  `capture_audio` uses the Session's audio recorder with an in-memory output (master bus from an exact frame) or a silent player tapping a node.
- **Lofi and stretch are offline edits** (`bits`, `lofi(:s950 | :sp1200 | :mpc60)`, `stretch`), baked into a new Sample, so they cost nothing per voice; the voice's `interpolation: :none` / `mips: false` gives the classic aliasing read.
- **SFZ**: `sfz(path)` parses the text format (a load format, not a mini-language) into an `Instrument`: `<global>`/`<group>`/`<region>` inheritance, sample=, lokey/hikey/key, lovel/hivel, pitch_keycenter, pitch_keytrack, tune, transpose, volume, offset, end, loop_mode, loop_start/loop_end, seq_length/seq_position, lorand/hirand, amp_veltrack, ampeg_attack/decay/sustain/release; sample paths go through FileGuard (relative, inside the file's directory) and `Registry::FILE_METHODS`.
- **Graph documents**: samples save as bundle assets (FLAC with their tags: root, loop, slices) with SHA-256; slices and edits print as chains on the asset (`Sample["assets/rec.flac"].slices(16)[4..7].rev`).
- **Plan layer**: the Sampler is a plan boundary for now (`plan_unsupported_reason`).
