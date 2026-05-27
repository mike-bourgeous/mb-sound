#!/usr/bin/env ruby
# A simple filter pinging synthesizer.

require 'bundler/setup'
require 'mb-sound'

MB::U.sigquit_backtrace

OSC_COUNT = ENV['OSC_COUNT']&.to_i || 8
repeat = !!ARGV.delete('--loop')

# TODO: Build an abstraction around switching between Jack and MIDI files for
# input, and FLAC files for output, for use by all synthesizers
jack = MB::Sound::JackFFI[]
output = jack.output(channels: 1, connect: [['system:playback_1', 'system:playback_2']])
midi = MB::Sound::MIDI::MIDIFile.new(ARGV[0]) if ARGV[0]&.end_with?('.mid') # TODO: Add a clock source based on jackd frames
manager = MB::Sound::MIDI::Manager.new(jack: jack, input: midi, connect: ARGV[0])

voices = OSC_COUNT.times.map { |i|
  MB::Sound::MIDI::GraphVoice.new(manager: manager) do |midi|
    # TODO: keyboard tracking for higher amplitude at lower frequency
    # FIXME: filter sweep from midi param interpolation causes high energy in filter
    midi.click(range: 5..25).filter(:lowpass, cutoff: midi.frequency, quality: midi.cc(1, range: 50..150)).softclip
  end
}

voices[0].open_graphviz

pool = MB::Sound::MIDI::VoicePool.new(
  manager,
  voices
)

output_chain = pool.softclip(0.8, 0.95).oversample(3)

if ENV['DEBUG'] == '1'
  puts 'saving before graph'
  File.write('/tmp/filter_ping_before.dot', output_chain.graphviz)
  `dot -Tpng /tmp/filter_ping_before.dot -o /tmp/filter_ping_before.png`
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
    File.write('/tmp/filter_ping_after.dot', output_chain.graphviz)
    `dot -Tpng /tmp/filter_ping_after.dot -o /tmp/filter_ping_after.png`
  end
end

