#!/usr/bin/env ruby

require 'bundler/setup'

require 'benchmark'

require 'mb-sound'

a = 100.hz.complex_square.forever.at(-6.db).filter(1500.hz.lowpass(quality: 0.5))
b = 150.hz.ramp.forever.at(-7.db).filter(2600.hz.lowpass(quality: 0.5))
c = 266.66667.hz.triangle.forever.at(-8.db).softclip(0.05, 0.5).filter(900.hz.lowpass1p) *
  0.1.hz.lfo.at(0..1) +
  250.hz.complex_triangle.forever.at(-6.db).softclip(0.05, 0.5).filter(900.hz.lowpass1p) *
  0.1.hz.lfo.at(0..1).with_phase(Math::PI)

denv = MB::Sound::ADSREnvelope.new(attack_time: 4, decay_time: 60, sustain_level: 1, release_time: 60, rate: 48000)
denv.trigger(1, auto_release: true)

d = (
  50.hz.triangle.at(-3.db).forever.filter(150.hz.lowpass1p) *
  4.hz.ramp.lfo.at(0..-30).db.filter(50.hz.lowpass)
).softclip(0.005, 0.25) * 10.db * denv

#abcenv = MB::Sound::ADSREnvelope.new(attack_time: 30, decay_time: 60, sustain_level: 0.125, release_time: 30)

graph = ((a + b + c) * 1.hz.ramp.lfo.at(2..0.1).filter(30.hz.lowpass) * 0.0001.hz.triangle.lfo.at(0..1).with_phase(-Math::PI/2) + d).softclip(0.25, 0.99)

MB::Sound.play graph.real.for(180)
