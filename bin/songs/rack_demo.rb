#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Racks (design/notes/racks.md): reusable pieces of graph with typed ports,
# applied like Procs.  8 bars at 112 BPM:
#
# - an mrack (notes in, notes out) arpeggiates a chord line merged with a
#   high counter line (note streams merge with +) and echoes it a fifth up,
# - an irack (notes in, audio out) plays it on a pluck,
# - a named arack with a sidechain port pumps the pad from the drum track
#   (the port is bound to the track by name: .with(side: :drums)),
# - a named arack colors the bass,
# - a named arack with knobs (racks R2) echoes the pluck: knob :space
#   (the knob :"dub/space") opens over bars 4-6, and :tone's lowpass
#   swings around its knob (knob(...).mod(lfo, depth:)).
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
#     help rack(:dub)          # ports, knobs with ranges, latency
#     turn :"dub/space", 0.8, over: 2.bars
#     rack(:dub).snap :wide; turn :"dub/space", 0.1; recall :"dub/wide", over: 1, only: [:space]
#     save :my_dub, rack(:dub) # a rack document; preset :my_dub gives the Rack back
#
# The dub rack is also a library preset (bin/save_presets.rb):
#     preset :dub_echo                       # the Rack
#     bg :try, seq(A3, C4, E4).n8.loop.synth { |v| v.hz.triangle.at(-20.db) * v.amp_env(0.002, 0.2, 0, 0.1) }.then(&rack(:dub_echo))
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

  # The dub echo rack (racks R2): echoes of the input, fed back by knob
  # :space and darkened by knob :tone, whose lowpass swings slowly around
  # the knob.  Defines the named rack :dub (or +name+) and returns it.
  def self.rack_demo_dub(name = :dub)
    arack(name) { |sig|
      space = knob(:space, 0.35, description: 'Echo level and feedback 0..1')
      tone = knob(:tone, 2400, range: 600..8000, curve: :exp, unit: 'Hz', description: 'Echo lowpass')
      echoes = sig.delay(3.n16, feedback: space * 0.7, wet: space, dry: 0)
      sig + echoes.filter(:lowpass, cutoff: tone.mod(0.13.hz.lfo, depth: 0.15))
    }
  end

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

    # Audio in with knobs: dub echoes for the pluck
    rack_demo_dub

    chords = seq(A2, F2, C3, G2).n2.loop
    counter = seq(nil, E5, nil, nil, nil, C5, nil, D5).n4.loop
    beat = grid(16, kick: 'x...x...x...x...', closed_hat: '..x...x...x...x.').loop
    bass_line = seq(A1, A1, nil, A2, F1, nil, C2, G1).n8.legato(0.8).loop

    track(:drums) { |k| tr808(k) * 1.6 }
    bg :drums, beat, fade: 0

    arp = (chords.stream.chord(:min7) + counter.stream).then(&sparkle)
    bg :pluck, arp.then(&pluck).then(&rack(:dub)) * 0.4, fade: 0

    pad = chords.chord(:min7).synth(voices: 8) { |v| (v.hz.ramp.at(0.5) + v.hz.triangle.at(0.5)).lp4(900) * v.amp_env(0.2, 0.5, 0.8, 0.6) }
    bg :pad, pad.then(&rack(:pump).with(side: :drums)) * 0.3, fade: 0

    bass = bass_line.synth(voices: 2) { |v| v.hz.ramp * v.amp_env(0.003, 0.2, 0.6, 0.08) }
    bg :bass, bass.then(&rack(:grit)) * 0.75, fade: 0

    at_bar(4) { turn :"dub/space", 0.7, over: 2 }
    at_bar(RACK_DEMO_BARS - 1) { outro fade: 1 }

    if show
      puts racks.map { |name, info| "#{name}: #{info}" }
      puts rack(:pump).to_ruby
      puts rack(:dub).to_ruby
      puts sparkle.to_ruby
    end
  end

  song_script(bars: RACK_DEMO_BARS, show: [false, 'print the racks and their definitions']) { |p| rack_demo(show: p.show) } if main_script?(__FILE__)
end
