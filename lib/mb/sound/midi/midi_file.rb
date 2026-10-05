require 'midilib'

module MB
  module Sound
    module MIDI
      # Parses a MIDI file with the midilib gem, merging its tracks into one
      # event list (see #events, read by FileSource, which plays files), and
      # describes its tracks (#tracks, used by bin/midi/midi_info.rb).  Note
      # lists with pedal times come from the events as played
      # (FileSource#notes, MIDI::NoteList).
      #
      # Playback goes through MIDI::FileSource (no clocks; see GH #67).  Due
      # to limitations in the midilib gem, times here use one tempo for the
      # whole file.
      #
      # Also note that track names from midilib might include a trailing NUL
      # ("\x00") byte.  This happens with MIDI files exported from ACID Pro,
      # for example.
      #
      # Useful references:
      #  - https://www.cs.cmu.edu/~music/cmsip/readings/Standard-MIDI-file-format-updated.pdf
      class MIDIFile
        # How long a Synth (and Notes nodes) keep playing silence after a MIDI
        # file ends, for sounds to decay in players that don't detect the end
        # of the tail themselves.  The script runner stops sooner, once the
        # output has been quiet for a second (see
        # ScriptRunner#stop_after_ringdown); this is longer than its
        # 10-second tail limit and fade so that it never cuts the runner off.
        TAIL_SECONDS = 11

        # The MIDI filename that was given to the constructor.
        attr_reader :filename

        # The number of events in #events.
        attr_reader :count

        # The *approximate* duration of the MIDI file, in seconds.  This is the
        # maximum duration of all tracks, not just the track selected for
        # reading.
        #
        # This is just the time of the last event in the file, and doesn't
        # account for sounds' decay times.
        attr_reader :duration

        # The time in seconds of the last channel (non-meta) event in the file:
        # when the music ends, not counting sounds' decay or trailing meta
        # events like the end of a track.
        attr_reader :music_end

        # The sequence object from the midilib gem that contains MIDI data from the file.
        attr_reader :seq

        # The merged list of midilib events (or the #read_track's events
        # alone without track merging), including meta events.
        attr_reader :events

        # The track index given to the constructor.
        attr_reader :read_track

        # Reads MIDI data from the given +filename+.
        #
        # If +:merge_tracks+ is false, then events will not be merged across
        # tracks, and #events will only have events from track +:read_track+.
        def initialize(filename, merge_tracks: true, read_track: 0)
          @filename = filename

          @seq = ::MIDI::Sequence.new
          File.open(filename, 'rb') do |f|
            @seq.read(f)
          end

          @read_track = read_track
          track = @seq.tracks[read_track].dup

          if merge_tracks
            @seq.tracks[0..-1].each_with_index do |t, idx|
              next if idx == read_track
              track.merge(t.events)
            end
          end

          last_event_pulses = @seq.tracks.map(&:events).map(&:last).map(&:time_from_start).max
          @duration = pulse_time(last_event_pulses)

          channel_events = @seq.tracks.flat_map(&:events).reject { |e| e.is_a?(::MIDI::MetaEvent) }
          @music_end = channel_events.empty? ? 0 : pulse_time(channel_events.map(&:time_from_start).max)

          @events = track.events.freeze
          @count = @events.count
        end

        # Returns information about each track in the underlying midilib
        # sequence object (see #seq).
        def tracks
          @track_info ||= @seq.tracks.map.with_index { |t, idx|
            stats = track_note_stats(idx)

            {
              index: idx,
              name: t.name.gsub("\x00", ''),
              instrument: t.instrument,
              channel_mask: t.channels_used.to_s(2).chars.map.with_index { |v, idx| v == '1' ? idx : nil }.compact,
              event_channels: t.events.select { |v| v.is_a?(::MIDI::ChannelEvent) }.map(&:channel).uniq,
              channel: t.events.group_by { |v| v.is_a?(::MIDI::ChannelEvent) ? v.channel : nil }.max_by { |ch, events| events.count }[0],
              num_events: t.events.length,
              num_notes: t.events.select { |v| v.is_a?(::MIDI::NoteOn) }.length,
              min_note: stats[0],
              mid_note: stats[1],
              max_note: stats[2],
              duration: pulse_time(t.events.last.time_from_start),
            }
          }
        end

        # Returns the minimum, median, and maximum note number of the note-ons
        # in the +index+th track, or 64 for each if there are no notes in the
        # track (see MIDI::NoteList.stats).
        def track_note_stats(index)
          raise "Track index #{index} out of range 0...#{@seq.tracks.length}" unless (0...@seq.tracks.length).cover?(index)

          @track_note_stats ||= {}
          @track_note_stats[index] ||= NoteList.stats(
            @seq.tracks[index].events.select { |e| e.is_a?(::MIDI::NoteOn) && e.velocity > 0 }.map(&:note)
          )
        end

        # Returns true if the file has no events (in the #read_track, without
        # track merging).
        def empty?
          @events.empty?
        end

        private

        # Calculates the time in seconds at the given number of elapsed MIDI
        # pulses (specified by the file, commonly 960 pulses per quarter note).
        # Does not handle variable tempo MIDI files.
        def pulse_time(pulses)
          @seq.pulses_to_seconds(pulses)
        end
      end
    end
  end
end
