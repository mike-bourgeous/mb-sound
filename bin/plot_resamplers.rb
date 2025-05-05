#!/usr/bin/env ruby

require 'bundler/setup'

require 'mb-sound'

GRAPHICAL = ARGV.include?('--graphical')
SPECTRUM = ARGV.include?('--spectrum')

loop do
  if SPECTRUM
    MB::Sound.mag_phase(
      MB::Sound::GraphNode::Resample::MODES.map { |m|
        [m, MB::M.skip_leading(40.hz.at(1).at_rate(400).resample(16000, mode: m).sample(17000), 0)[0...16000]]
      }.to_h,
      graphical: GRAPHICAL,
      freq_samples: 16000
    )
  else
    MB::Sound.time_freq(
      MB::Sound::GraphNode::Resample::MODES.map { |m|
        [m, MB::M.skip_leading(40.hz.at(1).at_rate(400).resample(16000, mode: m).sample(17000), 0)[0...16000]]
      }.to_h,
      graphical: GRAPHICAL,
      time_samples: 1000,
      freq_samples: 16000
    )
  end

  sleep 2
  # Loop in graphical mode to allow window resizing (TODO: figure out why
  # gnuplot doesn't resize plots when the window is resized)
  break unless GRAPHICAL
end
