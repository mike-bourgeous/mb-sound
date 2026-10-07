#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Plots the amplitude distribution (histogram and PDF) of every noise shape.
#
# Usage: $0 [options] [expression ...]
#
# A tone's #noise reads its waveform at random phases, so its values have
# the waveform's amplitude distribution: a ramp or triangle gives uniform
# noise, a sine the arcsine distribution (most values near the peaks), a
# square two values, and the gauss wave type an approximately Gaussian
# one.  This plots each shape's estimated density (a histogram scaled to
# area 1) with the theoretical density over it where one is known
# (uniform, arcsine, Gaussian with the measured mean and deviation), for
# the oscillator shapes, the wavetable library's shapes (at 1 Hz, so they
# read their brightest level, Gibbs ripples included), MB::Sound.noise,
# the spectral white/pink/brown noise of MB::Sound::Noise, and any
# expressions given (graph nodes, or NArrays; evaluated in MB::Sound).
# --print lists statistics instead of plotting: mean, deviation, range,
# crest factor, kurtosis (uniform 1.8, sine 1.5, square 1, Gaussian 3),
# and the total variation distance from the theory (0 = identical, 1 =
# disjoint; at the default settings sampling noise alone gives about
# 0.005-0.01).  A single block of spectral brown noise is far from
# Gaussian: its few lowest frequencies dominate (the central limit theorem
# needs many comparable components).
#
# Examples:
#     $0                                   # every shape, in the terminal
#     $0 -g                                # every shape in a gnuplot window
#     $0 --only gauss,sine,white --print   # statistics only
#     $0 --only none -e '1.hz.ramp.noise + 1.hz.ramp.noise'   # two uniforms: a triangle
#     $0 --only none -G -e 'noise.filter(500.hz.lowpass)'     # filtered uniform noise turns Gaussian
#     $0 --only none '1.hz.sine.noise * 1.hz.sine.noise' '1.hz.wavetable(:basic, scan: 0.5).noise'
#
# In the console (bin/sound.rb), the same plots:
#     hist(1.hz.gauss.noise.sample(200000), bins: 100, density: true)
#     arcsine = ->(x) { x.abs < 1 ? 1 / (Math::PI * Math.sqrt(1 - x * x)) : 0 }
#     hist(1.hz.sine.noise.sample(200000), bins: 100, pdf: arcsine)

require 'bundler/setup'
require 'mb-sound'

# Theoretical distributions: [label, density, cumulative distribution]
UNIFORM = ['uniform', ->(x) { x.abs <= 1 ? 0.5 : 0.0 }, ->(x) { (x.clamp(-1.0, 1.0) + 1) / 2 }].freeze
ARCSINE = [
  'arcsine',
  ->(x) { x.abs < 1 ? 1 / (Math::PI * Math.sqrt(1 - x * x)) : 0.0 },
  ->(x) { Math.asin(x.clamp(-1.0, 1.0)) / Math::PI + 0.5 },
].freeze

# A Gaussian with the mean and deviation of +data+.
def gaussian(data)
  m = data.mean
  s = data.stddev
  [
    format('Gaussian (sigma %.3f)', s),
    ->(x) { Math.exp(-0.5 * ((x - m) / s)**2) / (s * Math.sqrt(2 * Math::PI)) },
    ->(x) { 0.5 * (1 + Math.erf((x - m) / (s * Math.sqrt(2)))) },
  ]
end

# +count+ samples of +source+ (a graph node, NArray, or Array) as a DFloat.
def take(source, count)
  case source
  when Numo::NArray, Array
    d = Numo::DFloat.cast(source.is_a?(Array) ? source : (source.respond_to?(:real) ? source.real : source))
    return d[0...[count, d.length].min]
  end

  raise ArgumentError, "#{source.inspect} is neither a graph node nor an array" unless source.respond_to?(:sample)

  bufs = []
  total = 0
  while total < count && (buf = source.sample([4800, count - total].min))
    break if buf.empty?

    buf = buf.real if buf.respond_to?(:real) && (buf.is_a?(Numo::SComplex) || buf.is_a?(Numo::DComplex))
    bufs << Numo::DFloat.cast(buf)
    total += buf.length
  end
  raise ArgumentError, "#{source} gave no samples" if bufs.empty?

  Numo::DFloat.zeros(0).concatenate(*bufs)
end

# Time-domain noise from MB::Sound::Noise's spectral generators.
def spectral(color, count)
  bins = count / 2 + 1
  Numo::DFloat.cast(MB::Sound.real_ifft(MB::Sound::Noise.send("spectral_#{color}_noise", bins)))[0...count]
end

