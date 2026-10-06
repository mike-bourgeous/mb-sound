#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Benchmarks wavetable synthesis and lookup, printing CSV (used by
# bin/benchmark_ruby_versions.rb).
#
# Usage: $0 [--samples N]

require 'bundler/setup'
require 'benchmark'
require 'mb-sound'

MB::Sound.script(
  args: 0,
  samples: [ENV['SAMPLES']&.to_i || 48000 * 60, 'Samples per benchmark (default from SAMPLES, else 1 minute)', 1..],
) { |_, p|
  samples = p.samples
  ruby_samples = [samples / 50, 4800].max

  table = nil
  osc = nil
  shaper = nil
  sample_tone = nil

  MB::U.bench_csv(prefix: MB::U.ruby_info) do |bench|
    bench.report('build wavetable') do
      table = MB::Sound::Wavetable.from_file('sounds/drums_wavetable.flac')
      osc = 100.hz.wavetable(table, scan: 1.hz.ramp.lfo.at(0..1))
      shaper = 100.hz.sine.at(-0.5..1.5).phase_table(table, scan: 0.5)
      sample_tone = 100.hz.wavetable(MB::Sound::Wavetable.from_file('sounds/piano0.flac', mode: :sample, root: 100, loop: 24000...48000))
    end

    bench.report('oscillator once') do
      osc.sample(samples)
    end

    bench.report('oscillator in loop') do
      osc.multi_sample(800, samples / 800)
    end

    bench.report('waveshaper in loop') do
      shaper.multi_sample(800, samples / 800)
    end

    bench.report('sample mode in loop') do
      sample_tone.multi_sample(800, samples / 800)
    end

    bench.report("pure ruby oscillator (#{ruby_samples} samples)") do
      t = 100.hz.wavetable(table, scan: 0.3)
      (ruby_samples / 800).times { t.sample_ruby(800) }
    end
  end
}
