#!/usr/bin/env ruby
# Just a 23-ish second bass sound of increasing distortion.  The little drum
# sound at the end comes from filter pinging when the triangle wave gets cut
# off in the middle of a cycle.

require 'bundler/setup'
require 'mb-sound'

MB::Sound.play(
  (
    (
      25.hz.triangle.at(0.25).forever +
      50.hz.square.at(0.5).forever +
      100.hz.triangle.forever.at(1)
        .filter(:lowpass, cutoff: 0.5.hz.lfo.forever.at(50..1500), quality: 3)
        .quantize(800.hz.forever.fm(0.2.hz.forever.lfo.at(700)).at(0.5) + 0.5).forever
    ).forever.filter(:lowpass, cutoff: 0.3.hz.lfo.forever.at(80..6000), quality: 3) * (
      25.hz.square.at(1..0.5).filter(6000.hz.lowpass) *
      4.hz.drumramp.at(1..0.2).filter(5000.hz.lowpass) *
      MB::Sound.adsr(10, 30, 1, 20).db(-30)
    )
  ).multitap(0, 0.125, 0.125 / 8, 5.0 / 16)
    .each_slice(2).map(&:sum)
    .map(&:softclip)
    .map.with_index { |v, idx|
      v.quantize(
        0.05.hz.drumramp.at(0..1).for(20) ** 4
      ).and_then(
        50.hz.triangle.at(2.5).for(3)
        .and_then(0.constant.for(0.2)).softclip.filter(:lowpass, cutoff: 390 + idx * 20, quality: 25)
      )
    }
)
