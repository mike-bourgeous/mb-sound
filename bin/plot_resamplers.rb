#!/usr/bin/env ruby

require 'bundler/setup'

require 'mb-sound'

loop do
  MB::Sound.plot(
    MB::Sound::GraphNode::Resample::MODES.map { |m|
      123.hz.at(1).at_rate(1000).resample(16000, mode: m)
    },
    graphical: true
  )
  sleep 2
end
