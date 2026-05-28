#!/usr/bin/env ruby
# A simple filter pinging synthesizer.

require 'bundler/setup'
require 'mb-sound'

MB::U.sigquit_backtrace

# TODO: further simplify/automate argument handling for I/O

output_file = nil
input_file = nil

ARGV.each do |a|
  case a
  when /.(flac|wav|mp3|ogg|mp4|m4a|opus)$/i
    output_file = a

  else
    input_file = a
  end
end

synth = MB::Sound.synth(input_file) { |midi|
  (
    midi.click(range: 5..25).filter(:lowpass, cutoff: midi.frequency, quality: midi.cc(1, range: 50..150)) * midi.number(range: 48..-44).db
  ).softclip
}.softclip(0.8, 0.95).oversample(3)

if output_file
  MB::Sound.write(output_file, synth, overwrite: :prompt)
else
  MB::Sound.play synth
end
