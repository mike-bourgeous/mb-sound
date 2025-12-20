#!/usr/bin/env ruby

require 'bundler/setup'
require 'benchmark'
require 'mb-sound'
    
wt = nil

Benchmark.bmbm do |bench|
  bench.report('build wavetable') do
    wt = 100.hz.ramp.at(0..1).wavetable(wavetable: 'sounds/piano0.flac', number: 1.hz.ramp.at(0..1)).forever
  end

  bench.report('sample wavetable once') do
    wt.sample(48000 * 60).length
  end

  bench.report('sample wavetable in loop') do
    wt.multi_sample(800, 60 * 60).length
  end
end

