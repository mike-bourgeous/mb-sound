#!/usr/bin/env ruby
# Trying to synthesize a kick inspired by a YouTube tutorial:
# https://www.youtube.com/watch?v=ndG-6-vONNc

require 'bundler/setup'

require 'mb-sound'

# Generates a node graph and GraphVoice to synthesize a kick
def kicker
  # TODO: the node graph and GraphVoice really need some concept of i/o ports
  # and configurable parameters.
  #
  # Also the envelope generator needs to be smarter about dynamic parameter
  # changes.
  base = 440.constant
  freq_constants = []
  bfreq = -> { 2 ** base.dup.tap { |z| freq_constants << z }.log2.smooth(seconds: 0.1) }

  freq_env = MB::Sound.adsr(0.0005, 0.1, 0, 0.01)
  freq_env_range = freq_env.db(30) * 400 + 40

  falling_sine = (freq_env_range + bfreq.call).tone.at(0.1)

  apply_amp_env = falling_sine.adsr(0.0001, 0.5, 0, 0.5)

  final = apply_amp_env

  MB::Sound::MIDI::GraphVoice.new(
    final,
    freq_constants: freq_constants
  ).named('Kick').tap { |v|
    # v.on_cc(1, ''
  }
end

OSC_COUNT = ENV['OSC_COUNT']&.to_i || 2

voices = Array.new(OSC_COUNT) { kicker }

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

output_chain = (pool * 0.db).softclip(0.6, 0.99)

if ENV['DEBUG'] == '1'
  puts 'saving before graph'
  File.write('/tmp/fm_kick_before.dot', output_chain.graphviz)
  `dot -Tpng /tmp/fm_kick_before.dot -o /tmp/fm_kick_before.png`
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
    File.write('/tmp/fm_kick_after.dot', output_chain.graphviz)
    `dot -Tpng /tmp/fm_kick_after.dot -o /tmp/fm_kick_after.png`
  end
end

