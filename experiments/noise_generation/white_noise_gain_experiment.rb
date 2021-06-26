#!/usr/bin/env ruby
# An experiment to determine reasonable frequency domain amplitudes for
# generating white noise in a range of -1..1 in the time domain by using
# constant gain with random phase.

require 'bundler/setup'

require 'pry'
require 'pry-byebug'

$LOAD_PATH << File.expand_path('../../lib', __dir__)

require 'mb-sound'

def self.min_gain_for_bins(bins)
  ops = 100000
  loops = (25 + ops / bins)
  #loops.times.map { MB::Sound.real_fft(Sound.normalize_max([Sound.inv_pos_dft(Numo::DComplex.ones(bins).map { |v| Complex.polar(1.0, Random::DEFAULT.rand(2.0 * Math::PI)) }, false)])).abs.sum / (bins ** 0.5) }.min

  STDOUT.write "\r#{bins} bins #{loops} times\e[K"
  STDOUT.flush

  loops.times.map {
    orig = MB::Sound::Noise.spectral_white_noise(bins)
    td = MB::Sound.real_ifft(orig, odd_length: false)
    norm = MB::Sound.real_fft(td / td.max)
    norm.abs.sum / orig.abs.sum
  }
end

gains = (10..1000).map { |bins|
  min_gain_for_bins(bins)
}

# We generate FFT white noise a bunch of times and then find out the required
# gain to prevent time domain clipping.
#
# The goal is to have the minimum gain as close to 1 as reasonable.
p = MB::M::Plot.new
p.yrange(0, 2)
p.plot({min: gains.map(&:min), max: gains.map(&:max), avg: gains.map { |v| v.sum / v.size }, percentnotone: gains.map { |v| v.count { |g| g < 0.999 } / v.size.to_f }})
STDIN.readline
