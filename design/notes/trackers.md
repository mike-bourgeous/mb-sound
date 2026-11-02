# Tracker modules

<!-- summary -->
`mod_import(path)` (`TrackerMethods`, `lib/mb/sound/tracker/`) turns MOD, 669, S3M, XM, and IT modules into a `Tracker::Set`: pure-Ruby readers make a format-neutral `Tracker::Song`, `Tracker::Player` steps it tick by tick like the format's replay routine (effects, envelopes, IT background voices), and `Tracker::Import` maps the recording onto a track per channel (one `Sampler::Instrument` whose keys pick samples, played with `clip.sampler(inst, lanes: ...)`), a looping clip per pattern visit per channel (notes with pitch marks plus bend, CC 7 volume, CC 10 pan, CC 20 start lanes at tick resolution), a scene per visit, and a flow.  A tick is 1/96 of a whole note, so BPM is the module's tempo.  `play`, `render`, and `save` take the set; `:musical` and `:hardware` modes.  Help `help :trackers`.
<!-- /summary -->

## Quick reference

- `song = mod_import('tune.mod', mode: :musical | :hardware, separation:)`; `play song` (or `play 'tune.mod'`, `bin/play.rb tune.mod`), `render 'x.flac', song` (or the path), `save :tune, song` (a set bundle, samples as assets); `song.setup` then `go :p03`, `fx :ch2, ...`, `swap :ch1, song[:p03][:ch1].transpose(12)`, `tempo 150`; `song.play(loop: true)`; `mod_samples(path)`.
- Code `lib/mb/sound/tracker.rb` + `tracker/` (readers `*_reader.rb`, `player.rb` + `player/`, `import.rb`, `set.rb`), `lib/mb/sound/tracker_methods.rb`; the sampler-voice lanes in `lib/mb/sound/sampler/instrument.rb` (`Instrument#play` `lanes:`).
- Specs `spec/lib/mb/sound/tracker/*_spec.rb` (one per format, plus `set_spec.rb`), `spec/lib/mb/sound/sampler_lanes_spec.rb`; synthetic modules from `spec/support/module_writer.rb` (MOD, 669, S3M, XM, IT with an IT 2.14/2.15 compressor).

The maintainer (2026-11-02): "If I gave you a .669 file could you build a parser/player that would load it into the flow/track/clip/sampler structure?", then the framing: "The module support is because the mechanics are already there and for nostalgia's sake rather than being actually practical, so imperfection is OK, but fun is mandatory."  Branch `tracker-1`.  His modules (a MOD, a 669, an S3M, two XMs, an IT, and a reference mp3 of one XM) are private: never committed, quoted, or published; specs build their own with `ModuleWriter`.

## How it works

- **Readers** (`ModReader`, `SixSixNineReader`, `S3MReader`, `XMReader`, `ITReader`; `Tracker.read` picks one by signature) read through `Tracker::Binary` (every read bounds-checked, raising `FormatError` with what was read; truncated samples and patterns become `Song#problems`, warned by `mod_import`).  Paths go through `GraphIO::FileGuard`.  The format-neutral `Song` holds `SampleData` (rate at note 60, loops, sustain loops, volumes, finetune, relative note, pan), XM/IT `Instrument`s (keymap, `Envelope`s, fadeout, NNA/DCT/DCA), `Pattern`s of `Cell`s (neutral note numbers: 60 plays a sample at its base rate; MOD period 428, S3M C-4, XM C-4, IT C-5), orders (S3M/IT 254 markers kept and skipped), speed, tempo, flags.
- **Player** steps rows and ticks (row effects on tick 0, the rest on later ticks), follows breaks, jumps, pattern loops and delays, and stops where the song returns to a row it played (`Result#restart`; a restart mid-pattern splits that visit so the loop target starts a section).  Per channel it records the samples started (with offsets) and every tick's playback rate in Hz, volume (0..1, all volume levels and envelopes included), and pan.  Format subclasses: `MOD` (ProTracker), `SixSixNine`, `S3M`, `XM` (with `Envelopes`), `IT` (on S3M).  Effects a player skips are counted (`Result#unsupported`) and warned once by `mod_import`.
- **Import**: every sample becomes a `Sample` at its own rate (loops `:forward`/`:ping_pong`), all in one `Sampler::Instrument` whose keys pick samples (key = sample number, keytrack 0, like a slice keymap), so one track plays any sample as a tracker channel does; the note rides on each note event as a pitch mark (semitones from note 60), so `clip.transpose(12)` moves a channel's notes.  The tick-by-tick playback rate becomes a bend lane (range 96 semitones, relative to the note's mark), volume a CC 7 lane (linear, absolute), pan CC 10, sample offsets CC 20 (song-wide when any note uses one).  A lane point only where the value changes.  Channels that never play get no track; IT background voices get tracks `:bg1`, `:bg2`, ....
- **Sampler-voice lanes** (the one new engine piece, general): `Instrument#play(v, lanes: true | length | { bend:, volume:, pan:, start:, smooth:, law: })` makes the voice follow its channel's bend (semitones at the stream's bend range), CC 7, CC 10, and CC 20 (read at each note-on as the start fraction), stepping on the exact event samples or smoothed over a length; `law:` is the pan law.
- **Time**: a tick is 1/96 whole note (`Tracker::TICKS_PER_WHOLE`): a tick lasts 2.5 / tempo seconds and a whole note 240 / BPM, so the session BPM equals the module's tempo, rows at speed 6 are sixteenths, and speed changes only change row lengths (exact Rationals throughout).  Tempo changes are scene `tempo:` values (and, inside a pattern, `tempo` calls in the scene's block).
- **Set**: clips loop from their launch (`align: :launch`), a scene per distinct visit (`:p05`, then `:p05_b`, `:p05_c` for visits that play the pattern differently because of carried state), the flow a section per visit with the visit's length, then a one-tick `:fin` scene that cuts every track (looping samples would ring out forever); `loop: true` adds `label :loop` where the song loops back and a `goto :loop` before the end.  `Set#to_arrangement` sets it up on a private Session for saving (`GraphIO.dump` takes anything with `#to_arrangement`).

