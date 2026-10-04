#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Prints events as they occur in real time, either from live MIDI or a MIDI
# file.  Can optionally forward events to a jackd MIDI output.
#
# Live MIDI comes through RtMidi (CoreMIDI, ALSA, or JACK; see
# MB::Sound::MIDI::Input); without an input argument, connect a MIDI source to
# the virtual port it creates.  Forwarding still uses MB::Sound::JackFFI and
# needs jackd running (MIDI output is a later project).
#
# Usage:
#     $0 [--forward] [--forward-to PORT] [part_of_a_midi_source_name_or_midi_filename]

require 'bundler/setup'

require 'nibbler'
require 'forwardable'

require 'mb-sound'
require 'mb-sound-jackffi'
require 'mb-util'

MB::U.sigquit_backtrace


MB::Sound.script(
  args: 0..1,
  forward: [false, 'Forward events to a JACK MIDI output'],
  forward_to: [nil, String, 'Forward events to this JACK MIDI port (implies --forward)'],
) { |(input), p|
  puts "#{"\n" * MB::U.height}\e[H\e[J" # move to home, then clear everything

  if p.forward || p.forward_to
    puts 'Enabling output'
    puts "Connecting output to #{p.forward_to.inspect}" if p.forward_to
    midi_out = MB::Sound::JackFFI[].output(port_type: :midi, port_names: ['midi_out'], connect: p.forward_to)
  end

  if input && input.end_with?('.mid') && File.readable?(input)
    puts "Reading MIDI from #{input}"
    midi_in = MB::Sound::MIDI::MIDIFile.new(input)
  else
    midi_in = MB::Sound::MIDI::Input.open_live(input)
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
      data = midi_in.read(blocking: false)
      exit if data.nil? # end of a MIDI file
      break if data[0].nil?

      data[0].each do |t, e|
      # TODO: Somehow show realtime messages without them overwhelming other messages
        events.concat([midi.parse(e.bytes)].flatten.compact.reject { |e| e.is_a?(MIDIMessage::SystemRealtime) })
      end
    end

    events.each_with_index do |e, idx|
      id = "#{MB::U.highlight(frame).strip}.#{MB::U.highlight(idx).strip}"
      puts "#{('%.2f' % elapsed).rjust(5)}: #{id.rjust(6)}: #{MB::U.highlight(e).lines.map { |v| v.rstrip + "\e[K" }.join("\n")}"
      case e
      when MIDIMessage::ControlChange
        cc_chart[e.index] = e.value
      end

      midi_out&.write([Numo::Int8.cast(e.to_a)])
    end

    frame += 1
    sleep 0.001
  end
}
