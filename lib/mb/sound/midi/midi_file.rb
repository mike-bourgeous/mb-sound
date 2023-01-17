require 'midilib'

module MB
  module Sound
    module MIDI
      # Reads from a MIDI file, returning MIDI data at the appropriate times
      # for each MIDI event.  Can be used by MB::Sound::MIDI::Manager to play a
      # MIDI file.
      #
      # This implements just enough compatibility with
      # MB::Sound::JackFFI::Input#read to work with MB::Sound::MIDI::Manager.
      #
      # This uses the midilib gem for MIDI parsing.  Due to limitations in the
      # midilib gem, this does not support MIDI files that change tempo.
      #
      # Also note that track names from midilib might include a trailing NUL
      # ("\x00") byte.  This happens with MIDI files exported from ACID Pro,
      # for example.
      #
      # Useful references:
      #  - https://www.cs.cmu.edu/~music/cmsip/readings/Standard-MIDI-file-format-updated.pdf
      class MIDIFile
        # A clock that may be passed to the constructor that returns whatever
        # value was last assigned to #clock_now=.
        class ConstantClock
          # The constant value assigned to the clock.
          attr_reader :clock_now

          # Initializes a constant-value clock, with an optional initial time.
          def initialize(time = 0)
            @clock_now = time.to_f
          end

          # Sets the value to be returned for the current time.
          def clock_now=(time)
            @clock_now = time.to_f
          end
        end

        # The index of the next MIDI event to read, when its timestamp has
        # elapsed.
        attr_reader :index

        # The current plauback time within the MIDI file.  See #seek.
        attr_reader :elapsed

        # The number of events that could be read.
        attr_reader :count

        # The *approximate* duration of the MIDI file, in seconds.  This is the
        # maximum duration of all tracks, not just the track selected for
        # reading.
        #
        # This is just the time of the last event in the file, and doesn't
        # account for sounds' decay times.
        attr_reader :duration

        # The MIDI filename that was given to the constructor.
        attr_reader :filename

        # The sequence object from the midilib gem that contains MIDI data from the file.
        attr_reader :seq

        # The full list of events that will be returned over time by #read.
        attr_reader :events

        # Reads MIDI data from the given +filename+.  Call #read repeatedly to
        # receive MIDI events based on elapsed time.
        #
        # The +:clock+ parameter accepts any object that responds to
        # :clock_now.  This allows playing a MIDI file at a speed other than
        # monotonic real time.
        #
        # If +:merge_tracks+ is false, then events will not be merged across
        # tracks, and #read will only return events from track +:read_track+.
        def initialize(filename, clock: MB::U, merge_tracks: true, read_track: 0)
          raise "Clock must respond to :clock_now" unless clock.respond_to?(:clock_now)
          @clock = clock

          @filename = filename

          @seq = ::MIDI::Sequence.new
          File.open(filename, 'rb') do |f|
            @seq.read(f)
          end

          track = @seq.tracks[read_track].dup

          if merge_tracks
            @seq.tracks[0..-1].each_with_index do |t, idx|
              next if idx == read_track
              track.merge(t.events)
            end
          end

          @duration = @seq.pulses_to_seconds(@seq.tracks.map(&:events).map(&:last).map(&:time_from_start).max)

          @events = track.events.freeze
          @count = @events.count

          @index = 0
          @elapsed = 0
        end

        # Returns information about each track in the underlying midilib
        # sequence object (see #seq).
        def tracks
          @track_info ||= seq.tracks.map.with_index { |t, idx|
            {
              index: idx,
              name: t.name.gsub("\x00", ''),
              instrument: t.instrument,
              channel_mask: t.channels_used.to_s(2).chars.map.with_index { |v, idx| v == '1' ? idx : nil }.compact,
              event_channels: t.events.select { |v| v.is_a?(::MIDI::ChannelEvent) }.map(&:channel).uniq,
              channel: t.events.group_by { |v| v.is_a?(::MIDI::ChannelEvent) ? v.channel : nil }.max_by { |ch, events| events.count }[0],
              num_events: t.events.length,
              num_notes: t.events.select { |v| v.is_a?(::MIDI::NoteEvent) }.length,
              duration: @seq.pulses_to_seconds(t.events.last.time_from_start)
            }
          }
        end

        # Returns an Array of channels (0-based) used in the MIDI file.
        def channels
          @channel_list ||= tracks.flat_map { |t| t[:event_channels] }.sort.uniq
        end

        # Returns the track information for the track having the most notes or
        # events on the given channel, breaking ties using the highest track
        # index.
        #
        # This is useful for finding the track name given a channel number, for
        # example.  This works best on MIDI files that use a separate track for
        # each MIDI channel.
        def track_for_channel(channel)
          tracks.select { |t|
            t[:channel] == channel
          }.max_by { |t|
            [t[:num_notes], t[:num_events], t[:index]]
          }
        end

        # Returns true if there are no more events available to #read.
        def empty?
          @events.empty? || @index >= @events.length
        end

        # Returns the index of the first event with a timestamp greater than or
        # equal to the given number of seconds.  If +time+ is after the last
        # event, returns the number of events (corresponding to an index just
        # past the end of the list of events).
        def find_index(time)
          @events.bsearch_index { |ev| @seq.pulses_to_seconds(ev.time_from_start) >= time } || @events.length
        end

        # Returns a fractional index based on the given number of seconds,
        # where the fractional part represents the relative distance between
        # the given time and the previous and next events' timestamps.
        #
        # If the given +time+ is before or after all events, then the index
        # will be extrapolated at a rate of 4 events per second.  This allows
        # the fractional index to be used to scroll an event list before or
        # after playback in a plausible way.
        #
        # If +time+ is nil, then the current #elapsed playback time is used.
        def fractional_index(time = nil)
          time ||= @elapsed

          idx1 = find_index(time) - 1
          idx1 = 0 if idx1 < 0

          idx2 = idx1 + 1

          if idx2 >= @events.length
            idx1 = @events.length - 2
            idx2 = @events.length - 1
          end

          ts1 = @events[idx1]&.time_from_start
          ts1 ||= 0
          time1 = @seq.pulses_to_seconds(ts1)

          ts2 = @events[idx2]&.time_from_start
          ts2 ||= ts1
          time2 = @seq.pulses_to_seconds(ts2)

          if time < time1
            # Extrapolating before start
            idx1 + 0.25 * (time - time1)
          elsif time > time2
            # Extrapolating after end
            idx2 + 0.25 * (time - time2)
          elsif time1 == time2
            # Both events have the same timestamp when not extrapolating.  This
            # must mean time is equal to one of the events.  Otherwise this
            # should not be possible with binary search.
            idx1.to_f
          else
            idx1 + (time - time1).to_f / (time2 - time1)
          end
        end

        # Sets the current time used by #read to +time+.  Negative values delay
        # the start of playback.
        def seek(time)
          @elasped = time.to_f
          @start = @clock.clock_now - @elapsed
          @index = find_index(time)
        end

        # Returns events from the MIDI file whose timestamps are less than or
        # equal to the elapsed time since this method was first called.
        #
        # Returns an Array containing a single String, or nil if there are no
        # events left to read.
        #
        # If :blocking is true, then this method will sleep to keep time with
        # the MIDI file.  This will not work correctly if a non-realtime clock
        # was given to the constructor, so in that case, set :blocking to false
        # and use a different means of keeping time.
        def read(blocking: true)
          return nil if @events.empty? || @index >= @events.length

          @start ||= @clock.clock_now

          current_events = ''

          if blocking
            # Sleep until the scheduled time of the next event
            ev = @events[@index]
            delay = @clock.clock_now - (@start + @seq.pulses_to_seconds(ev.time_from_start))
            sleep delay if delay > 0
          end

          now = @clock.clock_now
          @elapsed = now - @start

          while @index < @events.length
            ev = @events[@index]

            # Stop the loop when we see an event from the future
            t = @seq.pulses_to_seconds(ev.time_from_start)
            break if t > @elapsed

            unless ev.is_a?(::MIDI::MetaEvent)
              current_events << ev.data_as_bytes.pack('C*')
            end

            @index += 1
          end

          if current_events.empty?
            [nil]
          else
            [current_events]
          end
        end
      end
    end
  end
end
