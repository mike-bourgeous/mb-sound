#!/usr/bin/env ruby
# Plays an audio file while showing meters.

require 'bundler/setup'
require 'pry-byebug'
require 'mb-sound'

if ARGV.include?('--help') || ARGV.empty?
  puts "Usage: \e[1m#{$0}\e[0m sound_filename"
  exit 1
end

MB::Sound.play ARGV[0]
