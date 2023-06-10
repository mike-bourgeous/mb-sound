#!/usr/bin/env ruby
# Displays an extremely simple piano roll style view of a MIDI file.
#
# Usage: $0 [options] midi_file.mid
#
# Example to scroll through a MIDI file:
#     for f in `seq 0 1 60`; do bin/midi_roll.rb -s $f -e $((f+20)) song.mid ; done

require 'bundler/setup'

require 'optparse'

require 'mb-sound'

options = {
  rows: MB::U.height - 2,
  columns: MB::U.width,
}
OptionParser.new { |p|
  p.banner = "Usage: \e[1m#{$0}\e[0m [options] midi_file\n-e and -d are mutually exclusive"

  p.accept(MB::Sound::Note) do |note|
    MB::Sound::Note.new(note)
  end

  p.on('-r', '--rows ROWS', Integer, 'The number of notes to display (defaults to terminal height - 2)')
  p.on('-c', '--columns COLUMNS', Integer, 'The number of columns to use (defaults to terminal width)')
  p.on('-n', '--min-note NOTE', MB::Sound::Note, 'The lowest note to display (number or name) (defaults to centering around median note)')
  p.on('-s', '--start-time SECONDS', Float, 'Offset within song to start displaying notes, in seconds (default is 0)')
  p.on('-e', '--end-time SECONDS', Float, 'Offset within song to stop displaying notes, in seconds (default is end of song)')
  p.on('-d', '--duration SECONDS', Float, 'Duration to display after start time, in seconds (default is end of song)')
}.parse!(into: options)

if options[:'end-time'] && options[:duration]
  raise 'Specify one of --end-time or --duration, or neither, but not both'
end

filename = ARGV[0]
raise 'Specify a MIDI file to display' unless filename
raise "MIDI file #{filename.inspect} not found" unless File.readable?(filename)
f = MB::Sound::MIDI::MIDIFile.new(filename)

options[:'start-time'] ||= 0.0
options[:'end-time'] ||= options[:'start-time'] + options[:duration] if options[:duration]
options[:'end-time'] ||= f.duration
time_range = options[:'start-time']..options[:'end-time']
raise "Start time #{options[:'start-time']} must be before end time #{options[:'end-time']}" if options[:'start-time'] > options[:'end-time']

cols = options[:columns] - 10
col_range = 0..cols

notes = f.notes.group_by { |n| n[:number] }

# Determine note offset based on note stats and window size
_min, mid, _max = f.note_stats
min_note = options[:'min-note']&.number || mid - options[:rows] / 2
max_note = min_note + options[:rows] - 1

puts "\e[1;33;44m#{f.filename} -- #{time_range}/#{f.duration.round(2)}s\e[K\e[0m"

for number in (max_note..min_note).step(-1) do
  r = [' '] * (cols + 1) # FIXME: why is a note sometimes going beyond the end?
  note = MB::Sound::Note.new(number)

  notes[number]&.each do |n|
    next unless time_range.cover?(n[:on_time]) ||
      time_range.cover?(n[:off_time]) ||
      time_range.cover?(n[:sustain_time]) ||
      (n[:on_time] <= time_range.begin && n[:sustain_time] >= time_range.end)

    c1 = MB::M.scale(n[:on_time], time_range, col_range).floor
    c2 = MB::M.scale(n[:off_time], time_range, col_range).floor
    c3 = MB::M.scale(n[:sustain_time], time_range, col_range).floor

    c1 = -1 if c1 < -1
    c1 = cols + 1 if c1 > cols + 1
    c2 = -1 if c2 < -1
    c2 = cols + 1 if c2 > cols + 1
    c3 = -1 if c3 < -1
    c3 = cols + 1 if c3 > cols + 1

    velocity_value = MB::M.scale(n[:on_velocity], 0..127, 0.3..0.8)
    channel_hue = MB::M.scale(n[:channel], 0..15, 0.333333..1.333333)
    color = MB::U.hsv(channel_hue, 0.5, velocity_value)

    # pedal sustain
    for c in (c2 + 1)..c3 do
      next unless col_range.cover?(c)
      r[c] = "#{color}\u254c"
    end

    # key release
    if col_range.cover?(c2)
      if n[:sustain_time] > n[:off_time]
        r[c2] = "#{color}\u2539"
      else
        r[c2] = "#{color}\u251b"
      end
    end

    # key sustain
    for c in (c1 + 1)...c2 do
      next unless col_range.cover?(c)
      r[c] = "#{color}\u2501"
    end

    # key press
    if col_range.cover?(c1)
      r[c1] = "#{color}\u2517"
    end
  end

  bg = note.black_key? ? "\e[48;5;232m\e[38;5;253m" : "\e[48;5;236m\e[38;5;250m"
  puts "\e[1m#{bg}#{number.to_s.rjust(3)} #{note.fancy_name.ljust(4)}\e[22m #{r.join}\e[0m"
end

# TODO: Maybe allow playing the MIDI file and showing a cursor?
# TODO: Implement paged playback based on time range and/or keyboard-interactive scrolling?
