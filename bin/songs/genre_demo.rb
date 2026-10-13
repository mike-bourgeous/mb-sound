#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A short arrangement built purely from a genre template (see
# MB::Sound::Genre and design/notes/genres.md): the template's tempo, knobs,
# master chain, a track per role (its suggested preset), its scenes, and its
# form scaled to about a minute (sections divided by a power of two, at
# least a bar each), or the whole form with --full.  No other code: what
# you hear is what the template says the genre is.
#
# The templates came from the persona panel experiment (2026-10-13): :dnb
# (Kez Volta, "Tunnel Vision"), :jungle (Nev Ashdown, "Memory Card"),
# :ambient (Kaede Rowntree, "Tin Roof, Slow River"), :funk (Tiko Marvell,
# "Loop Church"); :house and :techno are stubs from general knowledge
# waiting for a TR-909.
#
# Usage:
#     bin/songs/genre_demo.rb --genre dnb             # plays live (-G dnb; -g is graphviz)
#     bin/songs/genre_demo.rb -G jungle jungle.flac   # renders (-f to overwrite; --stems DIR)
#     bin/songs/genre_demo.rb -G ambient --full       # the whole form (about 5 minutes)
#     bin/songs/genre_demo.rb -G funk -s 30 --show    # half a minute, printing the template first
#     bin/songs/genre_demo.rb -G dnb --bpm 170        # another tempo
#
# Or in bin/sound.rb:
#     genres                                  # the list
#     genre :dnb                              # a summary; genre(:dnb).tips, .to_ruby
#     genre(:dnb).short.play                  # this script
#     genre(:dnb).setup; go :drop             # tracks and scenes to play by hand
#     genre(:dnb) { tempo 170; role :bass, :jungle_reese, duck: -8.db }.short.play

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  if main_script?(__FILE__)
    song_script(
      genre: [:dnb, Symbol, '-G', 'Genre template to play', Genre.names],
      full: [false, '-F', 'Play the whole form instead of about --seconds'],
      seconds: [60.0, Float, '-s', 'About how long the short form plays (seconds)', 5.0..3600.0],
      show: [false, 'Print the template as Ruby first'],
    ) { |p|
      t = genre(p.genre)
      t = t.short(p.seconds) unless p.full
      puts t.to_ruby if p.show
      puts t.summary
      t.play
    }
  end
end
