#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A two-operator FM brass in the DX tradition: a 1:1 modulator with
# operator self-feedback (Tone#fm_feedback) phase-modulating a sine carrier.
# The feedback runs inside the modulator's loop after its envelope (the
# `gain:` input), as on the DX7, so the modulator is brightest at the
# swell of each note and mellows as it decays: the brassy "blat".
# --feedback 0 plays the same patch with a plain sine modulator (the
# classic two-operator brass) to compare.
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# CC 1 (the mod wheel) sets the feedback from 0 to 1 cycle (2pi radians,
# Tone::FEEDBACK_MAX), starting at --feedback.  Feedback and index are in
# cycles (phases count cycles since 2026-10-10; the defaults are about the
# patch's original 1.4 and 1.6 radians).
#
# Examples:
#     $0                                       # live MIDI
#     $0 spec/test_data/c_major.mid brass.flac
#     $0 --feedback 0 spec/test_data/c_major.mid nofb.flac   # A/B: no feedback
#     $0 --feedback 0.48 spec/test_data/c_major.mid          # adds a chaotic hiss above 12 kHz
#     $0 --feedback 0.8 spec/test_data/c_major.mid           # noise in the modulator: breathy, growling
#
# Operator feedback in the console (bin/sound.rb):
#     play 110.hz.fm_feedback(0.2).at(-12.db)                       # a sine turned saw-like
#     play 110.hz.fm_feedback(2.hz.lfo.at(0..0.32)).at(-12.db)      # sweeping brightness
#     e = adsr(0.08, 0.5, 0.6, 0.3, hold: 1)
#     play 220.hz.fm_feedback(0.25, gain: e).at(-6.db)              # brightness follows the envelope
#     play (220.hz.fm_feedback(0.25) * e).at(-6.db)                 # the same envelope outside: constant timbre
#     play 220.hz.pm(220.hz.fm_feedback(0.19).at(0.24)).at(-12.db)  # a feedback modulator
#     play 880.hz.fm_feedback(0.29).oversample(4).at(-12.db)        # high notes alias; oversample helps
#     play 110.hz.fm_feedback(1.3.radians).at(-12.db)               # amounts in radians
#     Tone.dx7_feedback(6)                                       # => 0.5 cycle (DX7 FB 6 at full operator level)

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script(
  feedback: [0.223, Float, '-F', 'Modulator self-feedback in cycles at full envelope (about 1.4 radians; 0 for none; hiss above 12 kHz from ~0.35, noise from ~0.64)', 0.0..1.0],
  index: [0.255, Float, '-x', 'Modulation index in cycles of the modulator into the carrier (about 1.6 radians)', 0.0..1.3],
  voices: [6, Integer, '-v', 'Number of voices', 1..32],
) { |midi, p|
  midi.synth(voices: p.voices) { |v|
    # The modulator's level envelope, applied inside the feedback loop:
    # a swell, a quick fall from the peak, and a lower sustain
    menv = v.fm_env(0.07, 0.45, 0.6, 0.25, curve: [-6, 20, 30], sensitivity: -6.db..0.db).named('Modulator envelope')
    # The mod wheel is the feedback knob over the full range, 0 to
    # Tone::FEEDBACK_MAX (1 cycle), starting at --feedback (rounded to a
    # wheel step, 1 / 127 cycle = 0.05 rad)
    fb_max = MB::Sound::Tone::FEEDBACK_MAX
    amount = v.cc(1, range: 0.0..fb_max, default: (p.feedback / fb_max * 127).round, name: 'Feedback',
      description: 'Modulator self-feedback (cycles)').named('Feedback amount')
    mod = v.hz.fm_feedback(amount, gain: menv).at(p.index).named('Modulator')

    amp = v.amp_env(0.04, 0.8, 0.8, 0.25).named('Amplitude')
    (v.hz.sine.pm(mod) * amp * 0.8).named('Voice')
  }
}
