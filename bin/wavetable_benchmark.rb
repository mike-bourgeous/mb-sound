#!/usr/bin/env ruby

require 'bundler/setup'
require 'benchmark'
require 'mb-sound'

wt = nil
phase = nil
number = nil
number_arr = nil
phase_arr = nil

SAMPLES = ENV['SAMPLES']&.to_i || 48000 * 60

Benchmark.bmbm do |bench|
  bench.report('build wavetable') do
    phase = 100.hz.ramp.at(1).forever
    phase_arr = phase.sample(SAMPLES)

    number = 1.hz.ramp.at(0..1).forever
    number_arr = number_arr = number.sample(SAMPLES)

    wt = phase.wavetable(wavetable: 'sounds/piano0.flac', number: number)
  end

  bench.report('sample wavetable once') do
    wt.sample(SAMPLES)
  end

  bench.report('sample wavetable in loop') do
    wt.multi_sample(800, SAMPLES / 800)
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
