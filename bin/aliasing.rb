#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Measures aliasing and cost of oscillators and nonlinearities, and renders
# sweeps to listen to.  Each case is a Ruby expression of `p`, a Pitch (e.g.
# `p.ramp`, `p.sine.at(4).softclip`).
#
# Method: coherent sampling.  f0 = k * fs / N with k odd and N = 65536, so
# every harmonic and every alias lands exactly on an FFT bin (rectangular
# window, no leakage).  Harmonic bins are multiples of k; every other bin
# except DC is non-harmonic (aliases and noise).  Complex outputs are
# measured by their real parts, or with -c as complex signals (two-sided:
# negative frequencies count as non-harmonic).  Columns:
#
# - NHR<20k: non-harmonic power below 20 kHz relative to harmonic power (dB)
# - below f0: non-harmonic power below the fundamental (the most audible
#   aliases, inharmonic and unmasked) relative to harmonic power (dB)
# - worst: the largest single alias below 20 kHz relative to the strongest
#   harmonic (dBc)
# - top: the strongest harmonic from 10 to 20 kHz relative to the strongest
#   overall (dBc),
#   to compare high-frequency droop between methods
# - neg (with -c): power at negative frequencies relative to the harmonics
#   (with -c, harmonics are the multiples of f0 on both sides)
# - cost: CPU time per second of audio (% of realtime, one thread)
#
# With --render, each case is also rendered as an exponential sweep of `p`
# from 100 Hz to 8 kHz (one FLAC per case, plus a spectrogram PNG if ffmpeg
# can make one), so aliases can be heard and seen moving against the sweep.
#
# Usage: $0 [options] [expression ...]
#
# Examples:
#     $0                                  # the default cases
#     $0 'p.ramp' 'p.aramp'               # compare two expressions
#     $0 -k 4097 'p.sine.at(4).softclip'  # one frequency (~3 kHz)
#     $0 --render /tmp/sweeps 'p.ramp' 'p.aramp'
#     $0 -c 'p.complex_ramp' 'p.complex_ramp.pm(p.sine.at(0.5.radians.to_cycles))'  # complex outputs, two-sided

require 'bundler/setup'
require 'fileutils'
require 'mb-sound'

FS = 48000.0
N = 65536
WARMUP = 4800
BUF = 800

# Default cases.  Cases that use methods this version doesn't have are
# skipped.
OSCILLATORS = [
  'p.aramp', 'p.ramp',
  'p.asquare', 'p.square',
  'p.atriangle', 'p.triangle',
  'p.apulse(0.25)', 'p.pulse(0.25)',
].freeze

NONLINEAR = [
  'p.sine.at(4).asoftclip', 'p.sine.at(4).softclip',
  'p.sine.at(2).aclip(-1, 1)', 'p.sine.at(2).clip(-1, 1)',
  'p.sine.aabs', 'p.sine.abs',
  'p.sine.aquantize(0.25)', 'p.sine.quantize(0.25)',
].freeze

# Evaluates a case +expression+ with +p+ bound to a Pitch.
def build(expression, p)
  eval(expression, binding, expression) # rubocop:disable Security/Eval
end

def collect(node, total, complex: false)
  out = []
  while out.sum(&:length) < total
    buf = node.sample(BUF)
    raise "#{node} ended early" if buf.nil?
    out << buf.dup
  end
  data = Numo::NArray.concatenate(out)[0...total]
  return Numo::DComplex.cast(data) if complex

  data = data.real if data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex)
  Numo::DFloat.cast(data)
end

def db(power)
  power > 0 ? 10 * Math.log10(power) : -Float::INFINITY
end

def analyze(signal, k)
  pow = MB::Sound.real_fft(signal).abs**2
  bins = pow.length
  harm = Numo::Bit.zeros(bins)
  (k...bins).step(k).each { |b| harm[b] = 1 }
  nonharm = ~harm
  nonharm[0] = 0

  audible = Numo::Bit.zeros(bins)
  limit = (20000.0 / FS * N).floor
  audible[1..limit] = 1

  hpow = pow[harm].sum
  hmax = pow[harm].max
  na = pow[nonharm & audible]
  top_bins = ((limit / 2.0 / k).ceil..(limit / k)).map { |m| m * k }

  {
    nhr: db(na.sum / hpow),
    below: db(pow[1...k].sum / hpow),
    worst: db(na.max / hmax),
    top: top_bins.empty? ? -Float::INFINITY : db(top_bins.map { |b| pow[b] }.max / hmax),
  }
end

