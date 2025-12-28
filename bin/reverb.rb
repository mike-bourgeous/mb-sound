#!/usr/bin/env ruby
# A standalone monaural reverb effect.
#
# Input and output file can be specified using flags or positional arguments.
#
# Usage: $0 [options] [input_file [output_file]]

require 'bundler/setup'
require 'optionparser'
require 'mb-sound'

options = {
  channels: 4,
  stages: 4,
  'diffusion-time': 0.01,
  'feedback-time': 0.1,
  'feedback-gain': -6,
  wet: 0,
  dry: 0,
  input: nil,
  output: nil,
  force: false,
  quiet: false
}

optp = OptionParser.new { |p|
  MB::U.opt_header_help(p)

  p.on('-c', '--channels N', Integer, 'The number of parallel diffusion and feedback channels (default 4; powers of two: 1, 2, 4, 8, ...)')
  p.on('-s', '--stages N', Integer, 'The number of diffusion stages (default 4, range 1..N)')
  p.on('-t', '--diffusion-time SECONDS', Float, 'The maximum diffusion delay in seconds; controls smearing (default 0.01, range 0..)')
  p.on('-b', '--feedback-time SECONDS', Float, 'The maximum feedback delay in seconds; controls room size (default 0.1, range 0..)')
  p.on('-g', '--feedback-gain DB', Float, 'The feedback gain in decibels (default -6dB, range -120..0)')
  p.on('-w', '--wet DB', Float, 'The wet gain in decibels (default 0dB, range -120..)')
  p.on('-d', '--dry DB', Float, 'The dry gain in decibels (default 0dB, range -120..)')
  p.on('-i', '--input FILE', String, 'A sound file to process (default is soundcard input)')
  p.on('-o', '--output FILE', String, 'An output sound file (default is soundcard output)')
  p.on('-f', '--force', TrueClass, 'Whether to overwrite the output file if it exists')
  p.on('-q', '--quiet', TrueClass, 'Whether to disable plotting the output')
}.parse!(into: options)

if infile = ARGV.shift
  raise 'Specify input file using -i flag OR positional argument (got both)' if options[:input]
  options[:input] = infile

  if outfile = ARGV.shift
    raise 'Specify output file using -o flag OR positional argument (got both)' if options[:output]
    options[:output] = outfile
  end
end

if options[:input]
  input = MB::Sound.file_input(options[:input]).and_then(0.hz.at(0).for(10))
else
  input = MB::Sound.input
end

if options[:output]
  output = MB::Sound.file_output(options[:output], overwrite: options[:force] || :prompt, channels: 2)
else
  output = MB::Sound.output(plot: !options[:quiet])
end

reverb = input.reverb(
  channels: options[:channels],
  stages: options[:stages],
  diffusion_range: 0.0..options[:'diffusion-time'],
  feedback_range: 0.0..options[:'feedback-time'],
  feedback_gain: options[:'feedback-gain'].db,
  wet: options[:wet].db,
  dry: options[:dry].db
).softclip(0.9)

unless options[:quiet]
  MB::U.headline("Playing #{input} to #{output}")
  MB::U.table(options.to_a)
end

MB::Sound.play(reverb, output: output, clear: false)
