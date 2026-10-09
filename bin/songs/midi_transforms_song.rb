#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A 16-bar demo of MIDI transforms and generators at 112 BPM: a few notes
# and chords become arpeggios, echoes, strums, and grooves.
#
# 1. "bloom" (bars 1-8): one note per bar through a scale echo, so each
#    note blooms into a three-octave A minor arpeggio:
#    `lead.echo(1.n16, 11, pitch: 2, scale: am, velocity: 0.86, gate: 0.6)`.
# 2. "drums" (bars 3-16): Euclidean rhythms (`euclid(3, 8)` kicks,
#    `euclid(11, 16, Fs2)` hats with `chance(0.85)` and a humanize that
#    varies every loop), a snare with a fill every fourth bar
#    (`D2.every(4, from: 4)`), merged into one stream for the 808 kit.
# 3. "arp" (bars 5-12): held chords through `arp(:updown, 16, octaves: 2,
#    swing: 0.56, velocity: [1, 0.55, 0.8, 0.55])`, locked to the bar grid;
#    at bar 9 the chord clip is swapped and the arp follows on the bar.
# 4. "bass" (bars 5-16): a generated melody on a Euclidean rhythm
#    (`melody(scale(:minor_pentatonic, A1), rhythm: euclid(5, 8, ...),
#    vary: true)`: new notes every loop, the same every run), baked with an
#    octave echo into a visible four-bar clip
#    (`.bake(echo(3.n16, 2, pitch: 12), cycles: 4)`; print it with -s).
# 5. "strum" (bars 13-16): the chords strummed (alternating up and down
#    strokes) on a soft pad.
#
# Usage:
#     bin/songs/midi_transforms_song.rb                    # plays live
#     bin/songs/midi_transforms_song.rb song.flac          # renders (-f to overwrite)
#     bin/songs/midi_transforms_song.rb -p arp arp.flac    # one part alone
#     bin/songs/midi_transforms_song.rb -s song.flac       # also prints the generated and baked clips
#
# Or in bin/sound.rb:
#     load 'bin/songs/midi_transforms_song.rb'
#     midi_transforms_song
#
# Snippets for bin/sound.rb (play a keyboard into the console's MIDI port;
# `pluck` is the voice used here):
#     pluck = ->(v) { MB::Sound.transforms_pluck(v) }
#     am = scale(:minor, :a)
#     # Every key blooms into an A minor arpeggio (degrees of the scale):
#     bg :keys, midi.echo(1.n16, 11, pitch: 2, scale: am, velocity: 0.86, gate: 0.6).synth(voices: 16, &pluck)
#     # Fifths climbing and fading (degrees are semitones without a scale):
#     bg :keys, midi.echo(3.n16, 4, pitch: 7, velocity: 0.7).synth(voices: 16, &pluck)
#     # Overlapping echoes on one key stack instead of retriggering:
#     bg :keys, midi.echo(1.n8, 6, overlap: :stack).synth(voices: 16, &pluck)
#     # A grid-locked arpeggiator (hold a chord), two octaves, swung:
#     bg :keys, midi.arp(:updown, 16, octaves: 2, swing: 0.56).synth(voices: 8, &pluck)
#     # Juno-style: the clock starts with your first key; latch keeps it going:
#     bg :keys, midi.arp(:up, 1.n16.t, start: :key, latch: true).synth(voices: 8, &pluck)
#     # A riff from one key (steps in scale degrees):
#     bg :keys, midi.arp(:up, 16, steps: [0, 2, 4, 7, 4, 2], scale: am).synth(voices: 8, &pluck)
#     # One finger, diatonic triads; or a strummed seventh chord:
#     bg :keys, midi.chord(2, 4, scale: am).synth(voices: 16, &pluck)
#     bg :keys, midi.chord(:min7).strum(40.ms, window: 20.ms).synth(voices: 16, &pluck)
#     # Chains, unattached and reused:
#     bg :keys, midi.arp(:up, 16, start: :hybrid).synth(voices: 8, &pluck)   # first note at once, then the grid
#     fx = arp(:up, 16, octaves: 2).echo(3.n16, 2, velocity: 0.5)
#     bg :keys, midi.through(fx).synth(voices: 16, &pluck)
#     # Clips: feel, chance, conditions, per-loop permute, bake
#     riff = seq(A3, C4, E4, G4).n8
#     bg :riff, riff.loop.permute(vary: true).synth(voices: 4, &pluck)          # new order every loop
#     bg :riff, riff.loop.humanize(velocity: 0.2).synth(voices: 4, &pluck)        # +/-4 ms, new every loop
#     bg :riff, riff.loop.humanize(1.n64, velocity: 0.2).synth(voices: 4, &pluck)  # sloppier
#     bg :riff, seq(A3, C4, E4.every(2), G4.maybe(0.5)).n8.loop.synth(voices: 4, &pluck)
#     baked = riff.loop.bake(echo(3.n16, 3, pitch: 12, velocity: 0.5)); puts baked   # echoes wrapped into the loop
#     bg :riff, baked.swing(0.6).synth(voices: 12, &pluck)
#     bg :drums, tr808(euclid(5, 16).loop.stream.merge(euclid(9, 16, Fs2).loop.chance(0.8)))
#     bg :mel, melody(scale(:dorian, D3), 8, leap: 2, vary: true).loop.synth(voices: 2, &pluck)

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The song's length in bars.
  MIDI_TRANSFORMS_SONG_BARS = 16

  # A short plucked saw (the voice of the echo and arp parts).
  def self.transforms_pluck(v, cutoff: 500, decay: 0.5, level: 0.3)
    v.hz.ramp
      .filter(:lowpass, cutoff: v.cutoff(cutoff, env: v.filt_env(0.001, 0.3, 0, 0.2, depth: 4)), quality: 2) *
      v.amp_env(0.002, decay, 0, 0.3) * level
  end

  # A soft detuned pad for strummed chords.
  def self.transforms_pad(v)
    (v.hz.ramp + v.hz.transpose(0.12).ramp)
      .filter(:lowpass, cutoff: v.cutoff(900, env: v.filt_env(0.01, 0.8, 0.3, 0.6, depth: 2)), quality: 0.8) *
      v.amp_env(0.004, 1.2, 0.4, 0.8) * 0.3
  end

  # The song's clips: { lead:, chords:, chords2:, bass:, drums: }.
  def self.transforms_song_clips
    am = scale(:minor, :a)

    lead = seq(A3, F3, C4, G3).n1.legato(1/8r).loop
    chords = (seq(A3, F3, C4, G3).n1 & seq(C4, A3, E4, B3).n1 & seq(E4, C4, G4, D4).n1).legato(0.95).loop
    chords2 = (seq(D3, A3, F3, E3).n1 & seq(F3, C4, A3, Gs3).n1 & seq(A3, E4, C4, B3).n1).legato(0.95).loop

    # A new bass line every loop, the same every run (seed 7)
    rhythm = euclid(5, 8, A1, velocity: 0.8) | euclid(3, 8, A1, rotate: 1, velocity: 0.7)
    line = melody(scale(:minor_pentatonic, A1), rhythm: rhythm, leap: 2, range: E1..A2, seed: 7, vary: true).loop
    bass = line.bake(echo(3.n16, 2, pitch: 12, velocity: 0.45, gate: 0.4), cycles: 4)

    kick = euclid(3, 8, C2).loop
    hats = euclid(11, 16, Fs2, velocity: 0.6).loop.chance(0.85).humanize(1.n128, velocity: 0.25, vary: true)
    snare = (seq(nil, D2, nil, D2).n4 & seq(*([nil] * 13), D2.every(4, from: 4), D2.every(4, from: 4), D2.every(4, from: 4)).n16.vel(0.45)).loop
    drums = kick.stream.merge(hats, snare)

    { lead: lead, chords: chords, chords2: chords2, bass: bass, line: line, drums: drums, scale: am }
  end

  # Starts the song on the current session (live, or inside a render
  # block).  +part+ is :all or one of :bloom, :drums, :arp, :bass, :strum.
  def self.midi_transforms_song(part: :all)
    bpm 112
    c = transforms_song_clips

    bloom = c[:lead].echo(1.n16, 11, pitch: 2, scale: c[:scale], velocity: 0.86, gate: 0.6)
      .synth(voices: 16) { |v| transforms_pluck(v) } * 3
    drums = tr808(c[:drums], hat: { level: 0.5 }) * 0.3
    arp = c[:chords].arp(:updown, 16, octaves: 2, gate: 0.7, swing: 0.56, velocity: [1, 0.55, 0.8, 0.55])
      .synth(voices: 8) { |v| transforms_pluck(v, cutoff: 900, decay: 0.3, level: 0.9) }
    bass = c[:bass].synth(voices: 6) { |v| transforms_pluck(v, cutoff: 160, decay: 0.35, level: 0.9) }
    strum = c[:chords2].strum(1.n16, :alternate).synth(voices: 12) { |v| transforms_pad(v) }

    master { |mix| mix.reverb(:hall, wet: -10.db).softclip(0.6, 0.98) }

    parts = { bloom: bloom, drums: drums, arp: arp, bass: bass, strum: strum }
    if part != :all
      bg part, parts.fetch(part), fade: 0
      at_bar(9) { swap :arp, c[:chords] => c[:chords2] } if part == :arp
      return
    end

    bg :bloom, bloom, fade: 0
    at_bar(3) { bg :drums, drums, fade: 0 }
    at_bar(5) { bg :arp, arp, fade: 0; bg :bass, bass, fade: 0 }
    at_bar(9) { swap :arp, c[:chords] => c[:chords2]; stop :bloom, fade: 1 }
    at_bar(13) { stop :arp, fade: 1; bg :strum, strum, fade: 0 }
    at_bar(15) { outro fade: 2 }
  end

  if main_script?(__FILE__)
    song_script(
      bars: MIDI_TRANSFORMS_SONG_BARS,
      part: [:all, Symbol, '-p', 'The part to play', [:all, :bloom, :drums, :arp, :bass, :strum]],
      show: [false, '-s', 'Print the generated and baked clips, then play'],
    ) { |p|
      if p.show
        c = transforms_song_clips
        puts "bass line (a melody that varies every loop), cycles 1 and 2:"
        2.times { |i| puts "  #{Sequence::Clip.new(c[:line].events_for(i), length: c[:line].length)}" }
        puts "bass, baked with its echo (four cycles, echoes wrapped):\n  #{c[:bass]}"
      end
      midi_transforms_song(part: p.part)
    }
  end
end
