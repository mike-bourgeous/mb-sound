#!/usr/bin/env ruby

require 'bundler/setup'
require 'mb-sound'

d = MB::Sound.read('../mb-sound/sounds/drums.flac').sum
d = d[0...MB::M.round_to(d.length - 16000, 16000)]
d = d.reshape(nil, 8000)
d = Array.new(d.shape[0]) { |idx| d[idx, nil] }
drums = MB::Sound::GraphNode::DataShuffler.new(d).softclip(0.1, 0.6) * 0.5.hz.square.at(0..1)
# TODO: would be nice to have control over pulse width for square waves and/or a numeric sequence generator

# TODO: a way to play a sequence of notes without having to sample them first; kind of need a node graph for MIDI?
chords = Array.new(4) { |idx|
  nd = [MB::Sound::As2, MB::Sound::Cs3, MB::Sound::Ds3, MB::Sound::Fs3, MB::Sound::Gs3].map { |n|
    n = MB::Sound::Note.new((2 - idx) * 12 + n.number).at(1).ramp.forever
    n2 = MB::Sound::Note.new(n.number).triangle.at(1).forever
    if idx > 1
      env = MB::Sound.adsr(0.01, 0.5, 0.5, 2 + idx, auto_release: 2 + (6 - idx * 2))
    else
      env = MB::Sound.adsr(2, 2, 0.2, 2 + idx, auto_release: 2 + idx)
    end
    n = n + n2 if idx == 3
    n = (n * env).filter(:lowpass, cutoff: 300 + 1500 * env, quality: 2 * (idx + 1))
    n.multi_sample(60 * (4 + 4 * idx), 800)
  }
  nds = MB::Sound::GraphNode::DataShuffler.new(nd)
  if idx == 3
    notes = nds * 12.db
  else
    notes = nds * (0.1 / (idx + 1)).hz.lfo.at(-10.db..0.db) * (2 * idx).db
  end
  (notes * (-10 + 3 * idx).db).softclip
}.reduce(&:+)

delay_lfo = 0.0897.hz.sine.at(0..250)
filter_lfo = (1.0 / 12.0).hz.sine.at(3500..7500).forever

flange1 = chords + chords.delay(samples: delay_lfo).softclip(0.1) + chords.delay(seconds: 0.5).delay(seconds: 1.01, feedback: 0.7) + chords.delay(seconds: 0.51)
flange2 = chords + chords.delay(samples: (250 - delay_lfo)).softclip(0.1) + chords.delay(seconds: 0.99, feedback: 0.6)
echo1 = drums + drums.delay(seconds: 1.0 / 32.0, feedback: 0.5) + drums.delay(seconds: 3.0 / 6.0, feedback: 0.5)
echo2 = drums + drums.delay(seconds: 1.0 / 64.0, feedback: 0.7) + drums.delay(seconds: 5.0 / 6.0, feedback: 0.4)
graph1 = (1.1 * echo1 + 0.2 * flange1).filter(:lowpass, cutoff: filter_lfo, quality: 5)
graph2 = (1.1 * echo2 + 0.2 * flange2).filter(:lowpass, cutoff: filter_lfo, quality: 5)

MB::Sound.play [graph1.softclip, graph2.softclip]
