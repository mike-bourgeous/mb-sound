#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Something between a bell and a sitar??
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Velocity and CC 1 (the mod wheel) set modulation depths; slow LFOs
# (restarted with each note) move the operator levels.
#
# Examples:
#     $0                                    # live MIDI
#     $0 spec/test_data/c_major.mid sitar_bell.flac

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script { |midi|
  s = midi.synth(voices: 4) { |v|
    # An operator pitch: +ratio+ times the note, detuned up by +mils+
    # thousandths of an octave
    op = ->(ratio, mils = 0) { v.hz.transpose((Math.log2(ratio) + mils / 1000.0).oct) }

    # A level LFO restarted with each note
    lfo = ->(hz, range) { hz.hz.sine.at(range).reset(v.trigger) }

    # The envelopes are the old `.db(20)` and `.db(30)` ones (straight
    # lines in dB) converted: rising curves of -20 or -30 dB, falls by the
    # share of that range they cover, sustain levels mapped the same way.
    # Modulators get fm_env, the A and C carriers amp_env.

    r_osc = op.(8 * 3.5).complex_sine.at(1).named('R')
    r_env = v.fm_env(0.05, 4, 0.029, 4, curve: [-20, 18, 2], sensitivity: -12.4.db..0.db).named('R Envelope')
    r_out = (r_osc * r_env).named('R Out')
    # (modulation indices in cycles; retuned 2026-10-10 from radians, within 0.6%)
    rq_const = 0.223.constant.named('R into Q')

    q_osc = op.(8).complex_sine.at(1).pm(r_out * rq_const).named('Q')
    q_env = v.fm_env(2, 3, 0.334, 3, curve: [-30, 9, 21]).named('Q Envelope') * lfo.(0.1632, 0.5..1.5).named('Q LFO')
    q_out = (q_osc * q_env).named('Q Out')
    qb_mod = v.cc(1, range: 0.024..0.08, name: 'Q into B')
    qa_mod = v.cc(1, range: 0.04..0.64, name: 'Q into A')

    b_osc = op.(3.5, 2).complex_sine.at(1).pm(q_out * qb_mod).named('B')
    b_env = v.fm_env(0, 5, 0.033, 4, curve: [-30, 24, 6]).named('B Envelope') * lfo.(0.223, 0.8..1.1).named('B LFO')
    b_out = (b_osc * b_env).named('B Out')

    ba_vel = (v.velocity * 0.255 + 0.127).named('B into A')
    a_osc = op.(1, 2).complex_sine.at(1).pm(b_out * ba_vel + q_out * qa_mod).named('A')
    a_env = v.amp_env(0.001, 6, 0.151, 5, curve: [-30, 15, 15]).named('A Envelope') * lfo.(0.111, 0.9..1.0).named('A LFO')
    a_out = (a_osc * a_env).named('A Out')

    d_osc = op.(3.5, 3).complex_sine.at(1).named('D')
    d_env = v.fm_env(0, 5, 0.019, 4, curve: [-30, 26, 4]).named('D Envelope') * lfo.(0.157, 0.3..1.1).named('D LFO')
    d_out = (d_osc * d_env).named('D Out')

    dc_vel = (v.velocity * 0.255 + 0.127).named('D into C')
    c_osc = op.(1, 1).complex_sine.at(1).pm(d_out * dc_vel).named('C')
    c_env = v.amp_env(0.001, 6, 0.186, 5, curve: [-30, 13.5, 16.5]).named('C Envelope') * lfo.(0.317, 0.9..1.0).named('C LFO')
    c_out = (c_osc * c_env).named('C Out')

    a_out + c_out + (q_out * 0.05)
  }

  (s * 0.25)
    .filter(10000.hz.lowpass)
    .softclip(0.8, 0.95)
}
