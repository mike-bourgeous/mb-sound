#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# The endless ambient (the generative layer's phase G4, long form;
# design/notes/generative.md, "Long form"): the ambient genre template's
# instruments (a drone, singing bowls on loops in seconds, rin, gong, an FM
# koto, a Karplus-Strong harp, rain stick, rain and wind through a hiss
# bus) in a form that writes itself as it plays and never ends:
# `genre(:ambient).endless`.
#
# - Moods by a Markov chain (emerge, drift, bloom, hush, tide, dissolve),
#   each for 4 to 16 bars (16 to 64 s at 60 BPM), decided at each mood's
#   commit point; a dissolve leads into a new emerge.  Which layers play
#   and the weather follow the mood (its scene).
# - The key walks the yo scale on D, G, A, and E (another chain, a key
#   every 16 bars blending over its last 4; a 25.6-minute loop): the drone,
#   koto, and harp follow it, and the bowls, rin, and gong (D, E, A, in
#   every one of those keys) ring true throughout.
# - Every choice is a counter-based draw from a seed, so any moment can be
#   played cold: `--from 901 --seek` starts an hour in with what an
#   uninterrupted run plays there.
#
# Usage:
#     bin/songs/endless.rb                         # plays live, forever (Ctrl-C)
#     bin/songs/endless.rb -b 54 endless.flac      # renders 54 bars (3.6 minutes; -f overwrites)
#     bin/songs/endless.rb -s 2 -b 54 e2.flac      # another seed: other moods, the same keys
#     bin/songs/endless.rb --from 901 --seek -b 54 later.flac   # an hour in, cold
#     bin/songs/endless.rb --plan 20               # prints the first 20 moods (when each starts) and plays
#
# Or in bin/sound.rb:
#     genre(:ambient).endless.play                 # this piece
#     flow                                         # where it is, the last moods, what's next
#     goto :hush                                   # a hush next; the chain carries on from it
#     seek 901                                     # an hour in, as if it had played all along
#     genre(:ambient).endless.form.plan(seed: 1).first(10).map(&:section)

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # Bars an endless render plays without -b (3.6 minutes at 60 BPM).
  ENDLESS_BARS = 54

  # The endless ambient template, its mood chain reseeded with +seed+ (nil
  # keeps the template's own).
  def self.endless_ambient(seed: nil)
    genre(:ambient).endless(seed: seed)
  end

  # The first +count+ moods of +template+'s form as lines: bar, time, mood,
  # length.
  def self.endless_plan(template, count)
    bar_seconds = template.bar_length * 4 * 60 / template.tempo.to_r
    template.form.plan(seed: 0, bar_length: template.bar_length).first(count).map { |p|
      t = (p.start / template.bar_length * bar_seconds).to_f
      format('  bar %4d  %2d:%02d  %-9s %2d bars', (p.start / template.bar_length).to_i + 1, t.to_i / 60, t.to_i % 60, p.section, p.length)
    }
  end

  if main_script?(__FILE__)
    song_script(
      bars: ENDLESS_BARS,
      seed: [0, Integer, '-s', "The mood chain's seed (0 keeps the template's own)", 0..1_000_000],
      plan: [0, Integer, '--plan', 'Print the first N moods before playing', 0..10_000],
    ) { |p|
      t = endless_ambient(seed: p.seed.zero? ? nil : p.seed)
      puts endless_plan(t, p.plan) if p.plan > 0
      t.play
    }
  end
end
