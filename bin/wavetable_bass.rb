#!/usr/bin/env ruby
# Wavetable- and waveshaping-based monophonic bass synth.

require 'bundler/setup'
require 'mb-util'
require 'mb-sound'

MB::U.sigquit_backtrace

DETUNE_CENTS = 5
DETUNE_SEMIS = 0.01 * DETUNE_CENTS
DETUNE_RANGE = (2 ** -DETUNE_SEMIS)..(2 ** DETUNE_SEMIS)
PORTAMENTO_TIME = 0.1 # TODO: control with midi CC for portamento

if ARGV[0]&.downcase&.end_with?('.mid') && File.readable?(ARGV[0])
  # FIXME: exit when the MIDI file has ended
  midi = MB::Sound.midi_file(ARGV[0], speed: ENV['MIDI_SPEED']&.to_f || 1)
else
  midi = MB::Sound.midi
end

cc1 = midi.cc(1).filter(:lowpass, cutoff: 10, quality: 0.5)
cc2 = midi.cc(2, range: 1..10).filter(:lowpass, cutoff: 10, quality: 0.5)
cc4 = midi.cc(4).filter(:lowpass, cutoff: 10, quality: 0.5)

MB::U.headline('Loading wavetables...')

synth = MB::Sound::Wavetable.load_wavetable('sounds/drums.flac', slices: 10)
shaper = MB::Sound::Wavetable.load_wavetable('sounds/synth0.flac', slices: 10)

voices = Array.new(4) do
  (
    midi.env(0.003, 0.05, 0.5, 0.3) * cc2 *
    (
      midi.frequency(rand(DETUNE_RANGE)).filter(:lowpass, cutoff: 1.0 / PORTAMENTO_TIME, quality: 0.5).tone.ramp.at(2).wavetable(wavetable: synth, number: cc1).filter(:lowpass, cutoff: 5000, quality: 0.4) +
        midi.frequency(rand(DETUNE_RANGE)).filter(:lowpass, cutoff: 1.0 / PORTAMENTO_TIME, quality: 0.5).tone.triangle.at(0.5)
    )
  ).softclip
    .*(2)
    .wavetable(wavetable: shaper, number: cc4)
    .filter(:highpass, cutoff: 10, quality: 0.7)
end

l = (0.5 * voices[0] + voices[1]).filter(:lowpass, cutoff: 15000, quality: 0.25).softclip #XXX .oversample(2)
r = (0.5 * voices[2] + voices[3]).filter(:lowpass, cutoff: 15000, quality: 0.25).softclip #XXX .oversample(2)

MB::U.headline('Begin play!')

MB::Sound.play([l, r], plot: false)
