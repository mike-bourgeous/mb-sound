#!/usr/bin/env ruby
# Plots difference between Ruby and libsamplerate implementations of ZOH and
# linear resamplers.  There shouldn't be a difference (other than possible
# lag), but at time of writing, there is.

# TODO: dedupe with other plot_resampler* scripts?

require 'bundler/setup'

require 'pry-byebug'

require 'mb-sound'

GRAPHICAL = ARGV.include?('--graphical')
SPECTRUM = ARGV.include?('--spectrum')

SAMPLES = ENV['SAMPLES']&.to_i || 108000
TIME_SAMPLES = ENV['TIME_SAMPLES']&.to_i || SAMPLES / 10

FROM_RATE = ENV['FROM_RATE']&.to_i || 400
TO_RATE = ENV['TO_RATE']&.to_i || 17000

FREQ = ENV['FREQ']&.to_f || 40

MULTI_SAMPLES = ENV['MULTI_SAMPLES']&.to_i || SAMPLES
MULTI_COUNT = (SAMPLES * 1.1 / MULTI_SAMPLES).ceil

modes = [
  [:ruby_zoh, :libsamplerate_zoh],
  [:ruby_linear, :libsamplerate_linear],
  [:ruby_linear, :libsamplerate_best],
]
data = modes.flat_map { |(a, b)|
  d1 = MB::M.select_zero_crossings(
    FREQ.hz.at(1).at_rate(FROM_RATE).forever
      .resample(TO_RATE, mode: a)
      .multi_sample(MULTI_SAMPLES, MULTI_COUNT),
    nil
  )
  d2 = MB::M.select_zero_crossings(
    FREQ.hz.at(1).at_rate(FROM_RATE).forever
      .resample(TO_RATE, mode: b)
      .multi_sample(MULTI_SAMPLES, MULTI_COUNT),
    nil
  )

  dlength = [d1.length, d2.length].min
  d1 = d1[0...dlength]
  d2 = d2[0...dlength]

  delta = d2.not_inplace! - d1.not_inplace!
  [
    [a, d1],
    [b, d2],
    ["#{a}/#{b} diff", delta],
  ]
}.to_h

pry_next = false
MB::U.sigquit_backtrace {
  pry_next = true
  Thread.new do |t| sleep 0.1 ; Thread.main.wakeup end
}

puts MB::U.highlight({
  GRAPHICAL: GRAPHICAL,
  SPECTRUM: SPECTRUM,
  SAMPLES: SAMPLES,
  FROM_RATE: FROM_RATE,
  TO_RATE: TO_RATE,
  FREQ: FREQ,
  MULTI_SAMPLES: MULTI_SAMPLES,
  MULTI_COUNT: MULTI_COUNT,
})

data.each do |name, data|
  MB::Sound.write("tmp/#{"#{$0}_#{name}".gsub(/[^A-Za-z0-9-]+/, '_')}.flac", data, sample_rate: TO_RATE, overwrite: true)
end

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
