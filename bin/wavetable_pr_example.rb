#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# First wavetable example from the wavetable pull request.
# (C)2025 Mike Bourgeous
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Plays live MIDI, or a MIDI file (e.g. spec/test_data/c_major.mid).
# Run with --help for all options.

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script { |midi|
  # Noise LFO
  nzlfo = 1.hz.gauss.noise.at(100).filter(:highpass, cutoff: 0.02, quality: 0.5).filter(:lowpass, cutoff: 0.3, quality: 0.5).softclip(0, 1) * 26.0/30 + 0.3333

  table = MB::Sound::Wavetable.from_file('sounds/drums_wavetable.flac', align: false)

  # One voice (mono, with the sustain pedal)
  midi.synth(voices: 1) { |v|
    # Portamento (ratio of 0.1114 scales default 440Hz to 49Hz to match video).
    # The frequency holds 440 Hz until the first note, as the old MIDI DSL's
    # did, so the first note glides down from 49 Hz instead of up from 0.
    porta = (v.hz.glide(0, from: 440.hz).freq * 0.1114).filter(:lowpass, cutoff: 2, quality: 0.5)

    # The old MIDI gate: the note's velocity while held (with short ramps)
    gate = v.env(0.01, 0, 1, 0.01, curve: :linear, sensitivity: 0..1)

    # Synth: a sine waveshaped by the table (the sine sweeps two cycles of
    # the table, centered on its middle; frames not aligned, since this is
    # a shaper)
    shaper = porta.tone.at(-0.5..1.5).table_lookup(table, scan: nzlfo)
    (gate * (shaper * 0.5 + porta.tone.triangle.at(0.1))).filter(:lowpass, cutoff: 5000, quality: 0.25).softclip
  }
}
