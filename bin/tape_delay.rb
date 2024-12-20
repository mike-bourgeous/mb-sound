#!/usr/bin/env ruby
# A simple, mono, tape-simulator echo with feedback.
# (C)2022-2024 Mike Bourgeous
#
# Usage: [DRY=1.0] [WET=1.0] [PITCH=1] $0 [delay_s [feedback [extra_time]]] [filename]
#
# Examples:
#     $0

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

  input = input.and_then(0.hz.at(0).for(extra))
else
  input = MB::Sound.input(channels: 1)
  input_buffer_size = input.buffer_size
end

output = MB::Sound.output
bufsize = output.buffer_size

delay_samples = delay * output.rate
delay_samples = 0 if delay_samples < 0

if ENV['PITCH'] == '1'
  delay_samples = delay_samples + -0.4.hz.ramp.forever.at(0..3250)
end

puts MB::U.highlight(
  delay: delay,
  feedback: feedback,
  input: input.graph_node_name,
  rate: output.rate,
  buffer: bufsize,
  extra_time: extra
)

# TODO: Make it easy to replicate a signal graph for each of N channels

internal_bufsize = 16

dry = ENV['DRY']&.to_f || 1
wet = ENV['WET']&.to_f || 1
smoothing = ENV['SMOOTHING']&.to_f || 2

begin
  # Use the input buffer size when reading from the input, so our feedback loop
  # can run with a different buffer size.
  # TODO: maybe this should be automatic
  inp, inp_dry = input.with_buffer(input_buffer_size).named('Input').tee

  # Feedback buffer, overwritten by a later call to #spy
  a = Numo::SFloat.zeros(internal_bufsize)

  # Feedback injector and delay
  adjusted_delay = (delay_samples - internal_bufsize.constant).clip(0, nil)
  b = (inp + 0.constant.proc { a }).delay(samples: adjusted_delay, smoothing: smoothing)

  # Tape saturator
  c = b.filter(200.hz.highpass(quality: 0.5)).filter(3000.hz.lowpass(quality: 0.5))
  d = c.softclip(0, 0.5)

  # Final output, with a spy to save feedback buffer, using a shorter buffer
  # size for the feedback loop, allowing shorter delays
  feedback_loop = (dry * inp_dry + wet * d * feedback)
    .softclip(0.75, 0.95)
    .spy { |z| a[] = z if z }
    .with_buffer(internal_bufsize)

  loop do
    data = feedback_loop.sample(output.buffer_size)
    break if data.nil?
    output.write([data] * output.channels)
  end

rescue => e
  puts MB::U.highlight(e)
  exit 1
end
