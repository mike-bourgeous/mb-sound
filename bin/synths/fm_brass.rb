#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A two-operator FM brass in the DX tradition: a 1:1 modulator with
# operator self-feedback (Tone#feedback) phase-modulating a sine carrier.
# The feedback runs inside the modulator's loop after its envelope (the
# `gain:` input), as on the DX7, so the modulator is brightest at the
# swell of each note and mellows as it decays: the brassy "blat".
# --feedback 0 plays the same patch with a plain sine modulator (the
# classic two-operator brass) to compare.
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# CC 1 (the mod wheel) adds up to 0.6 rad of feedback.
#
# Examples:
#     $0                                       # live MIDI
#     $0 spec/test_data/c_major.mid brass.flac
#     $0 --feedback 0 spec/test_data/c_major.mid nofb.flac   # A/B: no feedback
#     $0 --feedback 3 spec/test_data/c_major.mid             # adds a chaotic hiss above 12 kHz
#     $0 --feedback 5 spec/test_data/c_major.mid             # noise in the modulator: breathy, growling
#
# Operator feedback in the console (bin/sound.rb):
#     play 110.hz.feedback(1.3).at(-12.db)                       # a sine turned saw-like
#     play 110.hz.feedback(2.hz.lfo.at(0..2)).at(-12.db)         # sweeping brightness
#     e = adsr(0.08, 0.5, 0.6, 0.3, hold: 1)
#     play 220.hz.feedback(1.6, gain: e).at(-6.db)               # brightness follows the envelope
#     play (220.hz.feedback(1.6) * e).at(-6.db)                  # the same envelope outside: constant timbre
#     play 220.hz.pm(220.hz.feedback(1.2).at(1.5)).at(-12.db)    # a feedback modulator
#     play 880.hz.feedback(1.8).oversample(4).at(-12.db)         # high notes alias; oversample helps
#     Tone.dx7_feedback(6)                                       # => pi (DX7 FB 6 at full operator level)

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script(
  feedback: [1.4, Float, '-F', 'Modulator self-feedback in radians at full envelope (0 for none; hiss above 12 kHz from ~2.2, noise from ~4)', 0.0..6.3],
  index: [1.6, Float, '-x', 'Modulation index (radians) of the modulator into the carrier', 0.0..8.0],
  voices: [6, Integer, '-v', 'Number of voices', 1..32],
) { |midi, p|
  midi.synth(voices: p.voices) { |v|
    # The modulator's level envelope, applied inside the feedback loop:
    # a swell, a quick fall from the peak, and a lower sustain
    menv = v.fm_env(0.07, 0.45, 0.6, 0.25, curve: [-6, 20, 30], sensitivity: -6.db..0.db).named('Modulator envelope')
    amount = (p.feedback + v.cc(1, range: 0.0..0.6, name: 'Feedback')).named('Feedback amount')
    mod = v.hz.feedback(amount, gain: menv).at(p.index).named('Modulator')

    amp = v.amp_env(0.04, 0.8, 0.8, 0.25).named('Amplitude')
    (v.hz.sine.pm(mod) * amp * 0.8).named('Voice')
  }
}
