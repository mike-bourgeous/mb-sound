#!/usr/bin/env ruby
# Very simple granular delay repeater.
# (C)2024 Mike Bourgeous
#
# Usage: $0 [--help] [--delay=seconds] [--count=integer] [--channels=integer] [--output=filename] [filename]
#
# Examples:
#     $0 --delay=0.02083333 --count=8 sounds/drums.flac
#     $0 --delay=0.05 --count=8 sounds/synth0.flac
#     $0 --delay=0.5 --count=2 sounds/sine/log_sweep_20_20k.flac

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
#
# Ideas for improvement:
# - MIDI CC control (of course)
# - Trigger on MIDI CC (possibly with a "forever" mode; this would require
#   using something other than a classical delay line)
# - Retrigger based on MIDI note (just reset the phase of the delay time oscillator)
# - Retrigger based on audio envelope
# - Delay time based pitch on MIDI note
# - Repeat while MIDI note is held
# - Normalize/semi-normalize/compress volume of each grain, maybe with noise
#   gate or expander
# - Multiple different delays and repeats in parallel or series

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
channels = ENV['CHANNELS']&.to_i
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
    raise 'Repeat count must be >= 2' unless count >= 2

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
  input = MB::Sound.file_input(filename, channels: channels, buffer_size: 4000)
  channels = input.channels
  input_nodes = input.split
else
  channels ||= 2
  input = MB::Sound.input(channels: channels)
  input_nodes = input.split
end

output_channels = input_nodes.length

if output_filename
  # TODO multiplex to file and live output
  output = MB::Sound.file_output(output_filename, overwrite: true, channels: output_channels, buffer_size: input.buffer_size)
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

period = count * delay
rate = 1.0 / period

paths = input_nodes.map.with_index { |inp, idx|
  # TODO: cross-fade two delays with opposite phase instead of fading out and back in?
  # TODO: use a constant number of samples with smoothstep for the fade instead of scaling a sine wave
  fade_osc = (1.0 / delay).hz.sine.forever.at(0..500).with_phase(-Math::PI / 2).clip(0, 1)

  delay_osc = rate.hz.with_phase(Math::PI).ramp.forever.at(0..1.0).proc { |v| (v * count).floor / (count - 1.0) } * (period - delay)

  # FIXME: if max_delay isn't set, then the first time the delay equals one second the buffer is lost
  # e.g. bin/grain_repeater.rb --delay=0.5 --channels=3 --count=3 --output=result.flac sounds/drums.flac
  inp.delay(seconds: delay_osc, smoothing: false, max_delay: period) * fade_osc
}

loop do
  data = paths.map { |p| p.sample(output.buffer_size) }
  break if data.any?(&:nil?)
  output.write(data)
end
