#!/usr/bin/env ruby
# Plots phase difference effects of various experiments with the Hilbert IIR
# filter.  The goal is to understand how to get closer to 90deg phase across a
# wider range of the spectrum, what the effect of each filter is, etc.

require 'bundler/setup'

require 'mb-sound'

filters = {
  original: [ MB::Sound::Filter::HilbertIIR.new ],
  fine_scale: (0.8..1.2).step(0.05).map { |i| MB::Sound::Filter::HilbertIIR.new(scale: i) },
  very_fine_scale: (0.95..1.05).step(0.01).map { |i| MB::Sound::Filter::HilbertIIR.new(scale: i) },
  scale_and_stretch: (0.8..1.4).step(0.1).map { |i| MB::Sound::Filter::HilbertIIR.new(scale: 1, stretch: i) },
  shifting: (-10..10).step(2).map { |i| MB::Sound::Filter::HilbertIIR.new(offset: i) },
  stretching: (0.1..4.0).step(0.2).map { |i| MB::Sound::Filter::HilbertIIR.new(stretch: i) },
  scaling: (0.1..4.0).step(0.2).map { |i| MB::Sound::Filter::HilbertIIR.new(scale: i) },
  interpolating: (15.5..17.5).step(0.05).map { |i| MB::Sound::Filter::HilbertIIR.new(interp: i) },
}

def linlogspace(min, max, count)
  Numo::SFloat.logspace(Math.log10(min), Math.log10(max), count)
end

filters.each do |group, flist|
  puts group.to_s.capitalize

  flist.each.with_index do |f, idx|
    #d = 180 / Math::PI * (MB::Sound.unwrap_phase(f.sine_response(Numo::SFloat.linspace(0, Math::PI, 24000))) - MB::Sound.unwrap_phase(f.cosine_response(Numo::SFloat.linspace(0, Math::PI, 24000))))
    d = 180 / Math::PI * (MB::Sound.unwrap_phase(f.sine_response(linlogspace(Math::PI/1200, Math::PI * 5/6, 24000))) - MB::Sound.unwrap_phase(f.cosine_response(linlogspace(Math::PI/1200, Math::PI * 5/6, 24000))))
    #d = d[20..20000]
    puts "Filter at index #{idx}: #{MB::U.highlight({first: d[0], last: d[-1], min: d.min, max: d.max, mean: d.mean, dev: d.stddev})}"
    puts "  #{MB::U.highlight((f.instance_variables - [:@filters]).map { |n| [n, f.instance_variable_get(n)] }.to_h)}\n\n"
  end

  MB::Sound.plot(
    flist.map { |f|
      p1 = MB::Sound.unwrap_phase(f.sine_response(linlogspace(Math::PI/1200, Math::PI * 5/6, 24000))) * 180 / Math::PI
      p2 = MB::Sound.unwrap_phase(f.cosine_response(linlogspace(Math::PI/1200, Math::PI * 5/6, 24000))) * 180 / Math::PI

      (p1 - p2)#[20..20000]
    },
    samples: ENV['SAMPLES']&.to_i || 24000,
    graphical: true
  )

  gets
end
