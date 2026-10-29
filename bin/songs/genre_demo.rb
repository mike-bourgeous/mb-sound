#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
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
#     bin/songs/genre_demo.rb -G techno -M club t.flac  # the club mastering preset instead of the template's chain
#     bin/songs/genre_demo.rb -G house -M vinyl --clip h.flac  # vinyl, its soft clipper rounding off the 909 kick
#     bin/songs/genre_demo.rb -G dnb -K pump.flac     # ducks keyed by the two-step :pump trigger track, not the kick
#     bin/songs/genre_demo.rb -G dnb -E song -S 3 d.flac        # a form the template's generator writes (seed 3; G4)
#     bin/songs/genre_demo.rb -G ambient -E endless -b 54 a.flac  # forever live; 54 bars (3.6 min) rendered
#
# Or in bin/sound.rb:
#     genres                                  # the list
#     genre :dnb                              # a summary; genre(:dnb).tips, .to_ruby
#     genre(:dnb).short.play                  # this script
#     genre(:dnb).setup; go :drop             # tracks and scenes to play by hand
#     genre(:dnb) { tempo 170; role :bass, :jungle_reese, duck: -8.db }.short.play
#     genre(:dnb).generative(seed: 3).play    # a generated form (-E song -S 3)
#     genre(:ambient).endless.play            # forever (-E endless)

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  if main_script?(__FILE__)
    song_script(
      genre: [:dnb, Symbol, '-G', 'Genre template to play', Genre.names],
      full: [false, '-F', 'Play the whole form instead of about --seconds'],
      seconds: [60.0, Float, '-s', 'About how long the short form plays (seconds)', 5.0..3600.0],
      show: [false, 'Print the template as Ruby first'],
      mastering: [:template, Symbol, '-M', "Master with a mastering preset instead of the template's chain (the template's mono_below and loudness range stay)", [:template, *Mastering.names]],
      clip: [false, "With -M club or vinyl: the preset's clip: true (club: a soft clipper in place of the fast limiter; vinyl: a soft clipper after the trim, so peaky mixes reach the target)"],
      pump: [false, '-K', "Key the ducks from the template's :pump line, a trigger track nobody hears (dnb's ghost-kick pump), instead of its sidechain"],
      generate: [:none, Symbol, '-E', "Play a form the template's generator writes as it plays (G4): song (one generated song, full length) or endless (forever; render with -b)", %i[none song endless]],
      form_seed: [0, Integer, '-S', "With -E: the generator's seed (0 keeps the template's own: another number grows another form)", 0..1_000_000],
    ) { |p|
      t = genre(p.genre)
      if p.pump
        raise ArgumentError, "Genre #{p.genre.inspect} has no :pump clip to key from" unless t.clips.key?(:pump)
        t = t.with { sidechain :pump, :pump }
      end
      unless p.mastering == :template
        preset = p.mastering
        options = p.clip ? { clip: true } : {}
        t = t.with { master nil; master preset, **options }
      end
      raise ArgumentError, '--clip goes with -M club or -M vinyl' if p.clip && !%i[club vinyl].include?(p.mastering)
      seed = p.form_seed.zero? ? nil : p.form_seed
      case p.generate
      when :song then t = t.generative(seed: seed)
      when :endless then t = t.endless(seed: seed)
      end
      t = t.short(p.seconds) unless p.full || p.generate != :none
      puts t.to_ruby if p.show
      puts t.summary
      t.play
    }
  end
end
