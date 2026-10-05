#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Prints events as they occur in real time, either from live MIDI or a MIDI
# file.  Can optionally forward events to a MIDI output.
#
# Events come from a MIDI::Stream (see MB::Sound::MIDI::RealtimeReader): live
# MIDI through JACK or RtMidi (see MB::Sound::MIDI::Input), or a MIDI file
# played in real time.  Without an input argument, connect a MIDI source to
# the port it creates.  --forward sends events from a virtual source named
# after this script; --forward-to connects to a destination by part of its
# name.
#
# Usage:
#     $0 [--forward] [--forward-to PORT] [part_of_a_midi_source_name_or_midi_filename]

require 'bundler/setup'

require 'mb-sound'
require 'mb-util'

MB::U.sigquit_backtrace

MB::Sound.script(
  args: 0..1,
  forward: [false, 'Forward events from a virtual MIDI source'],
  forward_to: [nil, String, 'Forward events to the MIDI destination whose name contains this (implies --forward)'],
) { |(input), p|
  puts "#{"\n" * MB::U.height}\e[H\e[J" # move to home, then clear everything

  if p.forward || p.forward_to
    puts 'Enabling output'
    puts "Connecting output to #{p.forward_to.inspect}" if p.forward_to
    midi_out = MB::Sound::MIDI::Output.new(connect: p.forward_to)
    puts "Sending to #{midi_out.connections.first} (#{midi_out.api})"
  end

  midi_in = MB::Sound::MIDI::RealtimeReader.new(input)
  puts "Reading MIDI from #{input}" if midi_in.file?

  frame = 0
  begin
    # TODO: Somehow show realtime messages without them overwhelming other messages
    while (events = midi_in.read)
      events.each_with_index do |e, idx|
        id = "#{MB::U.highlight(frame).strip}.#{MB::U.highlight(idx).strip}"
        puts "#{('%.2f' % e.time).rjust(5)}: #{id.rjust(6)}: #{e}\e[K"
        midi_out&.write(e.bytes) if e.bytes
      end

      frame += 1
    end
  rescue Interrupt
    puts
  ensure
    midi_in.close
    midi_out&.close
  end
}
