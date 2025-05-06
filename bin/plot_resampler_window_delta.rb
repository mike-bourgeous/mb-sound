#!/usr/bin/env ruby
# Plots difference between resampling with a large buffer size and a small
# buffer size.  There shouldn't be a difference, but at time of writing this
# script there is.

require 'bundler/setup'

require 'pry-byebug'

require 'mb-sound'

GRAPHICAL = ARGV.include?('--graphical')
SPECTRUM = ARGV.include?('--spectrum')

modes = [
  :ruby_zoh,
  :ruby_linear,
  #:libsamplerate_zoh,
  #:libsamplerate_linear,
]
data = modes.flat_map { |m|
  d1 = MB::M.skip_leading(44.hz.at(1).at_rate(400).resample(17000, mode: m).sample(27000), 0)[0...16000]
  d2 = MB::M.skip_leading(44.hz.at(1).at_rate(400).resample(17000, mode: m).multi_sample(216, 125), 0)[0...16000]
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

loop do
  if SPECTRUM
    MB::Sound.mag_phase(
      data,
      graphical: GRAPHICAL,
      freq_samples: 16000
    )
  else
    MB::Sound.time_freq(
      data,
      graphical: GRAPHICAL,
      time_samples: 1600,
      freq_samples: 16000
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
