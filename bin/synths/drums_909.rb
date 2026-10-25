#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# A TR-909-flavored drum kit played by MIDI (General MIDI drum notes).
#
# Notes: 35/36 kick, 37 rimshot, 38/40 snare, 39 clap, 41/43/45 low tom,
# 47/48 mid tom, 50 high tom, 42/44 closed hat, 46 open hat, 49/52/55/57
# crash, 51/53/59 ride (any channel).  The closed hat chokes the open hat.
# Live, CC 16-19 turn the kick's decay and attack, the snare's snappy,
# and the open hat's decay (each starts at its option's value in the
# middle of the knob).
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Examples:
#     $0                                          # live MIDI (a drum pad)
#     $0 --kick-tune 45 --kick-decay 1.2          # a longer, deeper kick
#     $0 spec/test_data/c2_sustain.mid kick.flac  # a MIDI file (C2 = 36, the kick)
#     $0 --acid-xml drums_909.xml                 # an ACID controller map

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script(
  kick_tune: [50.0, Float, '-t', 'Kick tune in Hz', 25.0..200.0],
  kick_decay: [0.55, Float, '-d', 'Kick decay in seconds (to -60 dB)', 0.05..4.0],
  kick_attack: [0.5, Float, '-k', 'Kick attack (click), 0..1', 0.0..1.0],
  snappy: [0.6, Float, '-s', 'Snare snappy (noise), 0..1', 0.0..1.0],
  hat_decay: [0.9, Float, '-H', 'Open hat decay in seconds', 0.05..4.0],
  accent: [6.0, Float, '-a', 'dB louder at velocity 127 than at 64 (6: about linear)', 0.0..24.0],
) { |midi, p|
  MB::Sound.tr909(
    midi,
    accent: p.accent.db,
    kick: {
      tune: p.kick_tune,
      decay: p.midi_cc(16, :kick_decay, range: 0.25..2.0),
      attack: p.midi_cc(17, :kick_attack, range: 0.0..1.0, relative: false),
    },
    snare: { snappy: p.midi_cc(18, :snappy, range: 0.0..1.0, relative: false) },
    open_hat: { decay: p.midi_cc(19, :hat_decay, range: 0.2..4.0) },
  )
}
