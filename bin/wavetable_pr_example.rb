#!/usr/bin/env ruby
# First wavetable example from the wavetable pull request.
# (C)2025 Mike Bourgeous

require 'bundler/setup'
require 'mb-sound'

# Noise LFO
nzlfo = 1.hz.gauss.noise.at(100).filter(:highpass, cutoff: 0.02, quality: 0.5).filter(:lowpass, cutoff: 0.3, quality: 0.5).softclip(0, 1) * 26.0/30 + 0.3333

# Portamento (ratio of 0.1114 scales default 440Hz to 49Hz to match video)
porta = MB::Sound.midi.frequency(0.1114).filter(:lowpass, cutoff: 2, quality: 0.5)

# Synth
graph = (porta.tone.at(1).wavetable(wavetable: {wavetable: 'sounds/drums.flac', slices: 30, ratio: 2}, number: nzlfo).forever * 0.5 + porta.tone.triangle).filter(:lowpass, cutoff: 5000, quality: 0.25).softclip

MB::Sound.play graph
