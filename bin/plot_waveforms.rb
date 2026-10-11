#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Plots the waveforms of MB::Sound::Tone and their spectra
#
# Usage: $0 [--imag] [-I] [-S FILE] [--width PX] [--height PX] [wave_type ...]
#
# Prints the plots in the terminal; -I shows them as an inline image
# (iTerm2, kitty, sixel), -S saves them (.svg, .png, .txt, .ans, .html).

require 'bundler/setup'
require 'pry-byebug'
require 'mb-sound'

MB::Sound.script(
  imag: [false, 'Plot the imaginary part of the waveforms'],
  width: [1800, 'Image width in pixels (with --image or --save)', 1..],
  height: [900, 'Image height in pixels (with --image or --save)', 1..],
  image: [false, '-I', 'Show an inline terminal image instead of text'],
  save: [nil, '-S', String, 'Save the plots to a file (.svg, .png, .txt, .ans, .html)'],
) { |waves, p|
  input = Numo::DComplex.linspace(0, 32.0, 64000) # 32 cycles

  plots = MB::Sound::Tone::WAVE_TYPES.flat_map { |w|
    next unless waves.empty? || waves.include?(w.to_s)

    time = input.map { |v|
      MB::Sound::Tone.value_at(w, v.real % 1.0)
    }
    freq = MB::Sound.fft(time).abs.map(&:to_db)

    t = time[0..4000]
    t = p.imag ? t.imag : t.real

    [
      [ "#{w.to_s.gsub('_', ' ')} time", { data: t, yrange: [-1.1, 1.1] } ],
      [ "#{w.to_s.gsub('_', ' ')} freq", { data: freq[0..240], yrange: [-80, 0] } ],
    ]
  }.compact.to_h

  plotter =
    if p.image
      MB::Sound::Plot::Plotter.graphical(width: p.width, height: p.height)
    else
      MB::Sound::Plot::Plotter.terminal(height_fraction: 1.0)
    end
  plotter.save_image(p.save, width: p.width, height: p.height) if p.save
  plotter.plot(plots, columns: waves.empty? ? 4 : nil)
  puts "Wrote #{p.save}" if p.save
}
