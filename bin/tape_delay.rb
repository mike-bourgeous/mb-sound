#!/usr/bin/env ruby
# A simple echo with feedback, to demonstrate the signal graph DSL.
# (C)2022 Mike Bourgeous

require 'bundler/setup'

require 'mb/sound'

if ARGV.include?('--help')
  puts "Usage: \e[1m#{$0}\e[0m [delay_s [feedback [filename]]]"
  puts "   Or: \e[1m#{$0}\e[0m [filename]"
  exit 1
end

numerics, others = ARGV.partition { |arg| arg.strip =~ /\A\+?[0-9]+(\.[0-9]+)?\z/ }

delay, feedback = numerics.map(&:to_f)
delay ||= 0.1
feedback ||= 0.75 # TODO: Allow controlling first delay amplitude separately

filename = others[0]

if filename && File.readable?(filename)
  # Extend input duration by a suitable delay decay time, e.g. RT60
  # feedback ** N == 0.001
  # N = log(0.001) / log(feedback)
  # padding = N * delay
  if feedback >= 1
    extra = 10
  else
    extra = delay * (Math.log(0.01) / Math.log(feedback))
    extra = 1.0 if extra <= 0
    extra = 10 if extra > 10
  end
  input = MB::Sound.file_input(filename).and_then(0.hz.at(0).for(extra))
else
  input = MB::Sound.input(channels: 1)
end

output = MB::Sound.output
bufsize = output.buffer_size

delay_samples = delay * output.rate - output.buffer_size
delay_samples = 0 if delay_samples < 0

puts MB::U.highlight(
  delay: delay,
  feedback: feedback,
  input: input.graph_node_name,
  rate: output.rate,
  buffer: bufsize,
  extra_time: extra
)

# TODO: Make it easy to replicate a signal graph for each of N channels

begin
  # Feedback buffer, overwritten by a later call to #spy
  a = Numo::SFloat.zeros(bufsize)

  # Feedback injector and delay
  b = 0.hz.forever.proc { a }.delay(samples: delay_samples)

  # Tape saturator
  c = b.filter(200.hz.highpass(quality: 0.5)).filter(3000.hz.lowpass(quality: 0.5))
  d = c.softclip(0, 0.5)

  # Final output, with a spy to save feedback buffer
  f = (input + d * feedback).softclip(0.75, 0.95).spy { |z| a[] = z if z }

  loop do
    data = f.sample(output.buffer_size)
    break if data.nil?
    output.write([data] * output.channels)
  end

rescue => e
  puts MB::U.highlight(e)
  exit 1
end
