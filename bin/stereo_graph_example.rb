#!/usr/bin/env ruby

require 'bundler/setup'
require 'mb-sound'

q = 120.1.hz.at(1).with_phase(Math::PI/3) + 0.1.hz.lfo.at(1) * 60.hz.lfo.at(Math::PI)
a = (
  (360.3.hz.pm(q) + 481.4.hz.pm(q)).oversample(3).forever + 30.hz.ramp.at(0.3).filter(:lowpass, cutoff: 0.23.hz.lfo.at(130..2500))
).softclip.oversample(2)

left = a.delay(seconds: 0.4.hz.lfo.at(0..0.01), feedback: -0.5, dry: 1, smoothing: false).softclip
right = a.delay(seconds: 0.3.hz.lfo.at(0..0.01), feedback: -0.5, dry: 1, smoothing: false).softclip

MB::Sound.play([left, right])
