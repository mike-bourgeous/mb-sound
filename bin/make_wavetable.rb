#!/usr/bin/env ruby
# Experiment to chop a sound into a wavetable.
#
# Usage:
#     $0 in_filename out_filename [[table_size] ratio] [--quiet]
#
#     table_size defaults to 100
#     ratio is a multiple of the fundamental period for each wave; defaults to 1
#       ideally should be integer multiples

require 'bundler/setup'

require 'mb-sound'

if ARGV.include?('--help') || ARGV.empty?
  MB::U.print_header_help
  exit 1
end

quiet = !!ARGV.delete('--quiet')

inname = ARGV[0]
raise 'No input file given' unless inname

outname = ARGV[1]
raise 'No output file given' unless outname

table_size = Integer(ARGV[2] || 100)
ratio = Float(ARGV[3] || 1)

# TODO: Support stereo wavetable generation?
data = MB::Sound.read(ARGV[0])
if data.length == 2
  # Blend channels with some phase rotation so side info isn't completely canceled
  # FIXME: This introduces some stupidly high frequency oscillation
  #mid = data.sum
  #side = (MB::Sound.analytic_signal(data[0] - data[1]) * 1i).real
  #data = mid + side
  data = data[0]
else
  data = data.sum / data.length
end
data.not_inplace!

MB::U.headline("Estimating frequency of #{inname}", color: '1;34')

result = MB::Sound::Wavetable.make_wavetable(data, slices: table_size, ratio: ratio)
MB::Sound.plot(result) unless quiet

MB::U.headline("Writing to #{outname}")
MB::Sound::Wavetable.save_wavetable(outname, result, overwrite: :prompt)

MB::U.headline "Code to load this wavetable in bin/sound.rb:", color: 36
puts "\n#{MB::U.syntax("data = MB::Sound::Wavetable.load_wavetable(#{outname.inspect})")}"
puts "#{MB::U.syntax("plot data, graphical: true")}"
puts "or\n#{MB::U.syntax("play midi.env * midi.hz.ramp.wavetable(#{outname.inspect})")}\n\n"
