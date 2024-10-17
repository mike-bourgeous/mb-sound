#!/usr/bin/env ruby
# Plots phase difference effects of various experiments with the Hilbert IIR
# filter.  The goal is to understand how to get closer to 90deg phase across a
# wider range of the spectrum, what the effect of each filter is, etc.

require 'bundler/setup'

require 'mb-sound'

filters = {
  shifting: (-10..10).step(2).map do |i| MB::Sound::Filter::HilbertIIR.new(offset: i) end,
  stretching: (0.1..4.0).step(0.2).map do |i| MB::Sound::Filter::HilbertIIR.new(stretch: i) end,
  scaling: (0.1..4.0).step(0.2).map do |i| MB::Sound::Filter::HilbertIIR.new(scale: i) end,
}

filters.each do |group, flist|
  puts group.to_s.capitalize

  MB::Sound.plot(
    flist.map { |f|
      p1 = MB::Sound.unwrap_phase(f.sine_response(Numo::SFloat.linspace(0, Math::PI, 24000)))
      p2 = MB::Sound.unwrap_phase(f.cosine_response(Numo::SFloat.linspace(0, Math::PI, 24000)))

      p1 - p2
    },
    samples: 24000,
    graphical: true
  )

  gets
end
