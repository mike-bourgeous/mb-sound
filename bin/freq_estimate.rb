#!/usr/bin/env ruby
# Prints an estimate of the fundamental frequency of the given sound file.

require 'bundler/setup'

require 'mb-sound'

puts "#{MB::M.sigformat(MB::Sound.freq_estimate(MB::Sound.read(ARGV[0])), 5)}Hz"
