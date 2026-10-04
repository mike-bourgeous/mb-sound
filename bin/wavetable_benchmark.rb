#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby
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

  wt = nil
  phase = nil
  number = nil
  number_arr = nil
  phase_arr = nil


  MB::U.bench_csv(prefix: MB::U.ruby_info) do |bench|
    bench.report('build wavetable') do
      phase = 100.hz.ramp.at(1)
      phase_arr = phase.sample(samples)

      number = 1.hz.ramp.at(0..1)
      number_arr = number_arr = number.sample(samples)

      wt = phase.wavetable(wavetable: 'sounds/piano0.flac', number: number)
    end

    bench.report('sample wavetable once') do
      wt.sample(samples)
    end

    bench.report('sample wavetable in loop') do
      wt.multi_sample(800, samples / 800)
    end

    bench.report('pure ruby linear') do
      MB::Sound::Wavetable.wavetable_lookup_ruby(wavetable: wt.table, number: number_arr, phase: phase_arr.dup, lookup: :linear, wrap: :wrap)
    end

    bench.report('pure C linear') do
      MB::Sound::Wavetable.wavetable_lookup_c(wavetable: wt.table, number: number_arr, phase: phase_arr.dup, lookup: :linear, wrap: :wrap)
    end

    bench.report('pure ruby cubic') do
      MB::Sound::Wavetable.wavetable_lookup_ruby(wavetable: wt.table, number: number_arr, phase: phase_arr.dup, lookup: :cubic, wrap: :wrap)
    end

    bench.report('pure C cubic') do
      MB::Sound::Wavetable.wavetable_lookup_c(wavetable: wt.table, number: number_arr, phase: phase_arr.dup, lookup: :cubic, wrap: :wrap)
    end
  end
}
