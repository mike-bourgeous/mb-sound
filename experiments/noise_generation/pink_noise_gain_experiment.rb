#!/usr/bin/env ruby
# An experiment to determine reasonable frequency domain amplitudes for
# generating pink noise in a range of -1..1 in the time domain by using
# descending gain with random phase.

require 'rubygems'
require 'bundler/setup'

require 'pry'
require 'pry-byebug'

$LOAD_PATH << File.expand_path('../../lib', __dir__)

require 'mb-sound'

# Histogram
$distr = Numo::Int64.zeros(1001)

$p = MB::M::Plot.new

$p2 = MB::M::Plot.new
$p2.plot(histogram: $distr)

def min_gain_for_bins(bins)
  ops = 30000
  loops = (27 + ops / bins)

  STDOUT.write "\r#{bins} bins #{loops} times\e[K"
  STDOUT.flush

  loops.times.map { |t|
    orig = MB::Sound::Noise.spectral_pink_noise(bins)
    binding.pry if orig.abs.sum == 0
    td = MB::Sound.real_ifft(orig, odd_length: false)
    norm = MB::Sound.real_fft(td / td.max)

    # Update global histogram
    MB::Sound.real_ifft(norm, odd_length: false).each do |v|
      histbin = MB::M.clamp(v * 500 + 500, 0, 1000)
      $distr[histbin] += 1
    end

    norm.abs.sum / orig.abs.sum
  }
end

def plot_things
  vals = {
    min: $gains.map(&:min),
    max: $gains.map(&:max),
    avg: $gains.map { |v| v.sum / v.size },
    percentnotone: $gains.map { |v| v.count { |g| g < 0.999 } / v.size.to_f }
  }

  $p.yrange(0, vals[:min].max * 2)
  $p.plot(vals)

  $p2.yrange(0, ($distr.max + 99).floor(-2))
  $p2.plot(histogram: $distr)
end

# We generate FFT pink noise a bunch of times and then find out the required
# gain curve relative to FFT size to prevent time domain clipping.
#
# The goal is to have the minimum gain as close to 1 as reasonable.
$gains = []
(10..2000).map { |bins|
  plot_things if bins % 20 == 0
  $gains << min_gain_for_bins(bins)
}

plot_things

STDIN.readline
