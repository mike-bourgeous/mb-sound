#!/usr/bin/env ruby
# Plots an ADSR envelope with parameters given on the command line.
#
# Usage: $0 attack_time decay_time sustain_level release_time

require 'bundler/setup'
require 'pry-byebug'
require 'mb-util'
require 'mb-sound'

if ARGV.include?('--help') || ARGV.length != 4
  puts MB::U.read_header_comment($0)
  exit 1
end

env = MB::Sound::ADSREnvelope.new(
  attack_time: ARGV[0].to_f,
  decay_time: ARGV[1].to_f,
  sustain_level: ARGV[2].to_f,
  release_time: ARGV[3].to_f,
  rate: 48000
)

env.trigger(1)
a = env.sample(48000 * (env.attack_time + env.decay_time + 0.25))

env.release
b = env.sample(48000 * (env.release_time + 0.25))

MB::Sound.plotter(graphical: true, width: 960, height: 540).plot({ adsr: a.concatenate(b) })

begin
  STDIN.readline
rescue EOFError => e
end
