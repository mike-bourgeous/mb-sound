#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Measures the interpolation error and aliasing of modulated delays against
# an exact answer.  A sine x[n] = sin(2π f0 n / fs) through a delay of d[i]
# samples should give y[i] = sin(2π f0 (i - d[i]) / fs), whose frequency is
# f0 * (1 - d'[i]).  Where that is below Nyquist (with a margin), the error
# against y is the interpolation error; where it is above Nyquist, a
# band-limited delay outputs nothing, so any output there is aliasing.
#
# Reports, in dB relative to the input level:
# - in-band error: RMS(output - y) where the output frequency < 0.45 fs
# - aliasing: RMS(output) where the output frequency > 0.55 fs
#
# Usage: $0 [options]
#
# Examples:
#     $0
#     $0 --interpolation cubic

require 'bundler/setup'
require 'mb-sound'

RATE = 48000.0

# Name => [sine Hz, LFO Hz, center delay (samples), LFO depth (samples)]
CASES = {
  'static fractional 15k' => [15000, 0, 480.37, 0],
  'chorus 5k' => [5000, 0.5, 960, 96],
  'chorus 15k' => [15000, 0.5, 960, 96],
  'flanger 12k' => [12000, 0.3, 216, 168],
  'fast vibrato 10k' => [10000, 6, 480, 48],
  'pitch up past Nyquist 20k' => [20000, 2, 1700, 1500],
}.freeze

# Returns [in-band error dB, aliasing dB or nil] for one case.
def measure(f0, fm, center, depth, seconds, options)
  n = (seconds * RATE).round
  pad = (center + depth + 10).ceil
  i = Numo::DFloat.new(n).seq
  d = center + depth * Numo::NMath.sin(2 * Math::PI * fm * i / RATE)
  slope = depth * 2 * Math::PI * fm / RATE * Numo::NMath.cos(2 * Math::PI * fm * i / RATE)
  out_freq = f0 * (1 - slope)
  ideal = Numo::NMath.sin(2 * Math::PI * f0 * (i - d) / RATE)

  input = MB::Sound::ArrayInput.new(data: [Numo::SFloat.cast(Numo::NMath.sin(2 * Math::PI * f0 * Numo::DFloat.new(n).seq / RATE))])
  times = MB::Sound::ArrayInput.new(data: [Numo::SFloat.cast(d / RATE)])
  out = Numo::DFloat.cast(input.delay(seconds: times, smoothing: false, max_delay: 2.0 * pad / RATE, **options).multi_sample(800, (n / 800.0).ceil)[0...n])

  valid = Numo::Bit.cast(i >= pad)
  in_band = valid & (out_freq < 0.45 * RATE)
  above = valid & (out_freq > 0.55 * RATE)

  err = out - ideal
  in_band_db = 10 * Math.log10((err[in_band] ** 2).mean / 0.5)
  aliasing_db = above.count_true > 0 ? 10 * Math.log10((out[above] ** 2).mean / 0.5) : nil
  [in_band_db, aliasing_db]
end

MB::Sound.script(
  seconds: [4.0, '-s', 'Seconds per case', 1.0..],
  interpolation: [nil, String, 'Interpolation mode to pass to #delay (default: the delay default)'],
) { |_, p|
  options = p.interpolation ? { interpolation: p.interpolation.to_sym } : {}
  puts format('%-28s %14s %12s', 'case', 'in-band error', 'aliasing')
  CASES.each do |name, (f0, fm, center, depth)|
    err, alias_db = measure(f0, fm, center, depth, p.seconds, options)
    puts format('%-28s %11.1f dB %12s', name, err, alias_db ? format('%.1f dB', alias_db) : '-')
  end
}
