#!/usr/bin/env ruby
# Shows the last-received value of MIDI CCs in a table layout.
#
# Requires MB::Sound::JackFFI and needs jackd running.

require 'bundler/setup'

require 'nibbler'
require 'forwardable'

require 'mb-sound'
require 'mb-sound-jackffi'

if ARGV.include?('--help')
  puts MB::U.read_header_comment.join.gsub('$0', $0)
  exit 1
end

if ARGV[0] && ARGV[0].end_with?('.mid') && File.readable?(ARGV[0])
  puts "Reading MIDI from #{ARGV[0]}"
  midi_in = MB::Sound::MIDI::MIDIFile.new(ARGV[0])
else
  jack = MB::Sound::JackFFI[]
  midi_in = jack.input(port_type: :midi, port_names: ['midi_in'], connect: ARGV[0] || :physical)
end

midi = Nibbler.new

cc_chart = Array.new(128)

puts "#{"\n" * MB::U.height}\e[H\e[J" # move to home, then clear everything

# See bin/ep2_syn.rb for an example of an event loop that works with MIDI and
# audio together (basically read MIDI with blocking: false)
frame = 0
loop do
  STDOUT.write("\e[J\e[H") # clear below the current output first, then move to home
  MB::U.table(
    cc_chart.each_slice(10).map.with_index { |r, idx| [idx * 10] + r },
    header: ['CCs'] + (0..9).to_a,
    separate_rows: true
  )
  puts

  midi.clear_buffer

  events = []
  while events.empty?
    data = midi_in.read
    return if data.nil?
    # TODO: Somehow show realtime messages without clearing the other received messages
    events = [midi.parse(data[0]&.bytes)].flatten.compact.reject { |e| e.is_a?(MIDIMessage::SystemRealtime) }
  end

  events.each_with_index do |e, idx|
    id = "#{MB::U.highlight(frame).strip}.#{MB::U.highlight(idx).strip}"
    puts "#{id}: #{MB::U.highlight(e).lines.map { |v| v.rstrip + "\e[K" }.join("\n")}"
    case e
    when MIDIMessage::ControlChange
      cc_chart[e.index] = e.value
    end
  end

  frame += 1
end
