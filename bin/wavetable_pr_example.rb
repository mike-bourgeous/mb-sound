#!/usr/bin/env ruby
# First wavetable example from the wavetable pull request.
# (C)2025 Mike Bourgeous
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Plays live MIDI (JACK), or a MIDI file (e.g. spec/test_data/c_major.mid).
# Run with --help for all options.

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script { |input|
  midi = input ? MB::Sound.midi_file(input) : MB::Sound.midi

  # Noise LFO
  nzlfo = 1.hz.gauss.noise.at(100).filter(:highpass, cutoff: 0.02, quality: 0.5).filter(:lowpass, cutoff: 0.3, quality: 0.5).softclip(0, 1) * 26.0/30 + 0.3333

  # Portamento (ratio of 0.1114 scales default 440Hz to 49Hz to match video)
  porta = midi.frequency(0.1114).filter(:lowpass, cutoff: 2, quality: 0.5)

  # Synth
  graph = (midi.gate * (porta.tone.at(2).wavetable(wavetable: 'sounds/drums_wavetable.flac', number: nzlfo) * 0.5 + porta.tone.triangle.at(0.1))).filter(:lowpass, cutoff: 5000, quality: 0.25).softclip

  graph
}
