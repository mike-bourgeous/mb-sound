#!/usr/bin/env ruby
# A simple, mono, tape-simulator echo with feedback.
# (C)2022-2024 Mike Bourgeous
#
# Usage: [DRY=1.0] [WET=1.0] [DRIVE=1.0] [PITCH=1 [SMOOTHING=2]] $0 [delay_s [feedback [extra_time]]] [filename]
#
# Examples:
#     # synth groove
#     DRY=1.75 DRIVE=2 WET=1.5 $0 0.25 1 sounds/transient_synth.flac
#
#     # space ship
#     DRY=0.4 WET=1.2 $0 0.25 1.06 sounds/sine/log_sweep_20_20k.flac
#
#     # lo-fi crunch
#     DRY=0 DRIVE=100 $0 0 0 sounds/drums.flac
#
#     # broken time machine
#     DRY=0 SMOOTHING=0.1 PITCH=1 $0 0.3333333 1.15 sounds/drums.flac
#
#     # dub drums
#     DRIVE=10 $0 0.166667 1.14 sounds/drums.flac

require 'bundler/setup'

require 'mb/sound'

if ARGV.include?('--help')
  MB::U.print_header_help
  exit 1
end

numerics, others = ARGV.partition { |arg| arg.strip =~ /\A\+?[0-9]+(\.[0-9]+)?\z/ }

delay, feedback, extra = numerics.map(&:to_f)
delay ||= 0.1
feedback ||= 0.75 # TODO: Allow controlling first delay amplitude separately

filename = others[0]

if filename && File.readable?(filename)
  # Extend input duration by a suitable delay decay time, e.g. RT60
  # feedback ** N == 0.001
  # N = log(0.001) / log(feedback)
  # padding = N * delay
  if feedback >= 1
    extra ||= 10
  else
    extra ||= delay * (Math.log(0.01) / Math.log(feedback))
    extra = 1.0 if extra <= 0
    extra = 10 if extra > 10
  end

  input = MB::Sound.file_input(filename)
  input_buffer_size = input.buffer_size

  input = input.and_then(0.hz.at(0).for(extra)).named(filename)
else
  input = MB::Sound.input(channels: 1).named('audio input')
  input_buffer_size = input.buffer_size
end

output = MB::Sound.output
bufsize = output.buffer_size

oversample = ENV['OVERSAMPLE']&.to_f || 2

delay_samples = (delay * output.sample_rate * oversample).round
delay_samples = 0 if delay_samples < 0

internal_bufsize = 32

dry = ENV['DRY']&.to_f || 1
wet = ENV['WET']&.to_f || 1
drive = ENV['DRIVE']&.to_f || 1
smoothing = ENV['SMOOTHING']&.to_f || 2

puts MB::U.highlight({
  dry: dry,
  wet: wet,
  drive: drive,
  smoothing: smoothing,
  delay: delay,
  delay_samples: delay_samples,
  feedback: feedback,
  extra_time: extra,
  input: input.graph_node_name,
  sample_rate: output.sample_rate,
  oversample: oversample,
  buffer: bufsize,
  internal_buffer: internal_bufsize,
})

if ENV['PITCH'] == '1'
  delay_samples = delay_samples + -0.4.hz.ramp.forever.at(0..(3250 * oversample))
end

# TODO: Make it easy to replicate a signal graph for each of N channels
# TODO: stereo+, ping-pong
# TODO: MIDI control

begin
  # Use the input buffer size when reading from the input, so our feedback loop
  # can run with a different buffer size.
  # TODO: maybe this should be automatic
  inp = input.with_buffer(input_buffer_size).resample(mode: :libsamplerate_fastest).named(filename || 'audio in')

  # Feedback buffer, overwritten by a later call to #spy
  a = Numo::SFloat.zeros(internal_bufsize)

  # Feedback injector and delay
  adjusted_delay = (delay_samples - internal_bufsize.constant).clip(0, nil)
  b = (inp * drive + 0.constant.proc { a } * feedback).delay(samples: adjusted_delay, smoothing: smoothing, sample_rate: input.sample_rate * oversample)

  # Tape saturator
  c = b
    .filter(200.hz.highpass(quality: 0.5))
    .filter(3000.hz.lowpass(quality: 0.5))
    .softclip(0, 0.5)
    .named('tape sim')

  # Feedback, with a spy to save feedback buffer, using a shorter buffer size
  # for the feedback loop, allowing shorter delays
  feedback_loop = c
    .spy { |z| a[] = z if z }
    .named('feedback')

  # Final output
  result = (dry * inp + wet * feedback_loop)
    .softclip(0.75, 0.95)
    .with_buffer(internal_bufsize)
    .oversample(oversample, mode: :libsamplerate_fastest)
    .named('mixed output')


  result.open_graphviz

  loop do
    data = result.sample(output.buffer_size)
    break if data.nil?
    data = MB::M.zpad(data, output.buffer_size) if data.length < output.buffer_size
    output.write([data] * output.channels)
  end

rescue => e
  puts MB::U.highlight(e)
  exit 1
end
