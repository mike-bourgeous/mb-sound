#!/usr/bin/env ruby
# Very simple granular delay repeater.
# (C)2024 Mike Bourgeous
#
# Usage: $0 [--help] [--delay=seconds] [--count=integer] [--channels=integer] [--output=filename] [filename]

require 'bundler/setup'

require 'getoptlong'

require 'mb/sound'

# The idea is to have every other N samples play live, followed by the same N
# samples delayed.
#
# Some possible ways to go about this:
# 1. Use an ordinary delay line and a square wave or stepped oscillator to
#    control the delay time.
# 2. Build a granular-specific delay buffer that can be told to start playing a
#    grain at a specific point in past absolute time, or something like that.
# 3. Use a fixed-time delay and modulate the amplitude of the wet and dry
#    signals using a square wave.

# Parameters:
# - Grain size / delay size
# - Number of repeats
# - Stereo spread?

opts = GetoptLong.new(
  [ '--help', '-h', GetoptLong::NO_ARGUMENT ],
  [ '--delay', '-d', GetoptLong::REQUIRED_ARGUMENT ],
  [ '--count', '-n', GetoptLong::REQUIRED_ARGUMENT ],
  [ '--channels', '-c', GetoptLong::REQUIRED_ARGUMENT ],
  [ '--output', GetoptLong::REQUIRED_ARGUMENT ],
)

delay = 0.125
count = 2
channels = ENV['CHANNELS']&.to_i || 2
output_filename = nil

opts.each do |opt, arg|
  case opt
  when '--help'
    MB::U.print_header_help
    exit 1

  when '--delay'
    delay = arg.to_f
    raise 'Delay time must be positive' unless delay > 0

  when '--count'
    count = arg.to_i
    raise NotImplementedError, 'Only a count of 2 is supported at this time' unless count == 2
    # TODO raise 'Repeat count must be >= 2' unless count >= 2

  when '--channels'
    channels = arg.to_i
    raise 'Channel count must be positive' unless channels > 0

  when '--output'
    output_filename = arg
    MB::U.prevent_overwrite(output_filename, prompt: true)
  end
end

filename = ARGV[0]
if filename
  raise "Cannot read #{filename}" unless File.readable?(filename)
  input = MB::Sound.file_input(filename)
  input_nodes = input.split
else
  input = MB::Sound.input(channels: channels)
  input_nodes = input.split
end

output_channels = input_nodes.length

if output_filename
  # TODO multiplex to file and live output
  output = MB::Sound.file_output(output_filename, overwrite: true, channels: output_channels)
else
  output = MB::Sound.output(channels: output_channels)
end

puts MB::U.highlight(
  count: count,
  delay: delay,
  input: input.graph_node_name,
  output: output,
  input_buffer: input.buffer_size,
  output_buffer: output.buffer_size,
)

# TODO: MIDI control of parameters

# TODO: rate needs to scale based on count
rate = 0.5 / delay

paths = input_nodes.map { |inp|
  # TODO: cross-fade two delays with opposite phase instead of fading out and back in
  fade_osc = (rate * 2).hz.sine.at(0..500).with_phase(-Math::PI / 2).clip(0, 1)

  # TODO: multiple repeats: rate.hz.with_phase(Math::PI).ramp.at(0..1).proc { |v| v.map { |q| (q * (count).floor / (count - 1.0) }
  delay_osc = rate.hz.square.at(0..delay).with_phase(Math::PI)

  inp.delay(seconds: delay_osc, smoothing: false) * fade_osc
}

loop do
  data = paths.map { |p| p.sample(input.buffer_size) }
  break if data.any?(&:nil?)
  output.write(data)
end
