#!/usr/bin/env ruby
# Trying to synthesize a kick inspired by a YouTube tutorial:
# https://www.youtube.com/watch?v=ndG-6-vONNc

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script { |input|
  s = MB::Sound.synth(input) { |midi|
    pitch_decay = 0.13
    decay_time = 0.18

    # FIXME: only sounds right at velocity 127
    # TODO: the node graph and GraphVoice really need some concept of i/o ports
    # and configurable parameters.
    #
    # Also the envelope generator needs to be smarter about dynamic parameter
    # changes.

    attack_hz = 100.constant.named('Attack Hz')
    attack_env = midi.env(0.0005, pitch_decay, 0, pitch_decay).db(60) # fast click at start
    pitch_env = midi.env(0.0005, decay_time, 0, decay_time) # semitone fall over full decay

    noise_cutoff = 1500.constant.named('Noise cutoff')
    noise_source = 1000.hz.gauss.noise.at(0.4).filter(:lowpass, cutoff: noise_cutoff) * midi.env(0.0001, 0.04, 0, 0.04).db(60)

    falling_sine = (attack_env + midi.frequency * (0.06 * pitch_env + 0.97)).tone.at(1).pm(noise_source)
    falling_sine_amp = falling_sine * midi.env(0.0001, decay_time, 0, decay_time).db(60)

    sub = falling_sine_amp.peq({
      30.hz => 9.db,
      95.hz => [6.db, 0.5],
      600.hz => [-20.db, 1.5],
      9000.hz => [25.db, 1.5],
    })

    ################################################

    boom_sine_decay = 0.4
    boom_noise_decay = 0.7

    boom_noise_cutoff = 10000.constant.named('Noise cutoff')
    boom_noise_gain = 2500.constant.named('Noise gain')
    boom_noise = 10000.hz.ramp.noise
      .at(1)
      .filter(:lowpass, cutoff: boom_noise_cutoff)

    boom_noise *= midi.env(0.0001, boom_noise_decay, 0.0, boom_noise_decay).db(40)

    boom_sine = 143.hz.at(1).fm(boom_noise * boom_noise_gain)
    boom_sine *= midi.env(0.01, boom_sine_decay, 0.0, boom_sine_decay).db(50) * midi.env(0.01, boom_sine_decay, 0.0, boom_sine_decay)

    boom = boom_sine.peq({
      20.hz => [-20.db, 1],
      60.hz => [11.db, 0.6],
      100.hz => [6.db, 0.6],
      133.hz => [-9.db, 0.3],
      180.hz => [3.db, 2],
      350.hz => 4.db,
      950.hz => [-12.db, 3],
      6000.hz => [-4.db, 3],
      12000.hz => [-1.db, 1],
      45.hz => [3.db, 0.1],
      95.hz => [2.db, 0.1],
    })

    ################################################

    sub + boom * 0.05
  }

  (s * -5.db)
    .softclip(0.8, 0.95)
}
