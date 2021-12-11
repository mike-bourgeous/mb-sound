#!/usr/bin/env ruby

require 'bundler/setup'
require 'mb-sound'

OSC_COUNT = ENV['OSC_COUNT']&.to_i || 1
voices = OSC_COUNT.times.map { |i|
  base = MB::Sound::Constant.new(440)
  freq_constants = []
  bfreq = -> { base.dup.tap { |z| freq_constants << z } }

  # TODO: True FM/PM feedback instead of a duplicate copy of the oscillator
  cenv = MB::Sound.adsr(0, 0.005, 0.0, 0.005, auto_release: false).named('cenv').db(30)
  cenv2 = MB::Sound.adsr(0, 0.01, 0.0, 0.01, auto_release: false).named('cenv2').db(60)
  c = cenv * MB::Sound.tone(bfreq.call * 2).at(1).pm(cenv2 * MB::Sound.tone(bfreq.call * 2).at(1).forever).forever

  denv = MB::Sound.adsr(0, 0.005, 0.0, 0.005, auto_release: false).named('denv').db(50)
  d = denv * MB::Sound.tone(bfreq.call * 2 * 0.9996 - 0.22).at(1).forever.named('d')

  eenv = MB::Sound.adsr(0, 2, 0.7, 2, auto_release: false).named('eenv')
  cconst = 15.constant.named('cconst')
  dconst = 13.constant.named('dconst')
  e = eenv.db * MB::Sound.tone(bfreq.call).at(1).pm(c * cconst + d * dconst).forever.named('e')

  fenv = MB::Sound.adsr(0, 2, 0.8, 2, auto_release: false).named('fenv')
  econst = 18.constant.named('econst')
  f = fenv.db * MB::Sound.tone(bfreq.call).at(1).pm(e * econst).named('f')

  MB::Sound::MIDI::GraphVoice.new(f, amp_envelopes: [fenv], freq_constants: freq_constants)
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
File.write('/tmp/pm_bass_before.dot', output_chain.graphviz)
`dot -Tpng /tmp/pm_bass_before.dot -o /tmp/pm_bass_before.png`

begin
  puts 'starting loop'
  loop do
    manager.update
    output.write([output_chain.sample(output.buffer_size)])
  end
ensure
  puts 'saving after graph'
  File.write('/tmp/pm_bass_after.dot', output_chain.graphviz)
  `dot -Tpng /tmp/pm_bass_after.dot -o /tmp/pm_bass_after.png`
end