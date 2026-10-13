#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A 16-bar TR-909 house-into-techno groove: four-on-the-floor kick with
# shuffled 16th hats, offbeat open hats and claps, a ride, a flammed snare
# roll building into a crash, then a darker techno half with a long tuned
# kick ("rumble"), rimshots, and toms.
#
# Usage:
#     bin/songs/drums_909.rb                 # plays live in the background session
#     bin/songs/drums_909.rb drums.flac      # renders to a file instead (-f to overwrite)
#     bin/songs/drums_909.rb --shuffle 4     # more swing (0..6, the 909's shuffle steps)
#     bin/songs/drums_909.rb --help          # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/drums_909.rb'
#     drums_909                              # live
#     render('drums.flac', bars: 16) { drums_909 }
#
# Snippets to try in bin/sound.rb (X is an accent, 6 dB louder by default):
#     bg :house, tr909(grid(16, kick: 'X...x...x...x...', clap: '....X.......X...', hat: 'xxXxxxXxxxXxxxXx', oh: '..x...x...x...x.').loop, shuffle: 2)
#     bg :techno, tr909(grid(16, kick: 'X...X...X...X...', rim: '..x..x....x..x..', ride: 'x.x.x.x.x.x.x.x.').loop, kick: { decay: 1.2, punch: 0.9, drive: 0.8 })
#     bg :roll, tr909(grid(16, snare: '3.4.5.6f7.8.9fXF').loop, flam: 14.ms)          # f / F: flams (F accented)
#     bg :flams, tr909(seq(D1, D1.flam, D1, D1.flam(30.ms), !D1.flam).n8.loop)            # flam marks on any clip
#     bg :rumble, tr909(grid(16, kick: 'X..xX..xX..xX..x').loop, kick: { tune: seq(A1, A1, C2, G1).n1.loop.freq, decay: 1.2 })   # a tuned kick
#     bg :hats, tr909(grid(16, hat: 'x' * 16).loop, hat: { decay: 2.bars.lfo.at(0.05..0.3) })                                  # moving hat decay
#     o = tr909(grid(16, kick: 'X...x...x...x...', clap: '....X.......X...', oh: '..x...x...x...x.').loop, outputs: :separate)
#     bg :outs, o[:kick].softclip(0.6) + o[:clap].reverb(:room) * 0.8 + o[:open_hat].delay(3.n16, feedback: 0.3)
#     bg :mine, kit(grid(16, kick: 'X...x...x...x...', clap: '....X.......X...').loop) { tr909 :kick, :clap, kick: { decay: 0.3 } }  # borrow voices
#
# Voices: kick, snare, rimshot (rim), clap, low/mid/high_tom, closed_hat
# (hat), open_hat (oh), crash, ride.  Knobs: kick tune (Hz), decay, attack,
# punch, drive; snare tune, tone, snappy, decay; toms and rimshot tune,
# decay; clap tone, decay; hats decay and tune (semitones); crash and ride
# tune, decay; every voice level.

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The song's length in bars.
  DRUMS_909_BARS = 16

  # Starts the song on the current session (live, or inside a render
  # block).  +shuffle+ is the 909 shuffle (0..6), +flam+ the snare roll's
  # flam spacing in seconds.
  def self.drums_909(shuffle: 2, flam: 0.016)
    bpm 124

    # House: the classic pattern, accents on the hats' "and"s
    house = -> {
      tr909(
        grid(16,
          kick: 'X...x...x...x...',
          clap: '....X.......X...',
          hat:  'x.xXx.x.x.xXx.xx',
          oh:   '..x...x...x...x.',
        ).loop,
        shuffle: shuffle,
        kick: { decay: 0.5 },
        open_hat: { decay: 0.35 },
      )
    }
    ride = -> { tr909(grid(16, ride: 'x.x.x.X.x.x.x.X.').loop, shuffle: shuffle, ride: { level: 0.3 }) }

    # The build: a snare roll rising to accents, with flams (f, F)
    roll = tr909(
      grid(16, snare: '3.f.4.f.5.5f6.6f|7.7f8888999XFXFX'),
      flam: flam,
      snare: { snappy: 0.75, tone: 0.65 },
    )

    # Techno: a rumbling kick tuned to a bass line, rimshots and toms
    notes = seq(A1, A1, C2, G1).n1.loop
    techno = -> {
      tr909(
        grid(16,
          kick: 'X...x...x...x..x',
          rim:  '..x..x....x..x.x',
          lt:   '.......x........',
          mt:   '...........x....',
          ht:   '..............x.',
          hat:  'xxXxxxXxxxXxxxXx',
          oh:   '..x...x...x...x.',
        ).loop,
        shuffle: shuffle,
        kick: { tune: notes.freq, decay: 0.8, punch: 0.85, drive: 0.6, attack: 0.7, level: 0.8 },
        closed_hat: { decay: 0.08, tune: -1 },
        open_hat: { decay: 0.25 },
        low_tom: { tune: notes.transpose(12).freq, level: 0.6 },
      )
    }
    crash = tr909(grid(16, crash: 'X'), crash: { level: 0.5 })

    master_gain(-4.db)
    master { |mix| mix.softclip(0.75, 0.98) }

    bg :house, house.()
    at_bar(5) { bg :ride, ride.(), fade: 0 }
    at_bar(7) { bg :roll, roll, fade: 0 }
    at_bar(9) do
      stop :house, fade: 0
      stop :ride, fade: 0
      bg :crash, crash, fade: 0
      bg :techno, techno.(), fade: 0
    end
    at_bar(13) { bg :house, house.(), fade: 0 }
    at_bar(15) { outro fade: 2 }
  end

  if main_script?(__FILE__)
    song_script(
      bars: DRUMS_909_BARS,
      shuffle: [2, Integer, '-s', 'TR-909 shuffle, 0..6', 0..6],
      flam: [0.016, Float, '-F', 'Flam spacing of the snare roll, in seconds', 0.0..0.05],
    ) { |p| drums_909(shuffle: p.shuffle, flam: p.flam) }
  end
end
