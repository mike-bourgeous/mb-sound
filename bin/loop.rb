#!/usr/bin/env ruby
# Loops an audio file until interrupted.

require 'bundler/setup'
require 'mb-sound'

MB::U.sigquit_backtrace

if ARGV.include?('--help') || ARGV.empty?
  puts "Usage: \e[1m#{$0}\e[0m sound_filename"
  exit 1
end

data = MB::Sound.read(ARGV[0])
inp = MB::Sound::ArrayInput.new(data: data, repeat: true)

MB::Sound.play inp
