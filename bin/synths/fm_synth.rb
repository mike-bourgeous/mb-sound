#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A plain FM synthesizer: each voice is a parabola wave frequency-modulated
# by a sine at a multiple of the note.  The modulation wheel controls the
# intensity of modulation.
# (C)2021 Mike Bourgeous
#
# The 2021 version chained notes instead (each later note modulated the one
# before it, and only the first held note was heard); it is in the
# repository's history.
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Examples:
#     $0                                    # live MIDI
#     $0 spec/test_data/c_major.mid         # a MIDI file
#     $0 --ratio 1.5 spec/test_data/c_major.mid fm.flac

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script(
  ratio: [2.0, Float, 'Modulator frequency as a multiple of the note frequency', 0.0..16.0],
) { |midi, p|
  midi.synth(voices: 8) { |v|
    # Peak frequency deviation in Hz: 0 to 10 kHz, starting near 1 kHz
    index = v.cc(1, range: 0.0..10000.0, default: 13, name: 'FM index')
    modulator = v.hz.transpose((Math.log2(p.ratio)).oct).at(1)

    # Parabola is a little more interesting than sine without being too chaotic
    v.hz.parabola.at(-10.db).fm(modulator * index) * v.amp_env(0.002, 0.05, 1, 0.05, sensitivity: -6.db..0.db)
  }
}
