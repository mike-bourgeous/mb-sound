#!/usr/bin/env ruby

require 'bundler/setup'
require 'optionparser'
require 'mb-util'

AVAILABLE_BENCHMARKS = [:node_graph, :resampling, :wavetable]
$enabled_benchmarks = [:wavetable]

OptionParser.new do |opt|
  opt.banner = "Usage: #{$0} [options] [ruby version list]"

  AVAILABLE_BENCHMARKS.each do |name|
    opt.on("--#{name.to_s.gsub('_', '-')}", "Run only the #{name.to_s.gsub('_', ' ')} benchmark") do
      $enabled_benchmarks = [name]
    end
  end

  opt.on('--all', 'Run all benchmarks') do
    $enabled_benchmarks = AVAILABLE_BENCHMARKS
  end
end.parse!

if ARGV.any?
  VERSION_LIST=ARGV
else
  VERSION_LIST=%w{2.7 3.0 3.1 3.2 3.3 3.4 4.0}
end

MB::U.headline 'Benchmark audio code on multiple ruby versions'

puts "\n\e[1;36mBenchmarking versions:\n  \e[22m#{VERSION_LIST.join("\n  ")}\e[0m"
puts "\n\e[1;35mBenchmarks:\n  \e[22m#{$enabled_benchmarks.join("\n  ")}\e[0m"

results = VERSION_LIST.map { |version|
  puts "\n\e[38;5;242m----------------\n Setup ruby #{version}\n----------------\e[0m\n\n"

  puts "\n  \e[38;5;242mruby install\e[0m\n"
  system("rvm install #{version} > /dev/null")
  system("rvm #{version} do rvm gemset create mb-sound > /dev/null")

  puts "\n  \e[38;5;242mbundle install\e[0m\n"
  system("rvm #{version}@mb-sound do bundle install > /dev/null")

  puts "\n  \e[38;5;242mrake clean compile\e[0m\n"
  system("rvm #{version}@mb-sound do rake clean compile > /dev/null")

  puts "\n\e[1;33m------------------\nBenchmark ruby #{version}\n------------------\e[0m\n\n"

  # TODO: allow selecting script to run
  if $enabled_benchmarks.include?(:node_graph)
    puts "\n\e[1mRunning node graph benchmark\e[0m\n\n"

    puts "\n\e[1mbenchmark \e[36m#{version} \e[31mwithout jit\e[0m\n"
    node_graph_csv = `RUBYOPT='' rvm #{version}@mb-sound do bin/songs/node_graph_benchmark.rb --bench`

    puts "\n\e[1mbenchmark \e[36m#{version} \e[32mwith jit\e[0m\n"
    node_graph_jit_csv = `RUBYOPT=--jit rvm #{version}@mb-sound do bin/songs/node_graph_benchmark.rb --bench`
  end

  if $enabled_benchmarks.include?(:resampling)
    MB::U.headline 'Running resampling benchmark'

    puts "\n  \e[1mbenchmark \e[36m#{version} \e[31mwithout jit\e[0m\n"
    resampling_csv = `RUBYOPT='' rvm #{version}@mb-sound do bin/resample_benchmark.rb`

    puts "\n  \e[1mbenchmark \e[36m#{version} \e[32mwith jit\e[0m\n"
    resampling_jit_csv = `RUBYOPT=--jit rvm #{version}@mb-sound do bin/resample_benchmark.rb`
  end

  if $enabled_benchmarks.include?(:wavetable)
    MB::U.headline 'Running wavetable benchmark'

    puts "\n\e[1mbenchmark \e[36m#{version} \e[31mwithout jit\e[0m\n"
    wavetable_csv = `RUBYOPT='' rvm #{version}@mb-sound do bin/wavetable_benchmark.rb`

    puts "\n\e[1mbenchmark \e[36m#{version} \e[32mwith jit\e[0m\n"
    wavetable_jit_csv = `RUBYOPT=--jit rvm #{version}@mb-sound do bin/wavetable_benchmark.rb`
  end

  {
    node_graph: node_graph_csv,
    node_graph_jit: node_graph_jit_csv,
    resampling: resampling_csv,
    resampling_jit: resampling_jit_csv,
    wavetable: wavetable_csv,
    wavetable_jit: wavetable_jit_csv,
  }
}
