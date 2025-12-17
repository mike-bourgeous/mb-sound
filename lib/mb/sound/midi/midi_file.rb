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
        # value was last assigned to #clock_now=.  Useful for testing.
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

        # The MIDI filename that was given to the constructor.
        attr_reader :filename

        # The index of the next MIDI event to read, when its timestamp has
        # elapsed.
        attr_reader :index

        # The current playback time (in seconds) within the MIDI file.  See
        # #seek.
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

        # The sequence object from the midilib gem that contains MIDI data from the file.
        attr_reader :seq

        # The full list of events that will be returned over time by #read.
        attr_reader :events

        # The track index given to the constructor.
        attr_reader :read_track

        # Reads MIDI data from the given +filename+.  Call #read repeatedly to
        # receive MIDI events based on elapsed time.
        #
        # The +:clock+ parameter accepts any object that responds to
        # :clock_now.  This allows playing a MIDI file at a speed other than
        # monotonic real time.  Additionally the +:speed+ parameter allows
        # specifying a playback speed ratio.
        #
        # If +:merge_tracks+ is false, then events will not be merged across
        # tracks, and #read will only return events from track +:read_track+.
        def initialize(filename, clock: MB::U, merge_tracks: true, read_track: 0, speed: 1.0)
          self.clock = clock

          raise 'Speed must be greater than zero' unless speed > 0
          @speed = 1.0 / speed

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
          @extra_duration = 5

          @events = track.events.freeze
          @count = @events.count

          @index = 0
          @elapsed = 0

          @notes = nil
          @note_stats = nil
          @note_channel_stats = []
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

        # Returns all notes from track number +index+ (0-based, though in
        # multi-track files the notes usually start in track 1), regardless of
        # what track was specified as #read_track in the constructor or whether
        # track merging was enabled.
        def track_notes(index)
          raise "Track index #{index} out of range 0...#{@seq.tracks.length}" unless (0...@seq.tracks.length).cover?(index)

          @track_notes ||= {}
          @track_notes[index] ||= event_notes(@seq.tracks[index].events)
        end

        # Returns an Array containing start and end times for all notes from
        # the #read_track (or all tracks if track merging was specified),
        # sorted by note start time.  These times do not account for variable
        # tempo.
        #
        #     {
        #       # The note channel (0-based)
        #       channel: 0..15,
        #
        #       # The note number
        #       note: 0..127,
        #
        #       # The note on and note off velocities
        #       on_velocity: 0..127,
        #       off_velocity: 0..127,
        #
        #       # The time when the note begins, in seconds, from the start of the file.
        #       on_time: Float,
        #
        #       # The time when the note ends, in seconds, from the start of the file.
        #       off_time: Float,
        #
        #       # If the sustain pedal was held when the note was released,
        #       # then this is the time when the sustain pedal was released
        #       # after the note was released.
        #       sustain_time: Float,
        #     }
        def notes
          @notes ||= event_notes(@events)
        end

        # Returns the minimum, median, and maximum note number used in the
        # +index+th track, or 64 for each if there are no notes in the track
        def track_note_stats(index)
          raise "Track index #{index} out of range 0...#{@seq.tracks.length}" unless (0...@seq.tracks.length).cover?(index)

          @track_note_stats ||= {}
          @track_note_stats[index] ||= note_list_stats(track_notes(index))
        end

        # Returns the minimum, median, and maximum note number used in the
        # #read_track, or 64 for each if there are no notes in the MIDI file.
        #
        # This may be useful for setting an initial scroll position of a piano
        # roll display, for example.
        #
        # If +:channel+ is not nil, then only stats for notes on the given
        # channel are returned.
        def note_stats(channel: nil)
          if channel
            @note_channel_stats[channel] ||= note_list_stats(notes, channel: channel)
          else
            @note_stats ||= note_list_stats(notes)
          end
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

        # Returns true if the current time is 5 seconds past the last event in
        # the MIDI file.
        #
        # TODO: allow specifying the amount of extra time, or find some way to
        # sync with envelopes/delays/etc. to allow ringdown
        def done?
          return false unless @start
          now = @clock.clock_now
          @elapsed = now - @start
          @elapsed > @duration + @extra_duration
        end

        # Returns the index of the first event with a timestamp greater than or
        # equal to the given number of seconds.  If +time+ is after the last
        # event, returns the number of events (corresponding to an index just
        # past the end of the list of events).
        def find_index(time)
          @events.bsearch_index { |ev| pulse_time(ev.time_from_start) >= time } || @events.length
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
          time1 = pulse_time(ts1)

          ts2 = @events[idx2]&.time_from_start
          ts2 ||= ts1
          time2 = pulse_time(ts2)

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

        # Changes the clock used by this MIDI file for tracking time.
        def clock=(clock)
          raise "Clock must respond to :clock_now" unless clock.respond_to?(:clock_now)
          @clock = clock
          @start = @clock.clock_now - @elapsed if @start
        end

        # Sets the current time used by #read to +time+ (in seconds).  Negative
        # values delay the start of playback.
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
            delay = @clock.clock_now - (@start + pulse_time(ev.time_from_start))
            sleep delay if delay > 0
          end

          now = @clock.clock_now
          @elapsed = now - @start

          while @index < @events.length
            ev = @events[@index]

            # Stop the loop when we see an event from the future
            t = pulse_time(ev.time_from_start)
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

        private

        # Returns an array of all notes from the given MIDILib event list,
        # sorted by note start time.  This probably does not account for SMPTE
        # track offset (this is untested).
        def event_notes(events)
          channels = 16.times.map {
            {
              sustain: false,
              active_notes: {},
            }
          }
          note_list = []

          events.each do |e|
            next unless e.respond_to?(:channel)

            event_time = pulse_time(e.time_from_start)
            ch_info = channels[e.channel]
            ch_notes = ch_info[:active_notes]

            # TODO: This code has some similarity to code in the MIDI manager
            # and VoicePool; see if that can be deduplicated.
            case e
            when ::MIDI::NoteOn
              # Treat repeated note on events as a note off followed by note on
              # (Alternatives could include counting the number of note ons,
              # and waiting for that number of note offs)
              existing_note = ch_notes[e.note]
              if existing_note
                existing_note[:off_velocity] ||= existing_note[:on_velocity]
                existing_note[:off_time] ||= event_time
                existing_note[:sustain_time] ||= event_time
                note_list << existing_note
              end

              ch_notes[e.note] = {
                channel: e.channel,
                number: e.note,
                on_velocity: e.velocity,
                off_velocity: nil,
                on_time: event_time,
                off_time: nil,
                sustain_time: nil,
              }

            when ::MIDI::NoteOff
              existing_note = ch_notes[e.note]
              if existing_note
                # Using ||= in case of repeated note off events during a sustain
                existing_note[:off_velocity] ||= e.velocity
                existing_note[:off_time] ||= event_time

                unless ch_info[:sustain]
                  # If the sustain pedal isn't pressed, move the note into the completed note list
                  existing_note[:sustain_time] ||= event_time
                  note_list << existing_note
                  ch_notes.delete(e.note)
                end
              end

            when ::MIDI::Controller
              if e.controller == 64 # sustain pedal is CC 64
                # TODO: what about half/variable pedal?
                # TODO: what about sostenuto?
                if e.value >= 64
                  ch_info[:sustain] = true
                else
                  ch_info[:sustain] = false

                  ch_notes.select! { |_, n|
                    if n[:off_time]
                      # If the note has an off time, it was sustained.  Release it.
                      n[:sustain_time] = event_time
                      note_list << n

                      false
                    else
                      # Keep notes without an off time
                      true
                    end
                  }
                end
              end
            end
          end

          # If any notes weren't released at the end, set their release times
          # to the MIDI file duration
          channels.each do |ch_info|
            ch_info[:active_notes].each do |n|
              n[:off_velocity] ||= n[:on_velocity]
              n[:off_time] ||= @duration
              n[:sustain_time] ||= @duration
              note_list << n
            end
          end

          notes = note_list.sort_by! { |n| [n[:on_time], n[:channel], n[:number], n[:off_time], n[:velocity]] }

          notes
        end

        # Returns min, median, and max note numbers from the given list of
        # notes, or 64 for each value if the list is empty.  Filters to notes
        # on the given +:channel+ (0-based) if +:channel+ is not nil.
        def note_list_stats(notes, channel: nil)
          numbers = notes.select { |n| channel.nil? || n[:channel] == channel }.map { |n| n[:number] }.sort

          [
            numbers[0] || 64,
            numbers[numbers.length / 2] || 64,
            numbers[-1] || 64,
          ]
        end

        # Calculates the time in seconds at the given number of elapsed MIDI
        # pulses (specified by the file, commonly 960 pulses per quarter note).
        # Does not handle variable tempo MIDI files.
        def pulse_time(pulses)
          @seq.pulses_to_seconds(pulses) * @speed
        end
      end
    end
  end
end
