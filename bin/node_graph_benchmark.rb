#!/usr/bin/env ruby
# This is a simple algorithmically defined song that exercises several common
# parts of the GraphNode and Filter code, including processing with complex
# numbers.
#
# Use --bench to run the benchmark, or no arguments to play the song.

require 'bundler/setup'

require 'benchmark'

require 'mb-sound'

abenv = MB::Sound::ADSREnvelope.new(attack_time: 60, decay_time: 30, sustain_level: 0.125, release_time: 90, rate: 48000)
abenv.trigger(1, auto_release: true)

a = 100.hz.complex_square.forever.at(-13.db).filter(1500.hz.lowpass(quality: 0.5))
b = 150.hz.ramp.forever.at(-15.db).filter(2600.hz.lowpass(quality: 0.5))

ab = (a + b).softclip(0.05, 0.2) * 1.hz.drumramp.lfo.at(2..0.1).filter(30.hz.lowpass) * abenv

cenv = MB::Sound::ADSREnvelope.new(attack_time: 90, decay_time: 60, sustain_level: 1, release_time: 30, rate: 48000)
cenv.trigger(1, auto_release: true)

c = (
  266.66667.hz.triangle.forever.at(-4.db).softclip(0.05, 0.5).filter(1900.hz.lowpass1p) * 0.1.hz.lfo.at(0..1) +
  250.hz.complex_triangle.forever.at(-3.db).softclip(0.05, 0.5).filter(1900.hz.lowpass1p) * 0.1.hz.lfo.at(0..1).with_phase(Math::PI)
).softclip(0.05, 0.25) * 10.db * cenv

denv = MB::Sound::ADSREnvelope.new(attack_time: 4, decay_time: 156, sustain_level: 1, release_time: 20, rate: 48000)
denv.trigger(1, auto_release: true)

d = (
  50.hz.triangle.at(-3.db).forever.filter(150.hz.lowpass1p) *
  4.hz.drumramp.lfo.at(0..-30).db.filter(50.hz.lowpass)
).softclip(0.005, 0.25) * 10.db * denv

drumenv = MB::Sound::ADSREnvelope.new(attack_time: 10, decay_time: 160, sustain_level: 1, release_time: 10, rate: 48000)
drumenv.trigger(1, auto_release: true)

hat = 10000.hz.noise.filter(9000.hz.highpass).filter(15000.hz.lowpass) * 8.hz.drumramp.lfo.at(-4..-25).filter(100.hz.lowpass).db
kick = 50.hz.at(-3.db).fm(2.hz.drumramp.at(90.to_db..-60).db.filter(100.hz.lowpass)) * 2.hz.drumramp.at(0..-30).db.filter(100.hz.lowpass)

drums = (hat + kick) * drumenv

graph = ((drums + ab + c + d) * -6.db).softclip(0.25, 0.99)

if ARGV.include?('--bench')
  raise 'TODO'
else
  m, s = graph.for(180).tee

  m1, m2 = m.real.tee
  s1, s2 = s.imag.tee

  l = m1 + -6.db * s1
  r = m2 - -6.db * s2

  final_l = l.tee.yield_self { |(x, y)|
    flanger = -4.db * x - -5.db * y.delay(seconds: 0.1.hz.triangle.lfo.at(0.001..0.008))
    flanger.softclip(0.5, 0.99).with_buffer(800)
  }
  final_r = r.tee.yield_self { |(x, y)|
    flanger = -4.db * x - -5.db * y.delay(seconds: 0.1.hz.triangle.lfo.with_phase(Math::PI).at(0.001..0.008))
    flanger.softclip(0.5, 0.99).with_buffer(800)
  }

  MB::Sound.play [final_l, final_r]
end
