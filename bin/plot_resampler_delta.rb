#!/usr/bin/env ruby
# Plots difference between Ruby and libsamplerate implementations of ZOH and
# linear resamplers.  There shouldn't be a difference (other than possible
# lag), but at time of writing, there is.

require 'bundler/setup'

require 'pry-byebug'

require 'mb-sound'

GRAPHICAL = ARGV.include?('--graphical')
SPECTRUM = ARGV.include?('--spectrum')

SAMPLES = ENV['SAMPLES']&.to_i || 64000
TIME_SAMPLES = ENV['TIME_SAMPLES']&.to_i || SAMPLES / 10

FROM_RATE = ENV['FROM_RATE']&.to_i || 400
TO_RATE = ENV['TO_RATE']&.to_i || 17000

FREQ = ENV['FREQ']&.to_f || 40

MULTI_SAMPLES = ENV['MULTI_SAMPLES']&.to_i || SAMPLES
MULTI_COUNT = (SAMPLES * 1.1 / MULTI_SAMPLES).ceil

modes = [
  [:ruby_zoh, :libsamplerate_zoh],
  [:ruby_linear, :libsamplerate_linear],
  #[:ruby_linear, :libsamplerate_best],
]
data = modes.flat_map { |(a, b)|
  d1 = MB::M.skip_leading(
    FREQ.hz.triangle.at(1).at_rate(FROM_RATE).forever
      .resample(TO_RATE, mode: a)
      .multi_sample(MULTI_SAMPLES, MULTI_COUNT),
    0
  )[-SAMPLES..]
  d2 = MB::M.skip_leading(
    FREQ.hz.triangle.at(1).at_rate(FROM_RATE).forever
      .resample(TO_RATE, mode: b)
      .multi_sample(MULTI_SAMPLES, MULTI_COUNT),
    0
  )[-SAMPLES..]
  delta = d2.not_inplace! - d1.not_inplace!
  [
    ["#{a}/#{b} diff", delta],
    [a, d1],
    [b, d2],
  ]
}.to_h

pry_next = false
MB::U.sigquit_backtrace {
  pry_next = true
  Thread.new do |t| sleep 0.1 ; Thread.main.wakeup end
}

loop do
  if SPECTRUM
    MB::Sound.mag_phase(
      data,
      graphical: GRAPHICAL,
      freq_samples: SAMPLES
    )
  else
    MB::Sound.time_freq(
      data,
      graphical: GRAPHICAL,
      time_samples: TIME_SAMPLES,
      freq_samples: SAMPLES,
      columns: 2
    )
  end

  sleep 2

  if pry_next
    binding.pry
    pry_next = false
  end

  # Loop in graphical mode to allow window resizing (TODO: figure out why
  # gnuplot doesn't resize plots when the window is resized)
  break unless GRAPHICAL
end
