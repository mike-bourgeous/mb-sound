#!/usr/bin/env ruby
# A tubular bell sound based in part on the T.BL-EXPA preset included with
# Dexed.

require 'bundler/setup'
require 'mb-sound'
require 'mb-util'

MB::Sound.synth_script { |input|
  s = MB::Sound.synth(input) { |midi|
    ba_dc_mod = midi.velocity(range: 1.6..3.2).named('B into A, D into C')
    ac_env = midi.env(0, 6, 0, 5).named('A and C Envelope').db(30)
    bd_env = midi.env(0, 5, 0, 4).named('B and D Envelope').db(30)
    bd_ratio = midi.cc(1, range: 3.5..4.0).named('B and D Ratio')

    base = midi.frequency

    # TODO: make it easier to work with semitones; could just add 42.084
    # instead of multiplying and exponentiating

    # 7 mils detuned up, 3.5 ratio
    b_osc = (base * bd_ratio * (2 ** (7.0 / 1000.0))).tone.complex_sine.at(1).named('B')
    b_out = (b_osc * bd_env).named('B Out')

    # 7 mils up
    a_osc = (base * (2 ** (7.0 / 1000.0))).tone.complex_sine.at(1).pm(b_out * ba_dc_mod).named('A')
    a_out = (a_osc * ac_env).named('A Out')

    # 5 mils up, 3.5 ratio
    d_osc = (base * bd_ratio * (2 ** (5.0 / 1000.0))).tone.complex_sine.at(1).named('D')
    d_out = (d_osc * bd_env).named('D Out')

    # 2 mils up
    c_osc = (base * (2 ** (2.0 / 1000.0))).tone.complex_sine.at(1).pm(d_out * ba_dc_mod).named('C')
    c_out = (c_osc * ac_env).named('C Out')

    sum = (a_out + c_out).real

    # TODO: need some kind of compressor or limiter
    (sum * 0.1).softclip
  }

  s.filter(15000.hz.lowpass) # Try to cut down on aliasing chalkboard noise
    .softclip(0.8, 0.95)
    .oversample(2)
}
