#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A stereo synthesizer example: phase-modulated voices with a drifting
# filter, widened by a different modulated delay on each side.  Plays live
# MIDI or a MIDI file; run with --help for all options.
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Examples:
#     $0                                    # live MIDI
#     $0 spec/test_data/c_major.mid stereo.flac

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script { |midi|
  s = midi.synth(voices: 4) { |v|
    # A pitch at +ratio+ times the note (oscillators made from it restart
    # at each note, from their with_phase phase)
    op = ->(ratio) { v.hz.transpose(Math.log2(ratio).oct) }

    q = (op.(2.001).at(1).with_phase(1.0 / 6) + 0.1.hz.lfo.at(1) * op.(1.001).at(Math::PI)).radians # PM in radians
    a = (
      (
        (op.(6.001).at(0.1).pm(q) + op.(8.001).at(0.1).pm(q)) + op.(0.501).ramp.at(0.3).filter(:lowpass, cutoff: 0.23.hz.lfo.at(130..2500))
      ) * v.amp_env(0.002, 0.05, -10.db, 0.1, sensitivity: -6.db..0.db)
    )

    a.softclip
  }

  b = s.oversample(2)

  left = b.delay(0.4.hz.lfo.at(0..0.01), feedback: -0.5, dry: 1, smoothing: false).softclip
  right = b.delay(0.3.hz.lfo.at(0..0.01), feedback: -0.5, dry: 1, smoothing: false).softclip

  [left, right]
}
