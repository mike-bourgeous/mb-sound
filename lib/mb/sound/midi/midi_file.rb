require 'midilib'

# Patch midilib for Ruby 3.0 because the Ruby 3.0 fix has not been released to
# rubygems.org yet, and the midilib Git repo is not directly installable as a
# gem source due to the spec living inside the Rakefile instead of a .gemspec
# file.
#
# Array#[] on a subclass of Array returns the subclass on 2.7, but Array on 3.
#
# See https://github.com/jimm/midilib/commit/a8d16566f5eebfab0e53b9a0d609d11f7fd9b1c7#diff-67c4a811efdcb8cdca6a5131315ed1de1f5a9b30017dbf6b1171c60840f54848

if RUBY_VERSION >= '3.0'
  class ::MIDI::Array
    alias_method :old_split_mbsound, :split
    def split
      old_split_mbsound.map { |a| ::MIDI::Array.new(a) }
    end
  end
end

module MB
  module Sound
    module MIDI
      # Reads from a MIDI file, returning MIDI data at the appropriate times
      # for each MIDI event.  Can be ysed by MB::Sound::MIDI::Manager to play a
      # MIDI file.
      #
      # This implements just enough compatibility with
      # MB::Sound::JackFFI::Input#read to work with MB::Sound::MIDI::Manager.
      #
      # Due to limitations in the midilib gem, this does not support MIDI files
      # that change tempo.
      class MIDIFile
        # The index of the next MIDI event to read, when its timestamp has
        # elapsed.
        attr_reader :index

        # The MIDI filename that was given to the constructor.
        attr_reader :filename

        # The sequence object from the midilib gem that contains MIDI data from the file.
        attr_reader :seq

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

          track = @seq.tracks[read_track]

          if merge_tracks
            @seq.tracks[0..-1].each_with_index do |t, idx|
              next if idx == read_track
              track.merge(t.events)
            end
          end

          @events = track.events

          @index = 0
        end

        # Returns true if there are no more events available to #read.
        def empty?
          @events.empty? || @index >= @events.length
        end

        # Sets the current time used by #read to +time+.  Negative values delay
        # the start of playback.
        def seek(time)
          @start = @clock.clock_now - time
          @index = @events.bsearch_index { |ev| @seq.pulses_to_seconds(ev.time_from_start) >= time } || @events.length
        end

        # Returns events from the MIDI file whose timestamps are less than or
        # equal to the elapsed time since this method was first called.
        #
        # Returns an Array containing a single String, or nil if there are no
        # events left to read.
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
          elapsed = now - @start

          while @index < @events.length
            ev = @events[@index]

            # Stop the loop when we see an event from the future
            t = @seq.pulses_to_seconds(ev.time_from_start)
            break if t > elapsed

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
