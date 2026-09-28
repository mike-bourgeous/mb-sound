#!/usr/bin/env ruby
# Uses MB::Sound::Filter::FIR to design a filter with a desired response, and
# process a sound file with that filter.  The filter design algorithm is very
# crude, but it works.
#
# Usage: $0 in_file out_file freq1 gain1 freq2 gain2 [freq3 gain3 ...]
#
# At least two frequency/gain pairs must be specified.  Append 'db' to gains
# to use decibels; otherwise they will be treated as complex linear.
#
# Examples:
#     # Cut bass
#     $0 sounds/synth0.flac /tmp/x.flac 20 -60db 200 0db 2000 0db
#
#     # Rotate phase 90 degrees
#     $0 sounds/synth0.flac /tmp/90.flac 20 1i 40 1i

require 'bundler/setup'
require 'pry-byebug'

$LOAD_PATH << File.expand_path('../lib', __dir__)

require 'mb/sound'

MB::Sound.script(args: 6..) { |(in_file, out_file, *pairs)|
  abort "Input file #{in_file} not found or not readable" unless File.readable?(in_file)
  abort "Specify frequency/gain pairs (got an odd number of values: #{pairs.join(' ')})" if pairs.length.odd?

  gains = pairs.each_slice(2).to_h { |freq, gain|
    gain = gain.downcase.end_with?('db') ? gain.to_f.db : gain.to_c
    [Float(freq), gain]
  }

  puts "Filtering \e[1;35m#{in_file}\e[0m to \e[1;36m#{out_file}\e[0m"

  filter = MB::Sound::Filter::FIR.new(gains.sort_by(&:first).to_h, sample_rate: 48000)

  puts "\e[1;33mGains:\e[0m"
  puts MB::U.highlight(filter.gain_map)

  puts "\e[34mFilter length: \e[1m#{filter.filter_length}\e[0m"
  puts "\e[32mFFT length: \e[1m#{filter.window_length}\e[0m"

  pad = Numo::SFloat.zeros(filter.window_length + filter.filter_length)

  p = MB::M::Plot.terminal(height_fraction: 0.4)
  p.logscale
  p.plot({magnitude: filter.filter_fft.abs.map{|v| MB::M.clamp(v.to_db, -80, 80) }, phase: filter.filter_fft.arg}, columns: 2)
  p.logscale(false)
  p.plot({impulse: filter.impulse})
  puts

  sound = MB::Sound.read(in_file)
  processed = sound.map { |c|
    filter.reset(0)
    filter.process(c.concatenate(pad))[(filter.window_length - filter.filter_length)..-1]
  }

  MB::Sound.write(out_file, processed, sample_rate: 48000)

}
