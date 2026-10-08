#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A TR-808-flavored drum kit played by MIDI (General MIDI drum notes).
#
# Notes: 36 kick, 37 rimshot, 38 snare, 39 clap, 42/44 closed hat, 46 open
# hat, 41/43/45 low tom, 47/48 mid tom, 50 high tom, 49-59 cymbal, 56
# cowbell, 60-64 congas, 69/70 maracas, 75-77 claves (any channel).  The
# closed hat chokes the open hat.  Live, CC 16-19 turn the kick's tune and
# decay, the snare's snappy, and the open hat's decay (each starts at its
# option's value in the middle of the knob).
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Examples:
#     $0                                          # live MIDI (a drum pad)
#     $0 --kick-tune 45 --cowbell 6               # a deeper kick and more cowbell
#     $0 spec/test_data/c2_sustain.mid kick.flac  # a MIDI file (C2 = 36, the kick)
#     $0 --acid-xml drums_808.xml                 # an ACID controller map

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script(
  kick_tune: [52.0, Float, '-t', 'Kick tune in Hz', 25.0..200.0],
  kick_decay: [2.4, Float, '-d', 'Kick decay in seconds (to -60 dB)', 0.05..10.0],
  snappy: [0.3, Float, '-s', 'Snare snappy (noise), 0..1', 0.0..1.0],
  hat_decay: [0.45, Float, '-H', 'Open hat decay in seconds', 0.05..4.0],
  accent: [6.0, Float, '-a', 'dB louder at velocity 127 than at 64 (6: about linear)', 0.0..24.0],
  cowbell: [0.0, Float, '-c', 'More cowbell, in dB', -24.0..24.0],
) { |midi, p|
  MB::Sound.tr808(
    midi,
    accent: p.accent,
    more_cowbell: p.cowbell,
    kick: { tune: p.midi_cc(16, :kick_tune, range: 0.5..2.0), decay: p.midi_cc(17, :kick_decay, range: 0.1..3.0) },
    snare: { snappy: p.midi_cc(18, :snappy, range: 0.0..1.0, relative: false) },
    open_hat: { decay: p.midi_cc(19, :hat_decay, range: 0.2..4.0) },
  )
}
