#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A one-voice FM drum/bass synthesizer: a chain of FM operators with
# fast-decaying modulation envelopes.  Plays live MIDI or a MIDI file; run
# with --help for all options.
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Examples:
#     $0                                    # live MIDI
#     $0 spec/test_data/c_major.mid drumbass.flac

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script { |midi|
  # One voice (mono): each note takes over from the last
  s = midi.synth(voices: 1) { |v|
    # The old drumbass incremented each voice by 16 semitones, but voice 0
    # was normal and there was only one voice.  C is modulated by a fixed
    # C3, which restarts with every note like the other oscillators.
    #
    # The envelopes are the old `.db(N)` ones (straight lines in dB over N
    # dB) converted: rising curves of -N dB, falls by the share of N dB
    # they cover, sustain levels and velocity ranges mapped the same way.

    cenv = v.fm_env(0, 0.005, 0.151, 0.005, curve: [-30, 15, 15]).named('C Envelope')
    cenv2 = v.fm_env(0, 0.01, 0.031, 0.01, curve: [-60, 30, 30], sensitivity: -30.3.db..0.db).named('C Mod Envelope')
    c = cenv * v.hz.at(1).fm(cenv2 * MB::Sound::C3.at(1).reset(v.trigger)).named('C')

    denv = v.fm_env(0, 0.005, 0, 0.005, curve: [-50, 50, 50], sensitivity: -25.5.db..0.db).named('D Envelope')
    d = denv * (v.freq * 0.9996 - 0.22).tone.at(1).reset(v.trigger).named('D')

    eenv = v.fm_env(0, 2, 0, 2, curve: [-80, 80, 80], sensitivity: -40.db..0.db).named('E Envelope')
    e = eenv * v.hz.at(1).fm(c * 4810 + d * 500).named('E')

    fenv = v.amp_env(0.001, 2, 0, 2, curve: [-80, 80, 80], sensitivity: -40.db..0.db).named('F Envelope')
    fenv * v.hz.at(1).fm(e * 250).named('F')
  }

  s.softclip(0.8, 0.95)
}
