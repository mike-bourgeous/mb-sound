#!/usr/bin/env ruby
# Displays an extremely simple piano roll style view of a MIDI file.
#
# Usage: $0 midi_file.mid

require 'bundler/setup'

require 'mb-sound'

f = MB::Sound::MIDI::MIDIFile.new(ARGV[0])

notes = f.notes.group_by { |n| n[:number] }

# Determine scaling and offset for window
# TODO: use median note
min_note = notes.keys.min
max_note = notes.keys.max

return if min_note.nil?

if max_note - min_note >= MB::U.height
  min_note = max_note - MB::U.height
  min_note = 0 if min_note < 0
  max_note = min_note + MB::U.height if max_note > min_note + MB::U.height
end

cols = MB::U.width - 5
cols_per_sec = cols / f.notes.map { |n| n[:sustain_time] }.max

for number in min_note..max_note do
  r = [' '] * (cols + 1) # FIXME: why is a note sometimes going beyond the end?
  note = MB::Sound::Note.new(number)

  notes[number]&.each do |n|
    c1 = (cols_per_sec * n[:on_time]).floor
    c2 = (cols_per_sec * n[:off_time]).floor
    c3 = (cols_per_sec * n[:sustain_time]).floor

    gray = "\e[38;5;#{n[:on_velocity] * 10 / 127 + 238}m"

    # TODO: color by channel, better symbols

    # pedal sustain
    for c in (c2 + 1)..c3 do
      r[c] = "#{gray}\u254c"
    end

    # key release
    if n[:sustain_time] > n[:off_time]
      r[c2] = "#{gray}\u2539"
    else
      r[c2] = "#{gray}\u251b"
    end

    # key sustain
    for c in (c1 + 1)...c2 do
      r[c] = "#{gray}\u2501"
    end

    # key press
    r[c1] = "#{gray}\u2517"
  end

  bg = note.black_key? ? "\e[48;5;232m\e[38;5;253m" : "\e[48;5;236m\e[38;5;250m"
  puts "\e[1m#{bg}#{number.to_s.rjust(3)} #{note.fancy_name.ljust(4)}\e[22m #{r.join}\e[0m"
end

# TODO: Maybe allow playing the MIDI file and showing a cursor?
# TODO: Allow specifying a page size in seconds for either playback or keyboard-interactive scrolling
