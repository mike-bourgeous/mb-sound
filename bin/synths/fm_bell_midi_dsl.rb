#!/usr/bin/env ruby
# A tubular bell sound based in part on the T.BL-EXPA preset included with
# Dexed.

require 'bundler/setup'
require 'mb-sound'
require 'mb-util'

MB::U.sigquit_backtrace

repeat = !!ARGV.delete('--loop')

# TODO: Build an abstraction around switching between Jack and MIDI files for
# input, and FLAC files for output, for use by all synthesizers
jack = MB::Sound::JackFFI[]
output = jack.output(channels: 1, connect: [['system:playback_1', 'system:playback_2']])
midi_in = MB::Sound::MIDI::MIDIFile.new(ARGV[0]) if ARGV[0]&.end_with?('.mid') # TODO: Add a clock source based on jackd frames
manager = MB::Sound::MIDI::Manager.new(jack: jack, input: midi_in, connect: ARGV[0])

OSC_COUNT = ENV['OSC_COUNT']&.to_i || 9
voices = OSC_COUNT.times.map { |i|
  MB::Sound::MIDI::GraphVoice.new(update_rate: manager.update_rate, manager: manager) { |midi|

    # TODO: easy shortcuts for portamento and/or tones based on note number
    # FIXME: key tracking is not linear???
    base = MB::Sound::Oscillator.calc_freq(midi.number.filter(:lowpass, cutoff: 25, quality: 0.5))

    b_d_ratio = midi.cc(1, range: 3.5..4.0).named('B and D Ratio')

    b_d_env = midi.env(0, 5, 0, 4).named('B and D Envelope').db(30)
    a_c_env = midi.env(0, 6, 0, 5).named('A and C Envelope').db(30)

    ba_dc_const = midi.velocity(range: 3.0..6.0).named('B into A and D into C')

    # 7 mils detuned up, 3.5 ratio
    b_osc = (base * b_d_ratio * (2 ** (7.0 / 1000.0))).tone.complex_sine.at(1).named('B')
    b_out = (b_osc * b_d_env).named('B Out')

    # 7 mils up
    a_osc = (base * (2 ** (7.0 / 1000.0))).tone.complex_sine.at(1).pm(b_out * ba_dc_const).named('A')
    a_out = (a_osc * a_c_env).named('A Out')

    # 5 mils up, 3.5 ratio
    d_osc = (base * b_d_ratio * (2 ** (5.0 / 1000.0))).tone.complex_sine.at(1).named('D')
    d_out = (d_osc * b_d_env).named('D Out')

    # 2 mils up
    c_osc = (base * (2 ** (2.0 / 1000.0))).tone.complex_sine.at(1).pm(d_out * ba_dc_const).named('C')
    c_out = (c_osc * a_c_env).named('C Out')

    sum = (a_out + c_out) * midi.velocity(range: 0.5..1.0).named('Output Level (velocity)')

    g = sum.filter(15000.hz.lowpass) # Try to cut down on aliasing chalkboard noise

    final = (g * 0.25).real
  }.named('FM Tubular Bell')
}

pool = MB::Sound::MIDI::VoicePool.new(
  manager,
  voices
)
output_chain = pool.softclip(0.8, 0.95).oversample(2)

if ENV['DEBUG'] == '1'
  puts 'saving before graph'
  File.write('/tmp/pm_bass_before.dot', output_chain.graphviz)
  `dot -Tpng /tmp/pm_bass_before.dot -o /tmp/pm_bass_before.png`
end

puts MB::U.syntax(manager.to_acid_xml, :xml)

begin
  puts 'starting loop'
  MB::Sound.plot(output_chain)

  loop do
    manager.update
    output.write([output_chain.sample(output.buffer_size)])

    if midi_in&.empty?
      pool.all_off
      midi_in.seek(0) if repeat
    end
    break if midi_in&.empty? && !pool.active? && !repeat
  end
ensure
  if ENV['DEBUG'] == '1'
    puts 'saving after graph'
    File.write('/tmp/pm_bass_after.dot', output_chain.graphviz)
    `dot -Tpng /tmp/pm_bass_after.dot -o /tmp/pm_bass_after.png`
  end
end
