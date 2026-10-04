#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Just a 23-ish second bass sound of increasing distortion.  The little drum
# sound at the end comes from filter pinging when the triangle wave gets cut
# off in the middle of a cycle.
#
# Usage:
#     bin/songs/node_graph_grit.rb              # plays live
#     bin/songs/node_graph_grit.rb grit.flac    # renders to a file
#     bin/songs/node_graph_grit.rb --help       # all options

require 'bundler/setup'
require 'mb-sound'

MB::Sound.song_script {
  grit = (
    (
      (
        25.hz.triangle.at(0.25) +
        50.hz.square.at(0.5) +
        100.hz.triangle.at(1)
          .filter(:lowpass, cutoff: 0.5.hz.lfo.at(50..1500), quality: 3)
          .quantize(800.hz.fm(0.2.hz.lfo.at(700)).at(0.5) + 0.5)
      ).filter(:lowpass, cutoff: 0.3.hz.lfo.at(80..6000), quality: 3) * (
        25.hz.square.at(1..0.5).filter(6000.hz.lowpass) *
        4.hz.drumramp.at(1..0.2).filter(5000.hz.lowpass) *
        MB::Sound.adsr(10, 30, 1, 20).db(-30)
      )
    ).multitap(0, 0.125, 0.125 / 8, 5.0 / 16)
      .each_slice(2).map(&:sum)
      .map(&:softclip)
      .map.with_index { |v, idx|
        v.quantize(
          0.05.hz.drumramp.at(0..1).until(20) ** 4
        ).and_then(
          50.hz.triangle.at(2.5).until(3)
          .and_then(MB::Sound.silence(0.2)).softclip.filter(:lowpass, cutoff: 390 + idx * 20, quality: 25)
        )
      }
  )

  MB::Sound.bg(:grit, grit, fade: 0)
}
