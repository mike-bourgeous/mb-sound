#!/usr/bin/env ruby

require 'bundler/setup'
require 'mb-sound'

OSC_COUNT = ENV['OSC_COUNT']&.to_i || 1
voices = OSC_COUNT.times.map { |i|
  note = MB::Sound::Note.new(36 + i * 16)
  note2 = MB::Sound::Note.new(note.number + 12)

  cenv = MB::Sound.adsr(0, 0.005, 0.5, 0.005, auto_release: false).db(30)
  cenv2 = MB::Sound.adsr(0, 0.01, 0.5, 0.01, auto_release: false).db(60)
  c = cenv * note2.dup.at(1).fm(cenv2 * note2.dup.at(1)).forever

  denv = MB::Sound.adsr(0, 0.005, 0.0, 0.005, auto_release: false).db(50)
  d = denv * MB::Sound::Tone.new(frequency: note2.dup.frequency.constant * 0.9996 - 0.22).at(1).forever

  eenv = MB::Sound.adsr(0, 2, 0, 2, auto_release: false)
  e = eenv.db * note.dup.at(1).fm(c * 4810 + d * 500).forever

  fenv = MB::Sound.adsr(0, 2, 0, 2, auto_release: false)
  f = fenv.db * note.dup.at(1).fm(e * 250)

  # FIXME: This is using a Mixer as a frequency constant
  MB::Sound::MIDI::GraphVoice.new(f, amp_envelopes: [fenv])
}

jack = MB::Sound::JackFFI[]
output = jack.output(channels: 1, connect: [['system:playback_1', 'system:playback_2']])
manager = MB::Sound::MIDI::Manager.new(jack: jack, connect: ARGV[0])
pool = MB::Sound::MIDI::VoicePool.new(
  manager,
  voices
)

output_chain = (pool * 20).softclip(0.8, 0.95)

puts 'saving before graph'
File.write('/tmp/fm_bass_before.dot', output_chain.graphviz)
`dot -Tpng /tmp/fm_bass_before.dot -o /tmp/fm_bass_before.png`

begin
  puts 'starting loop'
  loop do
    manager.update
    output.write([output_chain.sample(output.buffer_size)])
  end
ensure
  puts 'saving after graph'
  File.write('/tmp/fm_bass_after.dot', output_chain.graphviz)
  `dot -Tpng /tmp/fm_bass_after.dot -o /tmp/fm_bass_after.png`
end