MB::Sound.script(
  args: 0..,
  only: [nil, '-O', String, 'Comma-separated names to plot (see --list; "none" for only expressions)'],
  expr: [nil, '-e', String, 'An expression to add (a graph node or NArray, evaluated in MB::Sound); positional arguments add more'],
  samples: [240000, '-n', Integer, 'Samples per shape', 1000..],
  bins: [100, '-b', Integer, 'Histogram bins', 4..10000],
  seed: [nil, '-s', Integer, 'Random seed (MB::Sound.seed; MB::Sound::Noise follows RANDOM_SEED only)'],
  graphical: [false, '-g', 'Plot in a gnuplot window instead of the terminal'],
  print: [false, '-p', 'Print statistics instead of plotting'],
  gaussian: [false, '-G', 'Compare shapes without a known theory (expressions too) with a fitted Gaussian'],
  list: [false, '-l', 'List the shape names and exit'],
) { |args, p|
  MB::Sound.seed(p.seed) if p.seed

  # name => [description, source maker, theory maker (data -> theory or nil)]
  shapes = {
    'uniform' => ['1.hz.ramp.noise', -> { 1.hz.ramp.noise }, ->(_) { UNIFORM }],
    'gauss' => ['1.hz.gauss.noise', -> { 1.hz.gauss.noise }, ->(d) { gaussian(d) }],
    'sine' => ['1.hz.sine.noise', -> { 1.hz.sine.noise }, ->(_) { ARCSINE }],
    'triangle' => ['1.hz.triangle.noise', -> { 1.hz.triangle.noise }, ->(_) { UNIFORM }],
    'square' => ['1.hz.square.noise (two values)', -> { 1.hz.square.noise }, ->(_) { nil }],
  }
  ideal = { sine: ARCSINE, triangle: UNIFORM, saw: UNIFORM, ramp: UNIFORM }
  MB::Sound::Wavetable.names.each do |name|
    next unless MB::Sound::Wavetable[name].mode == :cycle

    shapes["wt_#{name}"] = [
      "1.hz.wavetable(#{name.inspect}).noise#{' (ideal shape: ' + ideal[name][0] + ')' if ideal[name]}",
      -> { 1.hz.wavetable(name).noise },
      ->(_) { ideal[name] },
    ]
  end
  shapes['noise'] = ['MB::Sound.noise (2000.hz.ramp.noise)', -> { MB::Sound.noise }, ->(_) { UNIFORM }]
  %w[white pink brown].each do |color|
    shapes[color] = ["MB::Sound::Noise.spectral_#{color}_noise (one inverse FFT)", -> { spectral(color, p.samples) }, ->(d) { gaussian(d) }]
  end

  if p.list
    shapes.each { |name, (desc, _, _)| puts format('%-12s %s', name, desc) }
    next
  end

  if p.only
    names = p.only.split(',').map(&:strip)
    unknown = names - shapes.keys - ['none']
    abort "Unknown shape #{unknown.join(', ')} (see --list)" unless unknown.empty?

    shapes.select! { |name, _| names.include?(name) }
  end

  ([p.expr].compact + args).each_with_index do |text, i|
    shapes["expr #{i + 1}"] = [text, -> { MB::Sound.instance_eval(text) }, ->(_) { nil }]
  end
  abort 'Nothing to plot (see --list)' if shapes.empty?

  results = shapes.map { |name, (desc, make, theory)|
    data = take(make.call, p.samples)
    theory = theory.call(data)
    theory ||= gaussian(data) if p.gaussian && data.stddev > 0
    [name, desc, data, theory]
  }

  if p.print
    puts format('%-12s %8s %8s %8s %8s %8s %6s %8s  %s', 'shape', 'mean', 'sigma', 'min', 'max', 'crest dB', 'kurt', 'TV dist', 'theory')
    results.each do |name, _, d, theory|
      m = d.mean
      s = d.stddev
      kurt = s > 0 ? (((d - m) / s)**4).mean : Float::NAN
      crest = 20 * Math.log10(d.abs.max / Math.sqrt((d**2).mean))

      tv = nil
      if theory
        # Total variation distance over the bins (theory by its exact
        # probability in each bin, from the cumulative distribution)
        lim = [d.abs.max, 1.0].max
        _, dens = MB::Sound.density(d, bins: p.bins, range: -lim..lim)
        width = 2 * lim / p.bins
        cdf = theory[2]
        tv = 0.5 * (0...p.bins).sum { |k|
          a = -lim + k * width
          (dens[k] * width - (cdf.call(a + width) - cdf.call(a))).abs
        }
      end

      puts format('%-12s %+8.4f %8.4f %+8.4f %+8.4f %8.2f %6.2f %8s  %s', name, m, s, d.min, d.max, crest, kurt, tv ? format('%.4f', tv) : '-', theory ? theory[0] : '-')
    end
    next
  end

  # Each shape in its own pane: in the terminal one after another, in a
  # window all together
  panes = results.map { |name, desc, d, theory|
    lim = [d.abs.max * 1.02, 1.05].max
    centers, dens = MB::Sound.density(d, bins: p.bins, range: -lim..lim)
    curves = { 'estimate' => [centers, dens] }
    if theory
      xs = Numo::DFloat.linspace(-lim, lim, p.bins * 4 + 1)
      ys = Numo::DFloat.cast(xs.to_a.map { |x| theory[1].call(x) }).clip(0, dens.max * 1.5)
      curves[theory[0]] = [xs, ys]
    end
    ["#{name}: #{desc}", curves]
  }

  if p.graphical
    MB::Sound.overlay(panes.to_h, graphical: true)
    puts 'Press Enter to exit'
    begin
      STDIN.readline
    rescue EOFError, Interrupt
    end
  else
    panes.each { |title, curves| MB::Sound.overlay({ title => curves }) }
  end
}
