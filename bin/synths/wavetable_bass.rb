#!/usr/bin/env ruby
# Wavetable- and waveshaping-based monophonic bass synth.

require 'bundler/setup'
require 'mb-util'
require 'mb-sound'

DETUNE_CENTS = 5
DETUNE_SEMIS = 0.01 * DETUNE_CENTS
DETUNE_RANGE = (2 ** -DETUNE_SEMIS)..(2 ** DETUNE_SEMIS)
PORTAMENTO_TIME = 0.1 # TODO: control with midi CC for portamento

MB::U.headline('Loading wavetables...')
synthwave = MB::Sound::Wavetable.sort(
  MB::Sound::Wavetable.normalize(
    MB::Sound::Wavetable.load_wavetable('sounds/drums.flac', slices: 10)
  )
)
shaperwave = MB::Sound::Wavetable.sort(
  MB::Sound::Wavetable.normalize(
    MB::Sound::Wavetable.load_wavetable('sounds/synth0.flac', slices: 10)
  )
)

MB::Sound.synth_script { |input|
  MB::U.headline('Building synth...')

  s1 = MB::Sound.synth(input, osc_count: 1) { |midi|
    cc1 = midi.cc(1).filter(:lowpass, cutoff: 10, quality: 0.5)
    cc2 = midi.cc(2, range: 1..10).filter(:lowpass, cutoff: 10, quality: 0.5)
    cc4 = midi.cc(4).filter(:lowpass, cutoff: 10, quality: 0.5)

    a = midi
      .frequency(rand(DETUNE_RANGE))
      .filter(:lowpass, cutoff: 1.0 / PORTAMENTO_TIME, quality: 0.5).named('A Portamento')
      .tone.ramp.at(2).named('A Phase')
      .wavetable(wavetable: synthwave, number: cc1).named('A Wavetable')
      .filter(:lowpass, cutoff: 5000, quality: 0.4).named('A Filter')

    b = midi
      .frequency(rand(DETUNE_RANGE))
      .filter(:lowpass, cutoff: 1.0 / PORTAMENTO_TIME, quality: 0.5).named('B Portamento')
      .tone.triangle.at(0.5).named('B')

    env = midi.env(0.003, 0.05, 0.5, 0.3, velocity: -20.db..0.db)

    sum = (a + b) * cc2 * env

    (sum.softclip * 2)
      .wavetable(wavetable: shaperwave, number: cc4)
  }.filter(:highpass, cutoff: 10, quality: 0.7)

  s2 = MB::Sound.synth(input, osc_count: 1) { |midi|
    cc1 = midi.cc(1).filter(:lowpass, cutoff: 10, quality: 0.5)
    cc2 = midi.cc(2, range: 1..10).filter(:lowpass, cutoff: 10, quality: 0.5)
    cc4 = midi.cc(4).filter(:lowpass, cutoff: 10, quality: 0.5)

    a = midi
      .frequency(rand(DETUNE_RANGE))
      .filter(:lowpass, cutoff: 1.0 / PORTAMENTO_TIME, quality: 0.5).named('A Portamento')
      .tone.ramp.at(2).named('A Phase')
      .wavetable(wavetable: synthwave, number: cc1).named('A Wavetable')
      .filter(:lowpass, cutoff: 5000, quality: 0.4).named('A Filter')

    b = midi
      .frequency(rand(DETUNE_RANGE))
      .filter(:lowpass, cutoff: 1.0 / PORTAMENTO_TIME, quality: 0.5).named('B Portamento')
      .tone.triangle.at(0.5).named('B')

    env = midi.env(0.003, 0.05, 0.5, 0.3, velocity: -20.db..0.db)

    sum = (a + b) * cc2 * env

    (sum.softclip * 2)
      .wavetable(wavetable: shaperwave, number: cc4)
  }.filter(:highpass, cutoff: 10, quality: 0.7)

  l = s1.filter(:lowpass, cutoff: 15000, quality: 0.25).softclip
  r = s2.filter(:lowpass, cutoff: 15000, quality: 0.25).softclip

  MB::U.headline('Begin play!')

  [l, r]
}
