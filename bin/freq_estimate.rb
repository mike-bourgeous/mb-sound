#!/usr/bin/env ruby
# Prints an estimate of the fundamental frequency of the given sound file.
#
# Usage:
#     $0 filename [min_frequency [max_frequency]]

require 'bundler/setup'

require 'mb-sound'

if ARGV.include?('--help')
  MB::U.print_header_help
  exit 1
end

filename, min_freq, max_freq, *_ = ARGV

raise 'No filename given' unless filename

min_freq ||= 20
max_freq ||= 2000

if min_freq || max_freq
  range = (min_freq&.to_f)..(max_freq&.to_f)
end

freq = MB::Sound.freq_estimate(MB::Sound.read(ARGV[0]).sum, range: range, cepstrum: false)

case
when freq.nil?
  puts "No frequency found in range #{range.inspect}"

when freq < 1
  puts "#{MB::M.sigformat(1.0 / freq, 5)}s (#{MB::M.sigformat(freq, 5)}Hz)"

else
  puts "#{MB::M.sigformat(freq, 5)}Hz"
end
