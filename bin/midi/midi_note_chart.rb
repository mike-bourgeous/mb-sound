#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Shows the attack velocity of notes while they are held.
#
# Reads live MIDI (JACK or RtMidi; see MB::Sound::MIDI::Input) or a MIDI file
# played in real time (see MB::Sound::MIDI::RealtimeReader).  Without an
# argument, connect a MIDI source to the port it creates.
#
# Usage: $0 [part_of_a_midi_source_name_or_midi_filename]

require 'bundler/setup'

require 'mb-sound'

MB::Sound.script(args: 0..1) { |(input)|
  midi_in = MB::Sound::MIDI::RealtimeReader.new(input)
  puts "Reading MIDI from #{input}" if midi_in.file?

  note_chart = Array.new(128)

  puts "#{"\n" * MB::U.height}\e[H\e[J" # move to home, then clear everything

  frame = 0
  begin
    loop do
      STDOUT.write("\e[J\e[H") # clear below the current output first, then move to home
      MB::U.table(
        note_chart.each_slice(12).map.with_index { |r, idx| [idx - 1] + r },
        header: ['###', 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'],
        separate_rows: true
      )
      puts

      # TODO: Somehow show realtime messages without clearing the other received messages
      events = midi_in.read
      break if events.nil? # end of a MIDI file

      events.each_with_index do |e, idx|
        id = "#{MB::U.highlight(frame).strip}.#{MB::U.highlight(idx).strip}"
        puts "#{id}: #{e}\e[K"
        case e.type
        when :note_on
          note_chart[e.note] = e.raw

        when :note_off
          note_chart[e.note] = "\e[38;5;237m#{-e.raw}\e[0m"
        end
      end

      frame += 1
    end
  rescue Interrupt
    puts
  ensure
    midi_in.close
  end
}
