#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Plots an ADSR envelope with parameters given on the command line.
#
# Usage: $0 [--db RANGE] [--filter HZ] attack_time decay_time sustain_level release_time
#
# Example:
#     $0 --db 60 0.01 0.2 0.5 1.0

require 'bundler/setup'
require 'pry-byebug'
require 'mb-util'
require 'mb-sound'

MB::Sound.script(
  args: 4,
  db: [nil, Float, 'Plot in decibels over this range (e.g. 80)'],
  filter: [1000.0, 'Envelope smoothing filter frequency in Hz'],
) { |(attack, decay, sustain, release), p|
  env = MB::Sound::ADSREnvelope.new(
    attack_time: Float(attack),
    decay_time: Float(decay),
    sustain_level: Float(sustain),
    release_time: Float(release),
    sample_rate: 48000,
    filter_freq: p.filter
  )

  if p.db
    envplot = env.db(p.db)
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
}
