#!/usr/bin/env ruby
# Installs several Ruby versions with rvm and runs the node graph,
# resampling, and wavetable benchmarks on each (with and without JIT),
# combining their CSV results.
#
# Usage: $0 [options] [ruby_version ...]
#
# Example:
#     $0 --all -o /tmp/results.csv 4.0 ruby-head

require 'bundler/setup'
require 'csv'
require 'mb-util'
require 'mb-sound'

AVAILABLE_BENCHMARKS = [:node_graph, :resampling, :wavetable]
DEFAULT_VERSIONS = %w{4.0}

def check_success(*msg)
  raise "#{msg} failed: #{$?}" unless $?.success?
end

def run_command(*args)
  clear_env = ENV.keys.select { |k| k.to_s.downcase.match?(/bundle|ruby/) }
  system(clear_env.map { |k| [k, nil] }.to_h, *args)
  check_success(*args)
end

MB::Sound.script(
  output: [nil, String, '-o', 'Save CSV results to a file instead of printing them'],
  node_graph: [false, 'Run the node graph benchmark'],
  resampling: [false, 'Run the resampling benchmark'],
  wavetable: [false, 'Run the wavetable benchmark (the default if none are chosen)'],
  all: [false, 'Run all benchmarks'],
) { |versions, p|
  version_list = versions.empty? ? DEFAULT_VERSIONS : versions
  csv_output = p.output ? File.open(p.output, 'wb') : $stdout

  enabled_benchmarks = AVAILABLE_BENCHMARKS.select { |name| p.all || p[name] }
  enabled_benchmarks = [:wavetable] if enabled_benchmarks.empty?

  MB::U.headline 'Benchmark audio code on multiple Ruby versions'
  puts "\e[33mWriting CSV to \e[1m#{csv_output.path}\e[0m"

  puts "\n\e[1;36mBenchmarking versions:\n  \e[22m#{version_list.join("\n  ")}\e[0m"
  puts "\n\e[1;35mBenchmarks:\n  \e[22m#{enabled_benchmarks.join("\n  ")}\e[0m"

  results = version_list.map { |version|
    puts "\n\e[38;5;242m----------------\n Setup ruby #{version}\n----------------\e[0m\n\n"

    puts "\n  \e[38;5;242mruby install\e[0m\n"
    run_command("rvm install #{version} > /dev/null")
    run_command("rvm #{version} do rvm gemset create mb-sound > /dev/null")

    puts "\n  \e[38;5;242mbundle install\e[0m\n"
    run_command("rvm #{version}@mb-sound do bundle install > /dev/null")

    puts "\n  \e[38;5;242mrake clean compile\e[0m\n"
    run_command("rvm #{version}@mb-sound do rake clean compile > /dev/null")

    puts "\n\e[1;33m------------------\nBenchmark ruby #{version}\n------------------\e[0m\n\n"

    jit_types = `rvm #{version}@mb-sound do ruby --help | grep -Eo -- "--.?jit"`.strip.lines.map { |l| l.strip.sub('--', '') }.uniq
    jit_types.delete('jit') if jit_types.length > 1

    jit_types.unshift(nil)

    version_results = {}

    jit_types.each do |jit|
      if jit
        puts "\n\e[1mbenchmark \e[36m#{version} \e[32mwith #{jit}\e[0m\n"
        opts = "--#{jit}"
      else
        puts "\n\e[1mbenchmark \e[36m#{version} \e[31mwithout jit\e[0m\n"
        opts = "''"
      end

      if enabled_benchmarks.include?(:node_graph)
        puts "\n\e[1mRunning node graph benchmark\e[0m\n\n"
        version_results[:"node_graph_#{jit || 'no_jit'}"] = `RUBYOPT=#{opts} rvm #{version}@mb-sound do bin/songs/node_graph_benchmark.rb --bench`
        check_success
      end

      if enabled_benchmarks.include?(:resampling)
        MB::U.headline 'Running resampling benchmark'
        version_results[:"resampling_#{jit || 'no_jit'}"] = `RUBYOPT=#{opts} rvm #{version}@mb-sound do bin/resample_benchmark.rb`
        check_success
      end

      if enabled_benchmarks.include?(:wavetable)
        MB::U.headline 'Running wavetable benchmark'
        version_results[:"wavetable_#{jit || 'no_jit'}"] = `RUBYOPT=#{opts} rvm #{version}@mb-sound do bin/wavetable_benchmark.rb`
        check_success
      end
    end

    [ version, version_results ]
  }.to_h

  MB::U.headline("RESULTS")

  header_keys = []

  # First gather all headers/keys across benchmarks
  results.each do |ruby_version, tests|
    puts "  \e[34mGetting headers from \e[1m#{ruby_version}\e[0m"
    tests.compact.each do |test, csv_text|
      puts "    \e[35mParsing headers from \e[1m#{test}\e[0m\n"
      test_csv = CSV.new(csv_text, headers: :first_row, return_headers: true)
      header_keys |= test_csv.first.headers
    end
  end

  puts "  \e[34mWriting CSV to \e[1m#{csv_output.path}\e[0m"

  csv = CSV.new(csv_output, headers: header_keys, write_headers: true)
  results.each do |ruby_version, tests|
    tests.compact.each do |test, csv_text|
      test_csv = CSV.new(csv_text, headers: :first_row, return_headers: false)
      test_csv.read.each do |r|
        csv << header_keys.map { |k| r[k] }
      end
    end
  end
}
