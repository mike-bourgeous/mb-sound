#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Demonstrates MB::Sound::Sequence: a looping bass line and drum grid played
# by simple synths through trigger/envelope nodes.
#
# Usage:
#     bin/songs/sequence_demo.rb                     # plays live until Ctrl-C
#     bin/songs/sequence_demo.rb --bpm 100           # at a different tempo
#     bin/songs/sequence_demo.rb -b 16 demo.flac     # renders 16 bars (default 8)
#     bin/songs/sequence_demo.rb --help              # all options

require 'bundler/setup'
require 'mb-sound'

# Running inside MB::Sound makes #seq, #grid, #bpm, etc. and note names like C2
# available just like in bin/sound.rb.
module MB::Sound
  song_script(bars: 8) {
    bpm 124

    # Two bars of bass: sixteenths by default, with a dotted-eighth and a
    # ratcheted note for variety
    bass = (
      seq(C2, C2, rest, C3, C2, rest, As1, G1).n16 |
      seq(C2.n8.d, Ds2, rest, F2.n4.ratchet(3), G2).n16
    ).loop

    # One bar of drums; the hat's last beat is a 32nd-note roll that gets louder
    beat = grid(16,
      kick:  'x...x...x...x..x',
      snare: '....x.......x..?',
      hat:   'x.x.x.x.x.x.'
    )
    hat = (beat[:hat] | seq(42).n4.roll(32, velocity: 0.2..1.0)).loop
    beat = beat.loop

    bass_env = bass.env(0.003, 0.1, 0.6, 0.04)
    bass_synth = bass.tone.ramp.at(1)
      .filter(:lowpass, cutoff: 300 + 2500 * bass.env(0.001, 0.12, 0.1, 0.05), quality: 5) * bass_env * 0.5

    kick = (40.constant + 90 * beat[:kick].env(0, 0.04, 0, 0.01)).tone.sine.at(1) * beat[:kick].env(0, 0.3, 0, 0.05)
    snare = noise.at(0.1).filter(:bandpass, cutoff: 1900, quality: 1.5) * beat[:snare].env(0, 0.12, 0, 0.05) * 2
    hats = noise.at(0.1).filter(:highpass, cutoff: 7500) * hat.env(0, 0.025, 0, 0.02, velocity: 0.1..1) * 0.6

    mix = (bass_synth + kick + snare + hats).softclip(0.5, 0.95)

    bg :demo, mix, fade: 0
  }
end
