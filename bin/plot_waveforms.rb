#!/usr/bin/env ruby
# Plots waveforms supported by MB::Sound::Oscillator and their spectra
# Usage: bin/plot_waveforms.rb

require 'bundler/setup'
require 'pry-byebug'
require 'mb-sound'

input = Numo::DComplex.linspace(0, 64.0 * Math::PI, 64000)

plots = MB::Sound::Oscillator::WAVE_TYPES.flat_map { |w|
  osc = MB::Sound::Oscillator.new(w)
  time = input.map { |v|
    osc.oscillator(v.real % (2.0 * Math::PI))
  }
  freq = MB::Sound.fft(time).abs.map(&:to_db)

  [
    [ "#{w.to_s.gsub('_', ' ')} time", { data: time[0..4000].real, yrange: [-1.1, 1.1] } ],
    [ "#{w.to_s.gsub('_', ' ')} freq", { data: freq[0..240], yrange: [-80, 0] } ],
  ]
}.to_h

MB::Sound.plotter(graphical: true, width: 960, height: 540).plot(plots, columns: 4)

begin
  STDIN.readline
rescue EOFError => e
end
