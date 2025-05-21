#!/usr/bin/env ruby
# Applies time-varying Haas-effect panning to an audio file based on a sequence
# of relative delay values in milliseconds and timestamps in seconds.
#
# Usage: $0 in_file out_file time_s_1 delay_ms_1 [time_s_2 delay_ms_2 [...]]

require 'bundler/setup'
require 'mb-sound'

def usage
  puts MB::U.read_header_comment.join.gsub('$0', $0)
  exit 1
end

usage if ARGV.include?('--help') || ARGV.length == 0

begin
  in_file = ARGV.shift
  raise "Unable to read input file #{in_file.inspect}" unless File.readable?(in_file)

  out_file = ARGV.shift
  MB::U.prevent_overwrite(out_file, prompt: true)

  raise 'No delay times were given' if ARGV.empty?
  raise 'Expected an even number of arguments forming timestamp/delay pairs' if ARGV.length.odd?

  delays = ARGV.map { |v| Float(v) }.each_slice(2).map { |ts, delay|
    raise "Received a negative timestamp #{ts}" if ts < 0

    { time: ts, data: [ delay / 1000.0 ] }
  }

  input = MB::Sound.file_input(in_file, resample: nil, channels: 2)
  output = MB::Sound.file_output(out_file, sample_rate: input.sample_rate, channels: 2, overwrite: true)
  interp = MB::Sound::TimelineInterpolator.new(delays, default_blend: :smootherstep)
  haas = MB::Sound::HaasPan.new(delay: delays[0][:data][0], sample_rate: input.sample_rate, smoothing: 0.2)
  chunk = 10 # (input.sample_rate / 100.0).round

  interp.plot(MB::Sound.plotter)

  puts "Processing \e[1;33m#{in_file.inspect}\e[0m with \e[1;35m#{delays.length}\e[0m delay pairs, using a chunk size of \e[1;32m#{chunk}\e[0m samples..."

  ts = 0
  MB::Sound.process_time_stream(input, output, chunk, chunk) do |data|
    haas.delay = interp.value(ts)[0]
    ts += chunk.to_f / input.sample_rate
    haas.process(data)
  end

  # Drain the delay buffer
  final_delay = interp.value(ts)[0].abs
  if final_delay != 0
    output.write(haas.process([Numo::SFloat.zeros((final_delay * input.sample_rate).ceil)] * 2))
  end

  output.close
  input.close

  puts "\e[32mProcessing complete.\e[0m"

rescue => e
  puts "\e[1;33m#{e}\n\t\[22m#{e.backtrace.join("\n\t")}\e[0m"
  usage
end
