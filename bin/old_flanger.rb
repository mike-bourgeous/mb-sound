#!/usr/bin/env ruby
# A simple flanger effect, to demonstrate using a signal node as a delay time.
# (C)2022 Mike Bourgeous
#
# Cool pitch effect: SMOOTHING=0.5 bin/flanger.rb 0.035 0 3 2

require 'bundler/setup'

require 'mb/sound'

if ARGV.include?('--help')
  puts "Usage: [WAVE_TYPE=:ramp] \e[1m#{$0}\e[0m [delay_s [feedback [hz [depth0..1]]]] [filename]"
  puts "   Or: \e[1m#{$0}\e[0m [filename]"
  exit 1
end

numerics, others = ARGV.partition { |arg| arg.strip =~ /\A[+-]?[0-9]+(\.[0-9]+)?\z/ }

delay, feedback, hz, depth = numerics.map(&:to_f)
delay ||= 0.02193
feedback ||= -0.3
hz ||= -0.7
depth ||= 0.35

wave_type = ENV['WAVE_TYPE']&.to_sym || :sine
raise 'Invalid wave type' unless MB::Sound::Oscillator::WAVE_TYPES.include?(wave_type)

filename = others[0]

if filename && File.readable?(filename)
  inputs = MB::Sound.file_input(filename).split.map { |d| d.and_then(0.hz.at(0).for(delay * 4)) }
else
  inputs = MB::Sound.input(channels: ENV['CHANNELS']&.to_i || 2).split
end

output = MB::Sound.output(channels: inputs.length)
bufsize = output.buffer_size

delay_samples = delay * output.sample_rate
delay_samples = 0 if delay_samples < 0
range = depth * delay_samples
min_delay = delay_samples - range * 0.5
max_delay = delay_samples + range * 0.5

# FIXME: This doesn't work with a filter like 1000.hz.lowpass1p; maybe there's overshoot or something?
delay_smoothing = ENV['SMOOTHING']&.to_f
delay_smoothing2 = delay_smoothing

dry_level = ENV['DRY']&.to_f || 1
wet_level = ENV['WET']&.to_f || 1

puts MB::U.highlight({
  wave_type: wave_type,
  delay: delay,
  feedback: feedback,
  lfo_hz: hz,
  depth: depth,
  min_delay: min_delay,
  max_delay: max_delay,
  inputs: inputs.map(&:graph_node_name),
  sample_rate: output.sample_rate,
  buffer: bufsize,
})

begin
  paths = inputs.map.with_index { |inp, idx|
    # Feedback buffers, overwritten by later calls to #spy
    a = Numo::SFloat.zeros(bufsize)

    lfo = hz.hz.with_phase(idx * 2.0 * Math::PI / inputs.length).send(wave_type).forever.at(min_delay..max_delay)

    # Split delay LFO for first-tap and feedback
    d1, d2 = lfo.tee

    # Split input into original and first delay
    s1, s2 = inp.tee(2)
    s1.named('s1')
    s2.named('s2')
    s2 = s2.delay(samples: d1, smoothing: delay_smoothing)

    # Feedback injector and feedback delay (compensating for buffer size)
    d_fb = (d2 - bufsize).proc { |v| v.inplace.clip(0, nil).not_inplace! }
    b = 0.hz.forever.proc { a }.delay(samples: d_fb, smoothing: delay_smoothing2)

    # Final output, with a spy to save feedback buffer
    wet = (feedback * b - s2).softclip(0.85, 0.95).spy { |z| a[] = z if z }

    (s1 * dry_level + wet * wet_level).softclip(0.85, 0.95)
  }

  loop do
    data = paths.map { |p| p.sample(output.buffer_size) }
    break if data.any?(&:nil?)
    output.write(data)
  end

rescue => e
  puts MB::U.highlight(e)
  exit 1
end
