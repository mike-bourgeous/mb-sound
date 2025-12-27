#!/usr/bin/env ruby
# Chops any sound file into a wavetable.
#
# Works by trying to detect the fundamental frequency of the sound, then
# slicing and blending the sound into loopable chunks of the fundamental
# period.
#
# Usage:
#     $0 [options] in_filename out_filename

require 'bundler/setup'
require 'optparse'
require 'mb-sound'

options = {
  blur: 0,
  quiet: false,
  size: 10,
  ratio: 1.0,
  force: false,
}

optp = OptionParser.new { |p|
  header_lines = MB::U.highlight_header_comment
  p.banner = header_lines[0]
  header_lines[1..].each do |l|
    p.separator(l)
  end

  p.on('-b', '--blur AMOUNT', Float, 'Weighting factor for blurring adjacent waves (default 0, range -1..1)')
  p.on('-q', '--[no-]quiet', TrueClass, 'Disable plotting the wavetable (defaults to enabling plotting)')
  p.on('-s', '--size SIZE', Integer, 'The number of waves to add to the table (default 10, range 1..)')
  p.on('-r', '--ratio RATIO', Float, 'Multiply the detected wave period by this ratio (default 1.0)')
  p.on('-f', '--force', TrueClass, 'Whether to overwrite an existing file (defaults to prompting)')
}

optp.parse!(into: options)

puts MB::U.highlight({ options: options, argv: ARGV }) # XXX

inname = ARGV[0]
raise "No input file given\n#{optp.summarize.join}" unless inname

outname = ARGV[1]
raise "No output file given\n#{optp.summarize.join}" unless outname

table_size = options[:size]
raise 'Table size must be >= 1' unless table_size >= 1

ratio = options[:ratio]

# TODO: Support stereo wavetable generation?
data = MB::Sound.read(ARGV[0])
if data.length == 2
  # Blend channels with some phase rotation so side info isn't completely canceled
  # FIXME: This introduces some very loud high frequency oscillation so just using L for now
  #mid = data.sum
  #side = (MB::Sound.analytic_signal(data[0] - data[1]) * 1i).real
  #data = mid + side
  data = data[0]
else
  data = data.sum / data.length
end
data.not_inplace!

MB::U.headline("Estimating frequency of #{inname}", color: '1;34')

metadata = {}
result = MB::Sound::Wavetable.make_wavetable(data, slices: table_size, ratio: ratio, metadata_out: metadata)

if options[:blur] != 0
  10.times do
    result = MB::Sound::Wavetable.blur(result, options[:blur] / 10.0)
  end
end
result = MB::Sound::Wavetable.normalize(result)

MB::Sound.plot(result) unless options[:quiet]

MB::U.headline("Writing to #{outname}")
MB::U.table(metadata.merge(options).to_a)
MB::Sound::Wavetable.save_wavetable(outname, result, overwrite: options[:force] ? true : :prompt)

MB::U.headline "Code to load this wavetable in bin/sound.rb:", color: 36
puts "\n#{MB::U.syntax("data = MB::Sound::Wavetable.load_wavetable(#{outname.inspect})")}"
puts "#{MB::U.syntax("plot data, graphical: true")}"
puts "or\n#{MB::U.syntax("play midi.env * midi.hz.ramp.wavetable(#{outname.inspect})")}\n\n"
