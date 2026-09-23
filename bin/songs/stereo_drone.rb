#!/usr/bin/env ruby

require 'bundler/setup'
require 'mb-sound'

def toneseq(interval, *tones)
  phase = -2.0 * Math::PI / tones.length
  lfo_freq = 1.0 / interval

  tones.map.with_index { |f, idx|
    f = f.frequency if f.is_a?(MB::Sound::Note)
    lfo_freq.hz.triangle.at(-90..-12).with_phase(Math::PI * 0.25 + phase * idx).db * f.hz.sine.pm((f * 2.hz.lfo.at(2.98..3.02)).tone.at(2) * (lfo_freq/2 + lfo_freq/tones.count * idx).hz.lfo.at(0..1)).at(1)
  }
end

q = 0.5 * toneseq(12, MB::Sound::B1, MB::Sound::Ds2, MB::Sound::E2).sum

tones = toneseq(32, MB::Sound::Fs3, MB::Sound::Ds3, MB::Sound::Fs3, MB::Sound::E3, MB::Sound::Fs4, MB::Sound::Ds4, MB::Sound::Fs4, MB::Sound::E4).each_slice(2).to_a.transpose

noise = (1.hz.noise * 0.056.hz.lfo.at(-20..-10).db * MB::Sound::B1.at(-2..1)).filter(:lowpass, cutoff: 0.082.hz.lfo.at(300..2200), quality: 2)

a = (0.3 * tones[0].sum + q + noise)
  .softclip(0.6)
  .oversample(2)
  .forever
b = (0.3 * tones[1].sum + q - noise)
  .softclip(0.6)
  .oversample(2)
  .forever

left = a.delay(seconds: 0.4.hz.lfo.at(0..0.013), feedback: -0.5, dry: 1, smoothing: false).softclip(0.8)
right = b.delay(seconds: 0.3.hz.lfo.at(0..0.02), feedback: -0.5, dry: 1, smoothing: false).softclip(0.8)

out = [left, right] # MB::Sound::GraphNode::Reverb.reverb(:space, input: [left, right], output_channels: 2, wet: -10.db, dry: -3.db)

MB::Sound.play(out)
