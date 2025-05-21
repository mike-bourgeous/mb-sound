#!/usr/bin/env ruby
# One-oscillator synthesizer based on MB::Sound::MIDI::Voice (slight upgrade of
# bin/ep2_syn.rb).
#
# GraphVoice is better so use that for building new synths.

require 'bundler/setup'

require 'mb-sound'
require 'mb-sound-jackffi'

MB::Sound::Oscillator.tune_freq = 480
MB::Sound::Oscillator.tune_note = 71

jack = MB::Sound::JackFFI['EP2Synth']
output = jack.output(port_names: ['Synth', 'Impulse'], channels: 2, connect: :physical)
manager = MB::Sound::MIDI::Manager.new(jack: jack, connect: ARGV[0] || :physical, channel: 0)

OSC_COUNT = 8
OVERSAMPLE = ENV['OVERSAMPLE']&.to_f || 16
osc_pool = MB::Sound::MIDI::VoicePool.new(
  manager,
  OSC_COUNT.times.map { MB::Sound::MIDI::Voice.new }
).real
  .filter(:lowpass, cutoff: 16000 * MB::M.min(1, OVERSAMPLE))
  .oversample(OVERSAMPLE, mode: :libsamplerate_fastest)

filter = 1500.hz.lowpass(quality: 4)
softclip = MB::Sound::SoftestClip.new(threshold: 0.5)

manager.on_cc(1, default: 1.8, range: 0..3) do |decade|
  freq = 20.0 * 10.0 ** decade
  filter.center_frequency = freq
end

loop do
  manager.update

  data = osc_pool.sample(output.buffer_size)
  data = filter.process(data)
  data = softclip.process(data * 0.2)
  output.write([data, data])
end
