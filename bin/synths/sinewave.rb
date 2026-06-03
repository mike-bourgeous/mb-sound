#!/usr/bin/env ruby
# A simple sine wave synthesizer.

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script { |input|
  s = MB::Sound.synth(input) { |midi|
    midi.hz * midi.env
  }

  s.softclip(0.8, 0.95).oversample(2)
}
