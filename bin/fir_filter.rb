#!/usr/bin/env ruby
# Uses MB::Sound::Filter::FIR to design a filter with a desired response, and
# process a sound file with that filter.  The filter design algorithm is very
# crude, but it works.

require 'bundler/setup'
require 'pry-byebug'

$LOAD_PATH << File.expand_path('../lib', __dir__)

require 'mb/sound'

def usage(msg)
  puts "\e[1;31mError:\e[22m #{msg}\e[0m\n\n" if msg

  puts "Usage: #{$0} in_file out_file freq1 gain1 freq2 gain2 [freq3 gain3 ...]"
  puts "At least two frequency/gain pairs must be specified."
  puts "Append 'db' to gains to use decibles; otherwise they will be treated as complex linear."

  puts "\nExample (cut bass): #{$0} sounds/synth0.flac /tmp/x.flac 20 -60db 200 0db 2000 0db"

  exit(1)
end

in_file = ARGV.shift
usage "No input file given" unless in_file && !in_file.empty?
usage "Input file #{in_file} not found or not readable" unless File.readable?(in_file)

out_file = ARGV.shift
usage "No output file given" unless out_file && !out_file.empty?
usage "Output file exists" if File.exists?(out_file)

gains = {}
while ARGV.length >= 2
  freq = ARGV.shift.to_f
  gain = ARGV.shift

  if gain.downcase.end_with?('db')
    gain = gain.to_f.db
  else
    gain = gain.to_c
  end

  gains[freq] = gain
end

usage "Must specify at least two frequency/gain pairs" if gains.length < 2
usage "Specify an even number of numeric arguments (have #{ARGV} remaining)" if ARGV.length != 0

begin
  puts "Filtering \e[1;35m#{in_file}\e[0m to \e[1;36m#{out_file}\e[0m"

  filter = MB::Sound::Filter::FIR.new(gains.sort_by(&:first).to_h, rate: 48000)

  puts "\e[1;33mGains:\e[0m"
  puts MB::Sound::U.highlight(filter.gain_map)

  pad = Numo::SFloat.zeros(filter.window_length + filter.filter_length)

  sound = MB::Sound.read(in_file)
  processed = sound.map { |c|
    filter.reset(0)
    filter.process(c.concatenate(pad))[(filter.window_length - filter.filter_length)..-1]
  }

  MB::Sound.write(out_file, processed, rate: 48000)

rescue => e
  usage "#{e}\n\t#{e.backtrace.join("\n\t")}"
end
