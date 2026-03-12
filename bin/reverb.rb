#!/usr/bin/env ruby
# Adds reverb to an audio file or real-time input using diffusion stages
# and a feedback delay network (FDN).
# (C)2025 Mike Bourgeous
#
# Usage: $0 [options] [input_file [output_file]]
#
# Examples:
#     # Real-time mic input with default settings
#     $0
#
#     # File input to speaker output
#     $0 sounds/piano0.flac
#
#     # File input to file output
#     $0 sounds/piano0.flac tmp/reverb_out.flac
#
#     # Large room with long decay
#     $0 --room-size 0.8 --decay 4.0 sounds/piano0.flac

require 'bundler/setup'

require 'optparse'

require 'mb/sound'
require 'mb-util'

MB::U.sigquit_backtrace

options = {
  room_size: 0.5,
  decay: 2.0,
  damping: 0.5,
  wet: 0.3,
  dry: 0.7,
  diffusion_steps: 4,
  channels: 8,
  seed: 0,
}
OptionParser.new { |p|
  p.banner = "Usage: \e[1m#{$0}\e[0m [options] [input_file [output_file]]"

  p.on('--room-size SIZE', Float, 'Room size 0.0..1.0 (default 0.5)')
  p.on('--decay SECONDS', Float, 'Decay time in seconds (default 2.0)')
  p.on('--damping AMOUNT', Float, 'HF damping 0.0..1.0 (default 0.5)')
  p.on('--wet GAIN', Float, 'Wet signal gain (default 0.3)')
  p.on('--dry GAIN', Float, 'Dry signal gain (default 0.7)')
  p.on('--diffusion-steps N', Integer, 'Number of diffusion steps (default 4)')
  p.on('--channels N', Integer, 'Parallel delay channels, power of 2 (default 8)')
  p.on('--seed N', Integer, 'Random seed for delay times (default 0)')
  p.on('--overwrite', 'Overwrite output file if it exists')
  p.on('--graphviz', 'Print signal graph in graphviz format')
  p.on('--quiet', 'Suppress progress output')
}.parse!(into: options)

graphviz = options.delete(:graphviz)
overwrite = options.delete(:overwrite)
quiet = options.delete(:quiet)

room_size = options[:'room-size'] || options[:room_size]
decay = options[:decay]
damping = options[:damping]
wet = options[:wet]
dry = options[:dry]
diffusion_steps = options[:'diffusion-steps'] || options[:diffusion_steps]
channels = options[:channels]
seed = options[:seed]

filename = ARGV[0]
outfile = ARGV[1]

if filename && File.readable?(filename)
  # Calculate extra time for reverb tail based on RT60 decay
  extra = [decay * 1.5, 10].min

  input = MB::Sound.file_input(filename)
  input = input.and_then(0.hz.at(0).for(extra)).named(filename)
else
  input = MB::Sound.input(channels: 1).named('audio input')
end

sample_rate = input.sample_rate

if outfile
  output = MB::Sound.file_output(outfile, sample_rate: sample_rate, channels: 1, overwrite: overwrite)
end

puts MB::U.highlight({
  room_size: room_size,
  decay: decay,
  damping: damping,
  wet: wet,
  dry: dry,
  diffusion_steps: diffusion_steps,
  channels: channels,
  seed: seed,
  input: input.graph_node_name,
  output: output,
  sample_rate: sample_rate,
})

begin
  result = input
    .reverb(
      room_size: room_size,
      decay: decay,
      damping: damping,
      diffusion_steps: diffusion_steps,
      channels: channels,
      wet: wet,
      dry: dry,
      seed: seed,
      sample_rate: sample_rate
    )
    .softclip(0.85, 0.95)
    .named('reverb output')
    .with_buffer(800)

  if graphviz
    png = result.open_graphviz
    puts "Wrote GraphViz image to #{png}"
  end

  MB::Sound.play(result, output: output, quiet: quiet)

rescue => e
  puts MB::U.highlight(e)
  exit 1
end
