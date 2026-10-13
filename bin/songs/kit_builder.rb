#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A drum machine of our own, built with the kit builder: a "junkyard"
# kit of a hand-made kick, an FM can-snare, a tuned log drum that plays a
# melody (its tune knob follows a clip), a reversed swell made from a
# bounced sample, metal hats, and two borrowed voices (the 909's clap and
# the 808's cowbell), with flams and shuffle.
#
# Usage:
#     bin/songs/kit_builder.rb                 # plays live in the background session
#     bin/songs/kit_builder.rb junk.flac       # renders to a file instead (-f to overwrite)
#     bin/songs/kit_builder.rb --shuffle 0     # straight
#     bin/songs/kit_builder.rb --help          # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/kit_builder.rb'
#     junk = MB::Sound.junkyard_kit                         # the Drums::Machine
#     bg :junk, junk.kit(junk.grid(16, kick: 'X..x..x...x.....', can: '....X.......X..x', log: 'x.x..x.x..x.x..x').loop)
#
# Snippets to try in bin/sound.rb:
#     zap = kit { voice(:zap, tune: 900) { |h| h.fm(h.tune, ratio: 3.5, index: 4, decay: 0.08, index_decay: 0.02, sweep: 2) } }
#     bg :zaps, zap.kit(zap.grid(16, zap: 'x..x..x.x.xxx..x').loop, zap: { tune: seq(900, 1200, 600, 1500).n4.loop.value })
#     bg :mine, kit(grid(16, kick: 'X...x...', snare: '....X...').loop) {
#       voice(:kick) { body(48, decay: 0.6, sweep: 4).softclip(0.6) + click(0.4) }
#       voice(:snare, snappy: 0.7) { body(190, decay: 0.1) * 0.5 + noise(decay: 0.2, highpass: 1500, lowpass: 9000) * snappy }
#     }
#     hit = bounce(1.beat) { 220.hz.saw.lp4(1200) * adsr(0.001, 0.2, 0, 0.1) }
#     bg :smp, kit(grid(16, kick: 'x..x..x.').loop) { voice :kick, hit, tune: -5 }     # any Sample as a voice
#     bg :both, kit(grid(16, kick: 'X...x...', clap: '....X...', cb: '..x...x.').loop) { tr909 :kick, :clap; tr808 :cowbell }
#
# Voice blocks get a Drums::Hit (h): h.t (the trigger), knob readers, and
# layers h.body / h.noise / h.click / h.metal / h.sample / h.fm / h.bursts,
# h.env / h.sweep / h.velocity; blocks without |h| run on the hit itself.

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The song's length in bars.
  KIT_BUILDER_BARS = 12

  # The junkyard kit (a Drums::Machine), with a +swell+ Sample for its
  # reversed swell voice.
  def self.junkyard_kit(swell)
    kit(name: :junkyard) {
      # A kick from scratch: a swept sine, driven, and a click
      voice :kick, tune: 46, decay: 0.45 do |h|
        h.body(h.tune, decay: h.decay, sweep: 3.5, sweep_time: 20.ms, drop: 0.2).softclip(0.55, 1.0) + h.click(0.35, tone: 0.7)
      end

      # A tin can: an inharmonic FM strike over a short burst of noise
      voice :can, tune: 410, snappy: 0.5, gm: 38, as: :snare, level: 0.7 do |h|
        tin = h.fm(h.tune, ratio: 2.71, index: 1.5, index_decay: 30.ms, decay: 0.16)
        h.mix(tin * 0.55, h.noise(decay: 0.12, highpass: 2500, lowpass: 9000) * h.snappy)
      end

      # A log drum whose pitch drops a little after the strike; its tune
      # knob plays a melody in the song
      voice :log, tune: 220, gm: 60, level: 0.55 do |h|
        h.body(h.tune, decay: 0.35, sweep: 0.15, sweep_time: 8.ms) + h.body(h.hz(h.tune) * 2.76, decay: 0.08) * 0.3
      end

      # A reversed swell (a bounced sample), tuned by the knob
      voice :swell, swell.rev, gm: 61, tune: 0, level: 0.8

      # Hats from the 808's square bank, brighter and shorter
      voice :closed_hat, decay: 0.05, level: 0.5 do
        metal(240).filter(:highpass, cutoff: 8500, quality: 0.8) * env(decay) * 4
      end
      voice :open_hat, decay: 0.3, level: 0.4 do
        metal(240).filter(:highpass, cutoff: 7500, quality: 0.8) * env(decay, curve: 40) * 3
      end
      choke :open_hat, by: :closed_hat

      # Borrowed: the 909's clap, the 808's cowbell
      tr909 :clap, clap: { decay: 0.4, level: 0.9 }
      tr808 :cowbell, cowbell: { level: 0.4 }
    }
  end

  # Starts the song on the current session (live, or inside a render
  # block).  +shuffle+ is the 909-style shuffle (0..6).
  def self.kit_builder(shuffle: 3)
    bpm 104

    swell = bounce(1.beat, bpm: 104) { 165.hz.saw.lp4(2400, resonance: 0.4) * adsr(0.002, 0.45, 0, 0.05) }
    junk = junkyard_kit(swell)
    melody = seq(A3, C4, E4, G3, A3, D4, C4, E4).n8.loop

    groove = -> {
      junk.kit(
        junk.grid(16,
          kick:  'X..x..x...x..x..',
          can:   '....X.......X..f|....X..f....X..f',
          hat:   'x.xXx.x.x.xXx.x.',
          oh:    '......x.......x.',
          log:   '..x..x.x..x..x.x',
        ).loop,
        flam: 22.ms,
        shuffle: shuffle,
        log: { tune: melody.freq },
      )
    }
    extras = -> {
      junk.kit(junk.grid(16, swell: '............x...', clap: '....x.......x...', cb: 'x..x..x...x..x..').loop, shuffle: shuffle)
    }

    master_gain(-2.db)
    master { |mix| mix.softclip(0.75, 0.98) }

    bg :groove, groove.()
    at_bar(5) { bg :extras, extras.(), fade: 0 }
    at_bar(9) { stop :extras, fade: 0 }
    at_bar(11) { outro fade: 2 }
  end

  if main_script?(__FILE__)
    song_script(
      bars: KIT_BUILDER_BARS,
      shuffle: [3, Integer, '-s', 'Shuffle, 0..6', 0..6],
    ) { |p| kit_builder(shuffle: p.shuffle) }
  end
end
