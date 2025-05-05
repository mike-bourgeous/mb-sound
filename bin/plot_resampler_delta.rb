#!/usr/bin/env ruby
# Plots difference between Ruby and libsamplerate implementations of ZOH and
# linear resamplers.  There shouldn't be a difference (other than possible
# lag), but at time of writing, there is.

require 'bundler/setup'

require 'pry-byebug'

require 'mb-sound'

GRAPHICAL = ARGV.include?('--graphical')
SPECTRUM = ARGV.include?('--spectrum')

modes = [
  [:ruby_zoh, :libsamplerate_zoh],
  [:ruby_linear, :libsamplerate_linear],
  [:ruby_linear, :libsamplerate_best],
]
data = modes.flat_map { |(a, b)|
  d1 = MB::M.skip_leading(40.hz.at(1).at_rate(400).resample(16000, mode: a).sample(27000), 0)[0...16000]
  d2 = MB::M.skip_leading(40.hz.at(1).at_rate(400).resample(16000, mode: b).sample(27000), 0)[0...16000]
  delta = d2.not_inplace! - d1.not_inplace!
  [
    ["#{a}/#{b} diff", delta],
#    [a, d1],
#    [b, d2],
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
      time_samples: 3200,
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
