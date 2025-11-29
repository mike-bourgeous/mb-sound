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
)

graph = osc_pool
  .real
  .filter(:lowpass, cutoff: 16000 * MB::M.min(1, OVERSAMPLE))
  .oversample(OVERSAMPLE, mode: :libsamplerate_fastest)

graph = (graph * 0.4).softclip(0.5)

manager.on_cc(1, default: 1.8, range: 1..3) do |decade|
  freq = 20.0 * 10.0 ** decade

  osc_pool.each do |v|
    v.cutoff = freq
    v.vibrato_intensity = (decade - 1) / 2
  end
end

loop do
  manager.update
  data = graph.sample(output.buffer_size)
  output.write([data, data])
end
