#!/usr/bin/env ruby
# A simple filter pinging synthesizer.

require 'bundler/setup'
require 'mb-sound'

MB::U.sigquit_backtrace

MB::Sound.synth_script { |input|
  MB::Sound.synth(input) { |midi|
    (
      midi.click(range: 5..25).filter(:lowpass, cutoff: midi.frequency, quality: midi.cc(1, range: 50..150)) * midi.number(range: 48..-44).db
    ).softclip
  }.softclip(0.8, 0.95).oversample(3)
}
