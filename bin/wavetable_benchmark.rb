#!/usr/bin/env ruby

require 'bundler/setup'
require 'benchmark'
require 'mb-sound'
    
wt = nil
phase = nil
number = nil
number_arr = nil
phase_arr = nil

Benchmark.bmbm do |bench|
  bench.report('build wavetable') do
    phase = 100.hz.ramp.at(0..1).forever
    phase_arr = phase.sample(48000 * 60)

    number = 1.hz.ramp.at(0..1).forever
    number_arr = number_arr = number.sample(48000 * 60)

    wt = phase.wavetable(wavetable: 'sounds/piano0.flac', number: number)
  end

  bench.report('sample wavetable once') do
    wt.sample(48000 * 60)
  end

  bench.report('sample wavetable in loop') do
    wt.multi_sample(800, 60 * 60)
  end

  bench.report('pure ruby once') do
    MB::Sound::Wavetable.wavetable_lookup_ruby(wavetable: wt.table, number: number_arr, phase: phase_arr.dup)
  end

  bench.report('pure C once') do
    MB::Sound::Wavetable.wavetable_lookup_c(wavetable: wt.table, number: number_arr, phase: phase_arr.dup)
  end
end
