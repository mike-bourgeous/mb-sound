#!/usr/bin/env ruby
# A very rough approximation of Solid Bass or Lately Bass from the classic
# Yamaha FM synthesizers.

require 'bundler/setup'
require 'mb-sound'

MB::U.sigquit_backtrace

OSC_COUNT = ENV['OSC_COUNT']&.to_i || 1
voices = OSC_COUNT.times.map { |i|
  base = 440.constant
  freq_constants = []
  bfreq = -> { 2 ** base.dup.tap { |z| freq_constants << z }.log2.smooth(seconds: 0.1) }

  # TODO: True FM/PM feedback instead of a duplicate copy of the oscillator
  cenv = MB::Sound.adsr(0, 0.2, 0.0, 0.1, auto_release: false).named('cenv').db(30)
  cenv2 = MB::Sound.adsr(0, 0.2, 0.0, 0.1, auto_release: false).named('cenv2').db(30)
  fbconst = 4.constant.named('Feedback')
  c = cenv * MB::Sound.tone(bfreq.call * 2).complex_sine.at(1).pm(cenv2 * fbconst * MB::Sound.tone(bfreq.call * 2).at(1).forever).forever

  denv = MB::Sound.adsr(0, 0.3, 0.0, 0.35, auto_release: false).named('denv').db(30)
  d = denv * MB::Sound.tone(bfreq.call * 2 * 0.9996 - 0.22).complex_sine.at(1).forever.named('d')

  eenv = MB::Sound.adsr(0, 2, 0.7, 0.5, auto_release: false).named('eenv')
  cconst = 0.9.constant.named('C')
  dconst = 0.7.constant.named('D')
  e = eenv.db * MB::Sound.tone(bfreq.call).complex_sine.at(1).pm(c * cconst + d * dconst).forever.named('e')

  fenv = MB::Sound.adsr(0, 2, 0.8, 0.5, auto_release: false).named('fenv')
  econst = 2.constant.named('E')
  f = fenv.db * MB::Sound.tone(bfreq.call).complex_sine.at(1).pm(e * econst).named('f')

  g = f.real.filter(15000.hz.lowpass).oversample(4, mode: :libsamplerate_fastest) # Try to cut down on aliasing chalkboard noise

  final = g + g.delay(seconds: 0.1) * 0.125

  MB::Sound::MIDI::GraphVoice.new(
    final,
    amp_envelopes: [fenv],
    freq_constants: freq_constants
  ).named('FM Bass').tap { |v|
    v.on_cc(1, 'Feedback', range: 1.0..2.0)
    v.on_cc(1, 'C', range: 1.0..2.0)
    v.on_cc(1, 'D', range: 1.0..2.0)
    v.on_cc(1, 'E', range: 1.0..2.0)
  }
}

voices[0].open_graphviz

repeat = !!ARGV.delete('--loop')

# TODO: Build an abstraction around switching between Jack and MIDI files for
# input, and FLAC files for output, for use by all synthesizers
jack = MB::Sound::JackFFI[]
output = jack.output(channels: 1, connect: [['system:playback_1', 'system:playback_2']])
midi = MB::Sound::MIDI::MIDIFile.new(ARGV[0]) if ARGV[0]&.end_with?('.mid') # TODO: Add a clock source based on jackd frames
manager = MB::Sound::MIDI::Manager.new(jack: jack, input: midi, connect: ARGV[0])
pool = MB::Sound::MIDI::VoicePool.new(
  manager,
  voices
)

output_chain = (pool * 20).softclip(0.8, 0.95)

if ENV['DEBUG'] == '1'
  puts 'saving before graph'
  File.write('/tmp/pm_bass_before.dot', output_chain.graphviz)
  `dot -Tpng /tmp/pm_bass_before.dot -o /tmp/pm_bass_before.png`
end

puts MB::U.syntax(manager.to_acid_xml, :xml)

begin
  puts 'starting loop'
  loop do
    manager.update
    output.write([output_chain.sample(output.buffer_size)])

    if midi&.empty?
      pool.all_off
      midi.seek(0) if repeat
    end
    break if midi&.empty? && !pool.active? && !repeat
  end
ensure
  if ENV['DEBUG'] == '1'
    puts 'saving after graph'
    File.write('/tmp/pm_bass_after.dot', output_chain.graphviz)
    `dot -Tpng /tmp/pm_bass_after.dot -o /tmp/pm_bass_after.png`
  end
end
