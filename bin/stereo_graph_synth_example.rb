#!/usr/bin/env ruby

require 'bundler/setup'
require 'mb-sound'

if ARGV[0]&.downcase&.end_with?('.mid') && File.readable?(ARGV[0])
  # FIXME: exit when the MIDI file has ended
  midi = MB::Sound.midi_file(ARGV[0])
else
  midi = MB::Sound.midi
end

q = (midi.frequency * 2.001).tone.at(1).with_phase(Math::PI/3) + 0.1.hz.lfo.at(1) * (midi.frequency * 1.001).tone.at(Math::PI)
a = (
  (
    ((midi.frequency * 6.001).tone.pm(q) + (midi.frequency * 8.001).tone.pm(q)) + (midi.frequency * 0.501).tone.ramp.at(0.3).filter(:lowpass, cutoff: 0.23.hz.lfo.at(130..2500))
  ) * midi.env
).softclip.oversample(2)

left = a.delay(seconds: 0.4.hz.lfo.at(0..0.01), feedback: -0.5, dry: 1, smoothing: false).softclip
right = a.delay(seconds: 0.3.hz.lfo.at(0..0.01), feedback: -0.5, dry: 1, smoothing: false).softclip

MB::Sound.play([left, right])
