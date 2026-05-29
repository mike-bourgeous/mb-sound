#!/usr/bin/env ruby
# Something between a bell and a sitar??

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script { |input|
  s = MB::Sound.synth(input) { |midi|
    # FIXME: velocity curve is too low at mid-low velocities, too high above

    r_ratio = (8 * 3.5).constant.named('R Ratio')
    r_osc = (midi.frequency * r_ratio).tone.complex_sine.at(1).named('R')
    r_env = midi.env(0.05, 4, 0.1, 4).named('R Envelope').db(20)
    r_out = (r_osc * r_env).named('R Out')
    rq_const = 1.4.constant.named('R into Q')

    q_ratio = 8.constant.named('Q Ratio')
    q_osc = (midi.frequency * q_ratio).tone.complex_sine.at(1).pm(r_out * rq_const).named('Q')
    q_env = midi.env(2, 3, 0.7, 3).named('Q Envelope').db(30) * 0.1632.hz.sine.at(0.5..1.5).named('Q LFO')
    q_out = (q_osc * q_env).named('Q Out')
    qb_mod = midi.cc(1, range: 0.15..0.5).named('Q into B')
    qa_mod = midi.cc(1, range: 0.25..4.0).named('Q into A')

    # 7 mils detuned up, 3.5 ratio
    b_ratio = 3.5.constant.named('B Ratio')
    b_osc = (midi.frequency * b_ratio * (2 ** (2.0 / 1000.0))).tone.complex_sine.at(1).pm(q_out * qb_mod).named('B')
    b_env = midi.env(0, 5, 0.2, 4).named('B Envelope').db(30) * 0.223.hz.sine.at(0.8..1.1).named('B LFO')
    b_out = (b_osc * b_env).named('B Out')

    # 7 mils up
    ba_vel = midi.velocity(range: 0.8..2.4).named('B into A')
    a_osc = (midi.frequency * (2 ** (2.0 / 1000.0))).tone.complex_sine.at(1).pm(b_out * ba_vel + q_out * qa_mod).named('A')
    a_env = midi.env(0, 6, 0.5, 5).named('A Envelope').db(30) * 0.111.hz.sine.at(0.9..1.0).named('A LFO')
    a_out = (a_osc * a_env).named('A Out')

    # 5 mils up, 3.5 ratio
    d_ratio = 3.5.constant.named('D Ratio')
    d_osc = (midi.frequency * d_ratio * (2 ** (3.0 / 1000.0))).tone.complex_sine.at(1).named('D')
    d_env = midi.env(0, 5, 0.13, 4).named('D Envelope').db(30) * 0.157.hz.sine.at(0.3..1.1).named('D LFO')
    d_out = (d_osc * d_env).named('D Out')

    # 2 mils up
    dc_vel = midi.velocity(range: 0.8..2.4).named('D into C')
    c_osc = (midi.frequency * (2 ** (1.0 / 1000.0))).tone.complex_sine.at(1).pm(d_out * dc_vel).named('C')
    c_env = midi.env(0, 6, 0.55, 5).named('C Envelope').db(30) * 0.317.hz.sine.at(0.9..1.0).named('C LFO')
    c_out = (c_osc * c_env).named('C Out')

    a_out + c_out + (q_out * 0.05)
  }

  (s * 0.5)
    .filter(10000.hz.lowpass)
    .softclip(0.8, 0.95)
}