## Modes (musical vs hardware, the maintainer's convention)

| | `:musical` (default) | `:hardware` |
|---|---|---|
| sample reads | band-limited levels, `:optimal` interpolation | drop-sample, no levels |
| note pitches | the format's tables (what the composer heard) with unrounded slides and exact arpeggio ratios | integer periods and the replay's rounding |
| lanes | stepped over 1.5 ms (a declick) | steps on the tick |
| pans | Amiga hard pans (MOD, 669) narrowed to 0.6 | as written |

Pan laws follow the formats (linear, FastTracker 2's equal power for XM), since a module's balance between hard-panned and centered channels was set under its tracker's law.  `Import::GAINS` matches openmpt123's loudness per format.

## Formats and effects

- **MOD** (31 samples; M.K. and multichannel signatures): ProTracker's set; 4-channel songs clamp periods to 113..856.  Skipped: E0x filter, E3x glissando, EFx invert loop.  15-sample SoundTracker files aren't read.
- **669** (Composer and UNIS): per-order speeds and break rows, 78 BPM; Hz-based effects carried from row to row, constants measured from openmpt123 on synthetic one-note files (a/b slides 80 Hz a tick per unit, c tone portamento 40, d detune 80, e a square vibrato alternating +668 per unit on odd ticks).  Skipped: UNIS g (balance), h (retrigger).
- **S3M**: ST3 periods by C2Spd (14317056 Hz / period), shared effect memory, fast slides by flag or ST3.00.  Skipped: S1x, S2x, SAx, SFx, Y, Z; AdLib channels.
- **XM**: linear or Amiga periods, FT2 memories, the volume column, instruments with keymaps, volume/pan envelopes, fadeout, auto-vibrato.  Skipped: E0x, E3x, EFx.
- **IT**: S3M's letters with IT's memories and extras (M/N, P, T slides, V/W, X, SAx, S7x), the volume column, instruments with note remapping, volume/pan/pitch envelopes, fadeout, NNA background voices with duplicate checks, IT 2.14/2.15 compressed samples (pure Ruby; checked against openmpt123 renders of files made by the spec writer's compressor).  Skipped: filter envelopes, S6x, S9x, S77-S7C, Y, Z.  Approximations: a Sample has one loop, so an IT sample's regular loop wins and a sustain loop alone plays as a plain loop (its release is the volume envelope's); a background voice restarts its sample at its current position on its own track.

## Comparison (tracker-1, 2026-11-02)

Reference: openmpt123 0.7.13 (libopenmpt), apt package, run only as an outside program (`--batch --samplerate 48000`); xmp 4.2.0 for per-channel solos (`-S`).  No reference source was read.  Metrics on the first 45 s, `:musical`, per stereo side: correlation of 100 ms loudness curves in dB, loudness difference after `Import::GAINS`, onsets (band-energy flux) matched within 25 ms.

| maintainer's module | length vs openmpt | curve correlation | loudness | onsets recall / precision |
|---|---|---|---|---|
| MOD, 4 ch | 182.400 s = 3:02.400 | 0.989 (hardware 0.776: hard pans vs openmpt's) | -0.2 LU | 74% / 66% |
| 669, 8 ch | 221.538 vs 221.471 s | 0.993 | -0.1 | 80% / 87% |
| S3M, 8 ch | 371.308 vs 371.276 s | 0.998 | +0.2 | 98% / 87% |
| XM, 32 ch | 274.286 vs 274.176 s | 0.969 (0.962 against his mp3, where openmpt itself gets 0.969) | 0.0 | 88% / 90% |
| XM, 22 ch | 166.667 vs 166.599 s | 0.992 | -0.4 | 91% / 79% |
| IT, 24 ch (20 used + 6 background) | 360.750 vs 360.689 s | 0.997 | +0.1 | 64% / 52% |

Lengths differ only because openmpt rounds each tick to whole frames.  Per-channel levels against xmp solos agreed within ~0.7 dB once the pan laws matched.  Renders: 45 s of the 32-channel XM in 19 s, the IT in 17 s, the MOD in 4 s (i9-9880H container, 800-frame buffers).  Bench set (private): `/app/tmp/listening/tracker-1/` (`render.rb` regenerates it).

## Found on the way

- Synth idle skipping: a lane's sole channel-wide Notes node (`v.cc(7)` read by one lane, no Tee) wasn't advanced while the lane slept, so its stream reader fell behind the timeline and a CC step arriving with the next note never landed (a one-voice sampler went silent for good).  Now such nodes are the lane's own boundary nodes (`Synth#setup_idle_skipping`).
- Numo's `%` keeps the dividend's sign (C-style); XM's delta decoding wraps with a bit mask instead.

## Not yet

- Mid-pattern tempo changes save as scene blocks reading locals, which set documents refuse (none of the maintainer's modules has one).
- A shared instrument variable in saved sets (each track's patch prints the instrument again).
- XM/IT "carry" envelopes, IT filters, DCT note checks against remapped notes, MOD sample swaps on loop ends, 15-sample MODs, MED/OKT/other formats.
