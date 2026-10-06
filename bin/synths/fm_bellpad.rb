#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A metallic bell pad sound.
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# CC 1 (the mod wheel) deepens the phase modulation; a slow noise LFO
# wobbles it.
#
# Examples:
#     $0                                    # live MIDI
#     $0 spec/test_data/c_major.mid bellpad.flac

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script { |midi|
  s = midi.synth(voices: 4) { |v|
    noise_lfo = 1.hz.ramp.noise.at(48.db).filter(0.05.hz.highpass).filter(0.15.hz.lowpass(quality: 0.4)).softclip(0.1, 1) * -30.dB + 1

    # Velocity: pads change level less than keys, so the carriers' amp
    # envelopes span 6 dB and the modulators' 9 dB (brightness), about
    # 9 dB(A) in all from velocity 16 to 127 (it was 19, with velocity 64
    # 11.6 dB down; now 5.6).

    # The envelopes are the old `.db(20)` and `.db(30)` ones (straight
    # lines in dB) converted: rising curves of -20 or -30 dB, falls by the
    # share of that range they cover, sustain levels and velocity ranges
    # mapped the same way.  Operators are pitches transposed by ratios and
    # thousandths of an octave ("mils"; 7 mils is about 8 cents).
    #
    # B and D were written as ratios 3.5 and 6, but in the old version
    # their phase noise ran them 1.336x and 1.24x sharp (a Tone bug at
    # 96 kHz, fixed 2026-10-05), so ratios 4.676 (about a fourth above
    # 3.5) and 7.44 keep the sound the patch had.  Use 3.5 and 6 to hear
    # the ratios as written.

    b_osc = v.hz.transpose((Math.log2(3.5 * 1.336) + 0.007).oct).tone.noise(0.000007).at(1).named('B')
    b_env = v.fm_env(0.4, 3.1, 0.59, 6, curve: [-20, 4, 16], sensitivity: -9.db..0.db).named('B Envelope')
    b_out = (b_osc * b_env).named('B Out')

    ba_mod = v.cc(1, range: 1.3..2.6, name: 'B into A')
    a_osc = v.hz.transpose(0.007.oct).at(1).pm(b_out * ba_mod * noise_lfo).named('A')
    a_env = v.amp_env(0.9, 3.2, 0.698, 6.1, curve: [-30, 3, 27], sensitivity: -6.db..0.db).named('A Envelope')
    a_out = (a_osc * a_env).named('A Out')

    d_osc = v.hz.transpose((Math.log2(6 * 1.24) + 0.005).oct).tone.noise(0.000005).at(1).named('D')
    d_env = v.fm_env(0.6, 3.2, 0.64, 6.4, curve: [-20, 3.4, 16.6], sensitivity: -9.db..0.db).named('D Envelope')
    d_out = (d_osc * d_env).named('D Out')

    dc_mod = v.cc(1, range: 1.25..2.5, name: 'D into C')
    c_osc = v.hz.transpose(0.002.oct).at(1).pm(d_out * dc_mod * noise_lfo).named('C')
    c_env = v.amp_env(1.1, 3.1, 0.582, 6.8, curve: [-30, 4.5, 25.5], sensitivity: -6.db..0.db).named('C Envelope')
    c_out = (c_osc * c_env).named('C Out')

    sum = a_out + c_out

    filt_freq = (v.freq * 15).aclip(5000, 12000)
    sum.filter(:lowpass, cutoff: filt_freq) # Try to cut down on aliasing chalkboard noise
  }

  (s * 0.2)
    .softclip(0.8, 0.95)
    .oversample(2)
}
