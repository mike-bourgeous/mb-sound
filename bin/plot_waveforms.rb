#!/usr/bin/env ruby
# Plots waveforms supported by MB::Sound::Oscillator and their spectra
# Usage: bin/plot_waveforms.rb

require 'bundler/setup'
require 'pry-byebug'
require 'mb-sound'

show_imag = !!ARGV.delete('--imag')

input = Numo::DComplex.linspace(0, 64.0 * Math::PI, 64000)

plots = MB::Sound::Oscillator::WAVE_TYPES.flat_map { |w|
  next unless ARGV.empty? || ARGV.include?(w.to_s)

  osc = MB::Sound::Oscillator.new(w)
  time = input.map { |v|
    osc.oscillator(v.real % (2.0 * Math::PI))
  }
  freq = MB::Sound.fft(time).abs.map(&:to_db)

  t = time[0..4000]
  t = show_imag ? t.imag : t.real

  [
    [ "#{w.to_s.gsub('_', ' ')} time", { data: t, yrange: [-1.1, 1.1] } ],
    [ "#{w.to_s.gsub('_', ' ')} freq", { data: freq[0..240], yrange: [-80, 0] } ],
  ]
}.compact.to_h

MB::Sound.plotter(graphical: true, width: 1800, height: 900).plot(plots, columns: ARGV.empty? ? 4 : nil)

begin
  STDIN.readline
rescue EOFError => e
end
