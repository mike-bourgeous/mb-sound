#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Racks (design/notes/racks.md): reusable pieces of graph with typed ports,
# applied like Procs.  8 bars at 112 BPM:
#
# - an mrack (notes in, notes out) arpeggiates a chord line merged with a
#   high counter line (note streams merge with +) and echoes it a fifth up,
# - an irack (notes in, audio out) plays it on a pluck,
# - a named arack with a sidechain port pumps the pad from the drum track
#   (the port is bound to the track by name: .with(side: :drums)),
# - a named arack colors the bass.
#
# Usage:
#     bin/songs/rack_demo.rb             # plays live in the background session
#     bin/songs/rack_demo.rb rack.flac   # renders to a file instead (-f to overwrite)
#     bin/songs/rack_demo.rb --show      # also prints the racks and the pluck's Ruby
#     bin/songs/rack_demo.rb --help      # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/rack_demo.rb'
#     rack_demo
#     racks                    # name => kind and ports, and where each is used
#     rack(:pump).to_ruby      # a rack's definition
#
# Racks to try in bin/sound.rb:
#     up = mrack { it.transpose(12) }
#     dreamy = up >> mrack { it.strum(30.ms) }        # Proc#>> order
#     bg :try, seq(A3, C4, E4).n4.loop.then(&dreamy).synth { |v| v.hz.triangle.at(-20.db) * v.amp_env }
#     vib = modrack(:vib) { |ctl| (ctl * 6).hz.lfo.at(0.98..1.02) }

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The demo's length in bars.
  RACK_DEMO_BARS = 8

  # Starts the demo on the current session (live, or inside a render block).
  # With +show+, prints the racks and the pluck part as Ruby.
  def self.rack_demo(show: false)
    bpm 112

    # Notes in, notes out: an arpeggio echoed a fifth up
    sparkle = mrack { |stream| stream.arp(:up, 16, octaves: 2).echo(3.n16, 2, pitch: 7, velocity: 0.55) }

    # Notes in, audio out: a pluck instrument
    pluck = irack(:pluck) { |stream|
      stream.synth(voices: 16) { |v|
        tone = v.hz.ramp.at(0.5) + v.hz.triangle
        tone.filter(:lowpass, cutoff: 500 + 3500 * v.env(0.001, 0.15, 0, 0.05), quality: 2) * v.amp_env(0.002, 0.3, 0, 0.12)
      }
    }

    # Audio in with a sidechain port: ducks the input under the side signal
    arack(:pump, side: :audio) { |sig, side:| sig.duck(side, amount: 14.db, threshold: -9.db, release: 1.n8) }

    # Audio in: a little grit for the bass
    arack(:grit) { |sig| sig.lp4(420, resonance: 0.35).softclip(0.4, 0.9) }

    chords = seq(A2, F2, C3, G2).n2.loop
    counter = seq(nil, E5, nil, nil, nil, C5, nil, D5).n4.loop
    beat = grid(16, kick: 'x...x...x...x...', closed_hat: '..x...x...x...x.').loop
    bass_line = seq(A1, A1, nil, A2, F1, nil, C2, G1).n8.legato(0.8).loop

    track(:drums) { |k| tr808(k) * 1.6 }
    bg :drums, beat, fade: 0

    arp = (chords.stream.chord(:min7) + counter.stream).then(&sparkle)
    bg :pluck, arp.then(&pluck) * 0.4, fade: 0

    pad = chords.chord(:min7).synth(voices: 8) { |v| (v.hz.ramp.at(0.5) + v.hz.triangle.at(0.5)).lp4(900) * v.amp_env(0.2, 0.5, 0.8, 0.6) }
    bg :pad, pad.then(&rack(:pump).with(side: :drums)) * 0.3, fade: 0

    bass = bass_line.synth(voices: 2) { |v| v.hz.ramp * v.amp_env(0.003, 0.2, 0.6, 0.08) }
    bg :bass, bass.then(&rack(:grit)) * 0.75, fade: 0

    at_bar(RACK_DEMO_BARS - 1) { outro fade: 1 }

    if show
      puts racks.map { |name, info| "#{name}: #{info}" }
      puts rack(:pump).to_ruby
      puts sparkle.to_ruby
    end
  end

  song_script(bars: RACK_DEMO_BARS, show: [false, 'print the racks and their definitions']) { |p| rack_demo(show: p.show) } if main_script?(__FILE__)
end
