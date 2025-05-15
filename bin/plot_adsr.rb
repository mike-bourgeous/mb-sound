#!/usr/bin/env ruby
# Plots an ADSR envelope with parameters given on the command line.
#
# Usage: $0 attack_time decay_time sustain_level release_time [--db[=nn]] [--filter=freq]

require 'bundler/setup'
require 'pry-byebug'
require 'mb-util'
require 'mb-sound'

db = ARGV.find { |s| s =~ /^--db(=([-+]?\d+(\.\d+)?))?$/ }
if db
  ARGV.delete(db)
  db = $2&.to_f || 80
end

filter = ARGV.find { |s| s =~ /^--filter(=([-+]?\d+(\.\d+)?))?$/ }
if filter
  ARGV.delete(filter)
  filter = $2&.to_f || 10000
end

if ARGV.include?('--help') || ARGV.length != 4
  puts MB::U.read_header_comment.join.gsub('$0', $0)
  exit 1
end

env = MB::Sound::ADSREnvelope.new(
  attack_time: ARGV[0].to_f,
  decay_time: ARGV[1].to_f,
  sustain_level: ARGV[2].to_f,
  release_time: ARGV[3].to_f,
  sample_rate: 48000,
  filter_freq: filter || 1000
)

if db
  envplot = env.db(db)
else
  envplot = env
end

env.trigger(1)
a = envplot.sample(48000 * (env.attack_time + env.decay_time + 0.25))

env.release
b = envplot.sample(48000 * (env.release_time + 0.25))

MB::Sound.plotter(graphical: true, width: 960, height: 540).plot({ adsr: a.concatenate(b) })

begin
  STDIN.readline
rescue EOFError => e
end
