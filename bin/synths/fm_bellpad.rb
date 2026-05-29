#!/usr/bin/env ruby
# A metallic bell pad sound.

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script { |input|
  s = MB::Sound.synth(input) { |midi|
    # TODO: remove smoothing from midi.frequency
    noise_lfo = 1.hz.ramp.noise.at(48.db).filter(0.05.hz.highpass).filter(0.15.hz.lowpass(quality: 0.4)).softclip(0.1, 1) * -30.dB + 1

    # FIXME: envelope velocity scaling is too quiet at moderate velocity

    b_ratio = 3.5.constant.named('B Ratio')
    b_osc = midi.frequency(3.5 * 2 ** (7.0 / 1000.0)).tone.noise(0.000007).at(1).named('B')
    b_env = midi.env(0.4, 3.1, 0.8, 6).named('B Envelope').db(20)
    b_out = (b_osc * b_env).named('B Out')

    # 7 mils up
    ba_mod = midi.cc(1, range: 1.3..2.6).named('B into A')
    a_osc = midi.frequency(2 ** (7.0 / 1000.0)).tone.at(1).pm(b_out * ba_mod * noise_lfo).named('A')
    a_env = midi.env(0.9, 3.2, 0.9, 6.1).named('A Envelope').db(30)
    a_out = (a_osc * a_env).named('A Out')

    d_osc = midi.frequency(6 * 2 ** (5.0 / 1000.0)).tone.noise(0.000005).at(1).named('D')
    d_env = midi.env(0.6, 3.2, 0.83, 6.4).named('D Envelope').db(20)
    d_out = (d_osc * d_env).named('D Out')

    # 2 mils up
    dc_mod = midi.cc(1, range: 1.25..2.5).named('D into C')
    c_osc = midi.frequency(2 ** (2.0 / 1000.0)).tone.at(1).pm(d_out * dc_mod * noise_lfo).named('C')
    c_env = midi.env(1.1, 3.1, 0.85, 6.8).named('C Envelope').db(30)
    c_out = (c_osc * c_env).named('C Out')

    sum = a_out + c_out

    filt_freq = midi.frequency(15).clip(5000, 12000)
    sum.filter(:lowpass, cutoff: filt_freq) # Try to cut down on aliasing chalkboard noise
  }

  (s * 0.5)
    .softclip(0.8, 0.95)
    .oversample(2)
}
