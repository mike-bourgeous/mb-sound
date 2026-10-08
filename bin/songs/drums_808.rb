#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A 16-bar TR-808 demo: a groove whose long kick is tuned to a bass line,
# accented hats and claps, a cowbell feature ("more cowbell"), a conga and
# rimshot break with a tom fill, and everything together at the end.
#
# Usage:
#     bin/songs/drums_808.rb                 # plays live in the background session
#     bin/songs/drums_808.rb drums.flac      # renders to a file instead (-f to overwrite)
#     bin/songs/drums_808.rb --cowbell 12    # even more cowbell (dB)
#     bin/songs/drums_808.rb --help          # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/drums_808.rb'
#     drums_808                              # live
#     render('drums.flac', bars: 16) { drums_808 }
#
# Snippets to try in bin/sound.rb (X is an accent, 6 dB louder by default):
#     bg :drums, tr808(grid(16, kick: 'X..x..x...x.x...', snare: '....X.......X...', hat: 'x.xXx.x.x.xXx.x.').loop)
#     bg :bell, tr808(grid(16, cowbell: 'X.x.x.X..x.X.x..').loop, more_cowbell: true)    # +6 dB of cowbell
#     bg :drums, tr808(grid(16, bd: 'x...x...', oh: '..x...x.', ch: 'x.x.x.x.').loop, kick: { tune: 45, decay: 1.2 }, accent: 10)
#     bg :boom, tr808(grid(16, kick: 'X.......x.x.....').loop, kick: { tune: seq(E1, G1, D1, A0).n1.loop.freq, decay: 3 })  # a tuned 808 bass
#     bg :wobble, tr808(grid(16, kick: 'x...').loop, kick: { tune: 0.25.hz.lfo.at(40..70), sigh: 1 })                     # moving knobs
#     bg :pads, tr808(midi)                  # a MIDI drum pad (GM notes: 36 kick, 38 snare, 42/46 hats, 56 cowbell, ...)
#     bg :file, tr808('spec/test_data/c2_sustain.mid', only: :kick)    # a .mid drum track
#     k = tr808(grid(16, kick: 'x...x...', clap: '....x...').loop); k[:kick]    # one voice of a kit
#     play 50.hz.lfo.square.wraps.ping(110, decay: 0.3)                # the resonator under the kick (any trigger)
#
# Voices: kick, snare, rimshot, clap, closed_hat (hat), open_hat, cymbal,
# cowbell, low/mid/high_tom, low/mid/high_conga, claves, maracas.
# Knobs: tune (Hz), decay (s), tone, snappy, level, sigh (kick).
#
# CPU (YJIT, % of realtime at 128 / 512-sample buffers, this container):
# the whole song about 18 / 8 at its busiest (bars 13-16).

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The song's length in bars.
  DRUMS_808_BARS = 16

  # Starts the song on the current session (live, or inside a render
  # block).  +cowbell+ is the extra cowbell level in dB.
  def self.drums_808(cowbell: 6.0)
    bpm 112

    # The kick's tune follows a bass line, one note per bar, with a long
    # decay: the 808 kick as a bass
    bass = seq(E1, E1, G1, D1).n1.loop
    groove = -> {
      tr808(
        grid(16,
          kick:     'X.....x...X..x..',
          clap:     '....X.......X..x',
          hat:      'x.xXx.x.x.xXx.xx',
          open_hat: '......x.......x.',
        ).loop,
        kick: { tune: bass.freq, decay: 1.8, tone: 0.4 },
        clap: { level: 0.5 },
      )
    }

    # The cowbell feature, with claves answering it
    bell = -> {
      tr808(
        grid(16,
          cowbell: 'X.x.x.X..x.X.x..',
          claves:  '...x.....x....x.',
        ).loop,
        more_cowbell: cowbell,
      )
    }

    # The break: congas, rimshots, and maracas, the congas following a
    # clip up a fifth in the second half (knobs can be any node)
    congas = seq(A3, A3, E4, E4).n1.loop
    latin = tr808(
      grid(16,
        low_conga:  'x..x....x..x..x.',
        mid_conga:  '..x...x...x...x.',
        high_conga: '.....X.x.....X.x',
        rimshot:    '..x..x..x..x.x..',
        maracas:    'x.xxx.xXx.xxx.xX',
      ).loop,
      low_conga: { tune: congas.freq },
      mid_conga: { tune: congas.transpose(7).freq },
      high_conga: { tune: congas.transpose(12).freq },
    )

    # A one-bar tom fill into the break, and a cymbal at the top of the end
    fill = tr808(grid(16,
      high_tom: 'X.x.x...........',
      mid_tom:  '......X.x.x.....',
      low_tom:  '............X.xX',
    ))
    crash = tr808(grid(16, cymbal: 'X'), cymbal: { decay: 2.5 })

    master_gain(-3.db)
    master { |mix| mix.softclip(0.7, 0.98) }

    bg :groove, groove.()
    at_bar(5) { bg :bell, bell.(), fade: 0 }
    at_bar(8) { bg :fill, fill, fade: 0 }
    at_bar(9) do
      stop :groove, fade: 0
      stop :bell, fade: 0
      bg :latin, latin, fade: 0
    end
    at_bar(13) do
      bg :crash, crash, fade: 0
      bg :groove, groove.(), fade: 0
      bg :bell, bell.(), fade: 0
    end
    at_bar(15) { outro fade: 2 }
  end

  if main_script?(__FILE__)
    song_script(
      bars: DRUMS_808_BARS,
      cowbell: [6.0, Float, '-c', 'More cowbell, in dB', -24.0..24.0],
    ) { |p| drums_808(cowbell: p.cowbell) }
  end
end
