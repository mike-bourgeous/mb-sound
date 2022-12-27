#!/usr/bin/env ruby
# Prints events as they occur in real time, either from a jackd input or a MIDI
# file.  Can optionally forward events to a jackd MIDI output.
#
# Requires MB::Sound::JackFFI and needs jackd running for realtime input.
#
# Usage:
#     $0 [--output[=output_port_name]] [input_port_or_midi_filename]

require 'bundler/setup'

require 'nibbler'
require 'forwardable'

require 'mb-sound'
require 'mb-sound-jackffi'

puts "#{"\n" * MB::U.height}\e[H\e[J" # move to home, then clear everything

if ARGV.include?('--help')
  puts MB::U.read_header_comment.join.gsub('$0', $0)
  exit 1
end

if ARGV[0] == '--output' || ARGV[0]&.start_with?('--output=')
  out_port = ARGV[0].split('=', 2)[1]
  puts 'Enabling output'
  puts "Connecting output to #{out_port.inspect}" if out_port
  midi_out = MB::Sound::JackFFI[].output(port_type: :midi, port_names: ['midi_out'], connect: out_port)
  ARGV.shift
end

# TODO: Just use a standard getopt-like option parser
if ARGV[0] && ARGV[0].end_with?('.mid') && File.readable?(ARGV[0])
  puts "Reading MIDI from #{ARGV[0]}"
  midi_in = MB::Sound::MIDI::MIDIFile.new(ARGV[0])
else
  midi_in = MB::Sound::JackFFI[].input(port_type: :midi, port_names: ['midi_in'], connect: ARGV[0] || :physical)
end

midi = Nibbler.new

cc_chart = Array.new(128)

# See bin/ep2_syn.rb for an example of an event loop that works with MIDI and
# audio together (basically read MIDI with blocking: false)
frame = 0
start = Time.now
loop do
  elapsed = Time.now - start
  midi.clear_buffer

  events = []
  while events.empty?
    data = midi_in.read
    return if data.nil?
    # TODO: Somehow show realtime messages without them overwhelming other messages
    events = [midi.parse(data[0]&.bytes)].flatten.compact.reject { |e| e.is_a?(MIDIMessage::SystemRealtime) }
  end

  events.each_with_index do |e, idx|
    id = "#{MB::U.highlight(frame).strip}.#{MB::U.highlight(idx).strip}"
    puts "#{('%.2f' % elapsed).rjust(5)}: #{id.rjust(6)}: #{MB::U.highlight(e).lines.map { |v| v.rstrip + "\e[K" }.join("\n")}"
    case e
    when MIDIMessage::ControlChange
      cc_chart[e.index] = e.value
    end

    midi_out&.write([e.to_a.pack('C*')])
  end

  frame += 1
end
