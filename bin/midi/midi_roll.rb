#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby
# Displays an extremely simple piano roll style view of a MIDI file.
#
# Usage: $0 [options] midi_file.mid
#
# Example to scroll through a MIDI file:
#     for f in `seq 0 1 60`; do $0 -s $f -d 20 song.mid ; done
#
# -e and -d are mutually exclusive.

require 'bundler/setup'

require 'mb-sound'

MB::Sound.script(
  args: 0..1,
  rows: [MB::U.height - 2, '-r', 'The number of notes to display (default: terminal height - 2)', 1..],
  columns: [MB::U.width, '-c', 'The number of columns to use (default: terminal width)', 11..],
  min_note: [nil, '-n', ->(n) { MB::Sound::Note.new(n) }, 'The lowest note to display, as a number or name (default: centered around the median note)'],
  start_time: [nil, Float, '-s', 'Offset within the song to start displaying notes, in seconds (default 0)'],
  end_time: [nil, Float, '-e', 'Offset within the song to stop displaying notes, in seconds (default: end of song)'],
  duration: [nil, Float, '-d', 'Duration to display after the start time, in seconds (default: end of song)'],
  channel: [-1, 'MIDI channel to display (1..16, or -1 for all channels)'],
) { |(filename), p|
  # Option names as in the OptionParser version of this script
  options = p.to_h.transform_keys { |k| k.to_s.tr('_', '-').to_sym }

  if options[:'end-time'] && options[:duration]
    abort 'Specify one of --end-time or --duration, or neither, but not both'
  end

  channel = options[:channel] - 1
  channel = nil if channel == -2
  abort 'MIDI channel must be an integer from 1 to 16, or -1' if channel && !(0..15).cover?(channel)
  channel_description = channel.nil? ? 'all channels' : "channel #{channel + 1}"

  abort 'Specify a MIDI file to display (see --help)' unless filename
  abort "MIDI file #{filename.inspect} not found" unless File.readable?(filename)
  f = MB::Sound::MIDI::MIDIFile.new(filename)

  notes = f.notes.select { |n| channel.nil? || n[:channel] == channel }.group_by { |n| n[:number] }

  options[:'start-time'] ||= 0.0
  options[:'end-time'] ||= options[:'start-time'] + options[:duration] if options[:duration]
  options[:'end-time'] ||= f.duration
  time_range = options[:'start-time']..options[:'end-time']
  raise "Start time #{options[:'start-time']} must be before end time #{options[:'end-time']}" if options[:'start-time'] > options[:'end-time']

  cols = options[:columns] - 10
  cols = 1 if cols < 1
  col_range = 0..cols

  # Determine note offset based on note stats and window size
  _min, mid, _max = f.note_stats(channel: channel)
  min_note = options[:'min-note']&.number || mid - options[:rows] / 2
  min_note = 0 if min_note < 0
  max_note = min_note + options[:rows] - 1
  max_note = 127 if max_note > 127

  # TODO: Sometimes the median shouldn't be in the center, so if we have room to scroll, let's scroll
  # Probably something like this:
  # if all notes are within range, do nothing
  # if see how many notes we can get away with scrolling down

  puts "\e[1;33;44m#{f.filename} -- #{time_range}/#{f.duration.round(2)}s \e[37m(#{channel_description})\e[K\e[0m"

  ruler = [' '] * (cols + 1) # FIXME: why is a note sometimes going beyond the end forcing adding 1?
  ruler_step = 30
  ruler_start = MB::M.round_to(time_range.begin, ruler_step)
  ruler_end = MB::M.round_to(time_range.end, ruler_step)
  for t in (ruler_start..ruler_end).step(30) do # TODO: scale ruler based on duration
    c = MB::M.scale(t, time_range, col_range)
    next unless col_range.cover?(c)
    ruler[c] = "\e[38;5;237m\u250a"
  end

  for number in (max_note..min_note).step(-1) do
    r = ruler.dup
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
      channel_hue = MB::M.scale(n[:channel] * 11, 0..15, 0.333333..1.333333)
      color = MB::U.hsv(channel_hue, (n[:channel] % 3) * 0.2 + 0.4, velocity_value)

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
}
