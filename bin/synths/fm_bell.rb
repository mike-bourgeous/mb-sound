#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A tubular bell sound based in part on the T.BL-EXPA preset included with
# Dexed.
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Velocity sets the modulation depth; CC 1 (the mod wheel) moves the B and D
# operators' ratio from 3.5 to 4.
#
# Examples:
#     $0                                    # live MIDI
#     $0 spec/test_data/c_major.mid bell.flac

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script { |midi|
  s = midi.synth(voices: 4) { |v|
    ba_dc_mod = (v.velocity * 1.6 + 1.6).named('B into A, D into C')

    # DX-style envelopes (straight lines in dB, as the old `.db(30)`): the
    # carriers' amplitude and the modulators' index
    ac_env = v.amp_env(0.001, 6, 0, 5, curve: :dx).named('A and C Envelope')
    bd_env = v.fm_env(0, 5, 0, 4).named('B and D Envelope')
    bd_ratio = v.cc(1, range: 3.5..4.0, name: 'B and D Ratio')

    # Fixed ratios as pitches: transposed up by thousandths of an octave
    # ("mils"; 7 mils is about 8 cents).  The B and D ratio follows the mod
    # wheel, so those oscillators are built on the frequency node and reset
    # at each note themselves.
    b_osc = (v.freq * bd_ratio * (2 ** (7.0 / 1000.0))).tone.complex_sine.at(1).reset(v.trigger).named('B')
    b_out = (b_osc * bd_env).named('B Out')

    a_osc = v.hz.transpose(0.007.oct).complex_sine.at(1).pm(b_out * ba_dc_mod).named('A')
    a_out = (a_osc * ac_env).named('A Out')

    d_osc = (v.freq * bd_ratio * (2 ** (5.0 / 1000.0))).tone.complex_sine.at(1).reset(v.trigger).named('D')
    d_out = (d_osc * bd_env).named('D Out')

    c_osc = v.hz.transpose(0.002.oct).complex_sine.at(1).pm(d_out * ba_dc_mod).named('C')
    c_out = (c_osc * ac_env).named('C Out')

    sum = (a_out + c_out).real

    # TODO: need some kind of compressor or limiter
    (sum * 0.1).softclip
  }

  s.filter(15000.hz.lowpass) # Try to cut down on aliasing chalkboard noise
    .softclip(0.8, 0.95)
    .oversample(2)
}