# Like .analyze for a complex +signal+: the two-sided spectrum, where the
# harmonics are the multiples of k on both sides (phase modulation, warps,
# and sync give an analytic waveform harmonics at negative frequencies too)
# and every other bin within +-20 kHz except DC is non-harmonic.  Adds
# :neg, the power at negative frequencies relative to all harmonics (none
# for an analytic waveform).
def analyze_complex(signal, k)
  pow = MB::Sound.fft(signal).abs**2
  n = pow.length
  half = n / 2
  harm = Numo::Bit.zeros(n)
  (k...half).step(k).each { |b| harm[b] = 1; harm[n - b] = 1 }
  limit = (20000.0 / FS * N).floor
  audible = Numo::Bit.zeros(n)
  audible[1..limit] = 1
  audible[(n - limit)..] = 1
  nonharm = ~harm
  nonharm[0] = 0

  hpow = pow[harm].sum
  hmax = pow[harm].max
  na = pow[nonharm & audible]
  top_bins = ((limit / 2.0 / k).ceil..(limit / k)).map { |m| m * k }
  below = pow[1...k].sum + pow[(n - k + 1)..].sum

  {
    nhr: db(na.sum / hpow),
    below: db(below / hpow),
    worst: db(na.max / hmax),
    top: top_bins.empty? ? -Float::INFINITY : db(top_bins.map { |b| pow[b] }.max / hmax),
    neg: db(pow[(half + 1)..].sum / hpow),
  }
end

def cost(node, seconds: 2.0)
  frames = (seconds * FS / BUF).ceil
  node.sample(BUF)
  t0 = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
  frames.times { node.sample(BUF) }
  100.0 * (Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID) - t0) / seconds
end

def render(expression, dir)
  seconds = 8.0
  n = (seconds * FS).round
  t = Numo::DFloat.new(n + BUF).seq / FS
  sweep = MB::Sound::ArrayInput.new(data: [Numo::SFloat.cast(100 * 80**(t / seconds))])
  node = build(expression, MB::Sound::Pitch.new(sweep))
  data = Numo::SFloat.cast(collect(node, n))
  peak = data.abs.max
  data *= 0.4 / peak if peak > 0.4

  name = expression.gsub(/[^A-Za-z0-9.()-]+/, '_').gsub(/[()]/, '_').gsub(/_+/, '_').sub(/\A_|_\z/, '')
  path = File.join(dir, "#{name}.flac")
  MB::Sound.write(path, [data], sample_rate: FS.to_i, overwrite: true)
  png = path.sub(/\.flac\z/, '.png')
  system('ffmpeg', '-loglevel', 'error', '-y', '-i', path, '-lavfi', 'showspectrumpic=s=1024x512:legend=1', png)
  path
end

MB::Sound.script(
  args: 0..,
  k: ['1365,4097,5461', String, 'Comma-separated odd FFT bins of the test frequencies (f0 = k * 48000 / 65536)', '-k'],
  render: [nil, String, 'Directory to render 100 Hz - 8 kHz sweeps into', '-r'],
  complex: [false, '-c', 'Analyze complex (analytic) outputs two-sided: negative frequencies count as non-harmonic; adds a column for their power'],
) { |args, p|
  cases = args.empty? ? OSCILLATORS + NONLINEAR : args
  ks = p.k.split(',').map { |v| Integer(v) }
  raise ArgumentError, 'k must be odd' if ks.any?(&:even?)

  cases = cases.select do |c|
    build(c, 100.hz)
    true
  rescue NoMethodError => e
    warn "Skipping #{c} (#{e.message.lines.first.strip})"
    false
  end

  ks.each do |k|
    f = k * FS / N
    puts
    puts format('f0 = %.1f Hz (k = %d)', f, k)
    if p.complex
      puts format('%-30s %8s %8s %8s %8s %8s %7s', 'case', 'NHR<20k', 'below f0', 'worst', 'top', 'neg', 'cost %')
    else
      puts format('%-30s %8s %8s %8s %8s %7s', 'case', 'NHR<20k', 'below f0', 'worst', 'top', 'cost %')
    end
    cases.each do |c|
      if p.complex
        r = analyze_complex(collect(build(c, f.hz), WARMUP + N, complex: true)[WARMUP..], k)
        puts format('%-30s %8.1f %8.1f %8.1f %8.1f %8.1f %7.3f', c, r[:nhr], r[:below], r[:worst], r[:top], r[:neg], cost(build(c, f.hz)))
      else
        r = analyze(collect(build(c, f.hz), WARMUP + N)[WARMUP..], k)
        puts format('%-30s %8.1f %8.1f %8.1f %8.1f %7.3f', c, r[:nhr], r[:below], r[:worst], r[:top], cost(build(c, f.hz)))
      end
    end
  end

  if p.render
    FileUtils.mkdir_p(p.render)
    cases.each { |c| puts "Rendered #{render(c, p.render)}" }
  end
}
