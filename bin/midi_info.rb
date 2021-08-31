#!/usr/bin/env ruby
# Displays number of events from each channel, and other info about a MIDI
# file.
#
# Usage: $0 midi_file.mid

require 'bundler/setup'

require 'mb-sound'

if ARGV.include?('--help') || ARGV.length != 1
  puts MB::U.read_header_comment.join.gsub('$0', $0)
  exit 1
end

f = MB::Sound::MIDI::MIDIFile.new(ARGV[0], merge_tracks: false)

title = f.seq.name

track_info = f.seq.tracks.map.with_index { |t, idx|
  {
    '#' => idx,
    'Name' => t.name.gsub("\x00", ''),
    'Inst.' => t.instrument,
    'Ch. mask' => t.channels_used.to_s(2).chars.map.with_index { |v, idx| v == '1' ? idx : nil }.compact,
    'Event ch.' => t.events.select { |v| v.is_a?(::MIDI::ChannelEvent) }.map(&:channel).uniq,
    'Events' => t.events.length,
    'Notes' => t.events.select { |v| v.is_a?(::MIDI::NoteEvent) }.length,
  }
}.reduce({}) { |h, t|
  t.each do |k, v|
    h[k] ||= []
    h[k] << v
  end

  h
}

msg = "#{File.basename(f.filename)}: \e[1m#{title}\e[0m"
len = MB::U.remove_ansi(msg).length
puts '', msg, '-' * len, ''

puts MB::U.table(track_info, variable_width: true)
