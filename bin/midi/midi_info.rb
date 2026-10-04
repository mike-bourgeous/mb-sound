#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Displays number of events from each channel, and other info about a MIDI
# file.
#
# Usage: $0 midi_file.mid

require 'bundler/setup'

require 'mb-sound'

NAME_MAP = {
  index: '#',
  name: 'Name',
  instrument: 'Inst.',
  channel_mask: 'Ch. mask',
  event_channels: 'Event ch.',
  channel: 'Ch.',
  num_events: 'Events',
  num_notes: 'Notes',
  duration: 'Duration',
  min_note: "Min \u2669",
  mid_note: "Med \u2669",
  max_note: "Max \u2669",
}.freeze

MB::Sound.script(args: 1) { |(filename)|
  f = MB::Sound::MIDI::MIDIFile.new(filename, merge_tracks: false)

  title = f.seq.name

  track_info = f.tracks.reduce({}) { |h, t|
    t.each do |k, v|
      kname = NAME_MAP[k] || k.to_s
      h[kname] ||= []
      h[kname] << v
    end

    h
  }

  MB::U.headline("#{File.basename(f.filename)}: \e[1m#{title}\e[0m")
  puts
  MB::U.table(track_info, variable_width: true)
}
