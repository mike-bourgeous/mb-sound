#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Trying to synthesize a kick inspired by a YouTube tutorial:
# https://www.youtube.com/watch?v=ndG-6-vONNc
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Examples:
#     $0                                    # live MIDI
#     $0 spec/test_data/c_major.mid kick.flac

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script { |midi|
  s = midi.synth(voices: 4) { |v|
    pitch_decay = 0.13
    decay_time = 0.18

    # Velocity: the carrier levels have 12 dB ranges (the boom another 6
    # dB from its linear envelope), as kicks usually have 10-20 dB of
    # level change (they were 30 and 25.5 dB), while the clicks (the
    # 100 Hz pitch click, the noise click, and the boom's noise FM) keep
    # their wide ranges (30, 30, and 21 dB), so soft hits are duller as
    # well as quieter.
    #
    # The envelopes are the old `.db(N)` ones (straight lines in dB over N
    # dB) converted to curves of -N rising and N falling, with the old
    # velocity ranges in dB; the pitch envelope and the second boom envelope
    # were linear.  Every oscillator restarts at each note.

    attack_hz = 100.constant.named('Attack Hz')
    # fast click at start: up to 100 Hz above the note, falling 60 dB
    attack_env = attack_hz * v.env(0.0005, pitch_decay, 0, pitch_decay, curve: [-60, 60, 60], sensitivity: -30.db..0.db, velocity_scale: :db)
    pitch_env = v.env(0.0005, decay_time, 0, decay_time, curve: :linear) # semitone fall over full decay

    noise_cutoff = 1500.constant.named('Noise cutoff')
    noise_source = 1000.hz.gauss.noise.at(0.4).filter(:lowpass, cutoff: noise_cutoff) *
      v.fm_env(0.0001, 0.04, 0, 0.04, curve: [-60, 60, 60], sensitivity: -30.db..0.db)

    falling_sine = (attack_env + v.freq * (0.06 * pitch_env + 0.97)).tone.at(1).pm(noise_source).reset(v.trigger)
    falling_sine_amp = falling_sine * v.amp_env(0.0001, decay_time, 0, decay_time, curve: [-60, 60, 60], sensitivity: -12.db..0.db)

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
    boom_noise = 10000.hz.ramp.noise.at(0.1)
      .at(1)
      .filter(:lowpass, cutoff: boom_noise_cutoff)

    boom_noise *= v.fm_env(0.0001, boom_noise_decay, 0.0, boom_noise_decay, curve: [-40, 40, 40], sensitivity: -20.8.db..0.db)

    boom_sine = 143.hz.at(1).fm(boom_noise * boom_noise_gain).reset(v.trigger)
    boom_sine *= v.amp_env(0.01, boom_sine_decay, 0.0, boom_sine_decay, curve: [-50, 50, 50], sensitivity: -12.db..0.db) *
      v.env(0.01, boom_sine_decay, 0.0, boom_sine_decay, curve: :linear)

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
