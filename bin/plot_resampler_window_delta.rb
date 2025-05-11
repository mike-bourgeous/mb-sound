#!/usr/bin/env ruby
# Plots difference between resampling with a large buffer size and a small
# buffer size.  There shouldn't be a difference, but at time of writing this
# script there is.

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

MULTI_SAMPLES = ENV['MULTI_SAMPLES']&.to_i || 216
MULTI_COUNT = (SAMPLES * 1.1 / MULTI_SAMPLES).ceil

modes = [
  :ruby_zoh,
  :ruby_zoh_dfloat,
  :ruby_zoh_array,
  :ruby_zoh_dfloat_array,
  #:ruby_linear,
  #:libsamplerate_zoh,
  #:libsamplerate_linear,
]
data = modes.flat_map { |m|
  $d1 = d1 = MB::M.select_zero_crossings(
    FREQ.hz.at(1).at_rate(FROM_RATE).forever
      .resample(TO_RATE, mode: m)
      .sample(SAMPLES),
    nil
  )
  $d2 = d2 = MB::M.select_zero_crossings(
    FREQ.hz.at(1).at_rate(FROM_RATE).forever
      .resample(TO_RATE, mode: m)
      .multi_sample(MULTI_SAMPLES, MULTI_COUNT),
    nil
  )

  dlength = [d1.length, d2.length].min
  d1 = d1[0...dlength]
  d2 = d2[0...dlength]

  delta = d2.not_inplace! - d1.not_inplace!
  [
    ["#{m} large", d1],
    ["#{m} small", d2],
    ["#{m} diff", delta],
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
      columns: 4
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
