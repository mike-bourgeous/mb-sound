#!/usr/bin/env ruby
# Plots waveforms supported by MB::Sound::Oscillator and their spectra
#
# Usage: $0 [--imag] [--width PX] [--height PX] [wave_type ...]

require 'bundler/setup'
require 'pry-byebug'
require 'mb-sound'

MB::Sound.script(
  imag: [false, 'Plot the imaginary part of the waveforms'],
  width: [1800, 'Plot width in pixels', 1..],
  height: [900, 'Plot height in pixels', 1..],
) { |waves, p|
  input = Numo::DComplex.linspace(0, 64.0 * Math::PI, 64000)

  plots = MB::Sound::Oscillator::WAVE_TYPES.flat_map { |w|
    next unless waves.empty? || waves.include?(w.to_s)

    osc = MB::Sound::Oscillator.new(w)
    time = input.map { |v|
      osc.value_at(v.real % (2.0 * Math::PI))
    }
    freq = MB::Sound.fft(time).abs.map(&:to_db)

    t = time[0..4000]
    t = p.imag ? t.imag : t.real

    [
      [ "#{w.to_s.gsub('_', ' ')} time", { data: t, yrange: [-1.1, 1.1] } ],
      [ "#{w.to_s.gsub('_', ' ')} freq", { data: freq[0..240], yrange: [-80, 0] } ],
    ]
  }.compact.to_h

  MB::Sound.plotter(
    graphical: true,
    width: p.width,
    height: p.height
  ).plot(
    plots,
    columns: waves.empty? ? 4 : nil
  )

  begin
    STDIN.readline
  rescue EOFError => e
  end
}
