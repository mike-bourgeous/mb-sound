#!/usr/bin/env ruby
# A very rough approximation of Solid Bass or Lately Bass from the classic
# Yamaha FM synthesizers.

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script { |input|
  s = MB::Sound.synth(input) { |midi|
    base = midi.number.named('Note number').smooth(seconds: 0.1).freq.named('Base freq')
    base2x = (base * 2).named('Base 2x')
    mod = midi.cc(1, range: 1.0..2.0)

    # TODO: True FM/PM feedback instead of a duplicate copy of the oscillator
    cenv = midi.env(0, 0.2, 0.0, 0.1).named('cenv').db(30)
    c = cenv * base2x.tone.complex_sine.at(1).pm(cenv * mod * base2x.tone.at(1))

    denv = midi.env(0, 0.3, 0.0, 0.35).named('denv').db(30)
    d = denv * (base2x * 0.9996 - 0.22).tone.complex_sine.at(1).named('d')

    # FIXME: sounds are too quiet below ~80 velocity
    eenv = midi.env(0, 2, 0.7, 0.5).named('eenv').db
    e = eenv * base.tone.complex_sine.at(1).pm(mod * (c + d)).named('e')

    fenv = midi.env(0, 2, 0.8, 0.5).named('fenv').db
    f = fenv * base.tone.complex_sine.at(1).pm(e * mod).named('f')

    f.real
  }

  # Reduce aliasing noise
  s = s.softclip(0.8, 0.95)
    .filter(15000.hz.lowpass)
    .oversample(4, mode: :libsamplerate_fastest)

  s + s.delay(seconds: 0.1) * 0.125
}

voices[0].open_graphviz

pool = MB::Sound::MIDI::VoicePool.new(
  manager,
  voices
)

output_chain = (pool * 20).softclip(0.8, 0.95)

if ENV['DEBUG'] == '1'
  puts 'saving before graph'
  File.write('/tmp/fm_bass_before.dot', output_chain.graphviz)
  `dot -Tpng /tmp/fm_bass_before.dot -o /tmp/fm_bass_before.png`
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
    File.write('/tmp/fm_bass_after.dot', output_chain.graphviz)
    `dot -Tpng /tmp/fm_bass_after.dot -o /tmp/fm_bass_after.png`
  end
end
