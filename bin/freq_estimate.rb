#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby
# Prints an estimate of the fundamental frequency of the given sound file.
#
# Usage:
#     $0 [--min HZ] [--max HZ] filename

require 'bundler/setup'

require 'mb-sound'

MB::Sound.script(
  args: 1,
  min: [20.0, 'Lowest frequency to consider in Hz'],
  max: [2000.0, 'Highest frequency to consider in Hz'],
) { |(filename), p|
  range = p.min..p.max

  freq = MB::Sound.freq_estimate(MB::Sound.read(filename).sum, range: range, cepstrum: false)

  case
  when freq.nil?
    puts "No frequency found in range #{range.inspect}"

  when freq < 1
    puts "#{MB::M.sigformat(1.0 / freq, 5)}s (#{MB::M.sigformat(freq, 5)}Hz)"

  else
    puts "#{MB::M.sigformat(freq, 5)}Hz"
  end
}
