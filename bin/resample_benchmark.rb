#!/usr/bin/env ruby

require 'bundler/setup'

require 'benchmark'

require 'mb-util'
require 'mb-sound'

MB::U.sigquit_backtrace

SAMPLE_COUNT = ENV['SAMPLES']&.to_i || 48000 * 180

MB::U.bench_csv(prefix: MB::U.ruby_info) do |bench|
  bench.report("ruby_zoh single sample") do
    100.hz.forever.at_rate(441)
      .resample(17000, mode: :ruby_zoh)
      .sample(SAMPLE_COUNT)
  end

  bench.report("ruby_zoh sample loop") do
    node = 100.hz.forever.at_rate(441)
      .resample(17000, mode: :ruby_zoh)

    (SAMPLE_COUNT.to_f / 716).ceil.times do
      node.sample(716)
    end
  end

  bench.report("ruby_zoh multi_sample()") do
    100.hz.forever.at_rate(441)
      .resample(17000, mode: :ruby_zoh)
      .multi_sample(716, (SAMPLE_COUNT.to_f / 716).ceil)
  end

  [233, 800, 4000].each do |bufsize|
    MB::Sound::GraphNode::Resample::MODES.each do |mode|
      upsample = 100.hz.forever.at_rate(1234).resample(5432, mode: mode)
      downsample = 100.hz.forever.at_rate(17000).resample(5432, mode: mode)

      bench.report("#{mode.inspect}@#{bufsize} upsampling") do
        (SAMPLE_COUNT.to_f / bufsize).ceil.times do
          upsample.sample(bufsize)
        end
      end

      bench.report("#{mode.inspect}@#{bufsize} downsampling") do
        (SAMPLE_COUNT.to_f / bufsize).ceil.times do
          downsample.sample(bufsize)
        end
      end
    end
  end
end
