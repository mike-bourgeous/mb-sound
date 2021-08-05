require 'midilib'

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
        def initialize(filename)
          @seq = ::MIDI::Sequence.new
          File.open(filename, 'rb') do |f|
            @seq.read(f)
          end

          @track0 = @seq.tracks[0]
          @seq.tracks[1..-1].each do |t|
            @track0.merge(t.events)
          end
          @events = @track0.events

          @index = 0
        end

        # Returns events from the MIDI file whose timestamps are less than or
        # equal to the elapsed time since this method was first called.
        #
        # Returns an Array containing a single String, or nil if there are no
        # events left to read.
        def read(blocking: true)
          return nil if @events.empty? || @index >= @events.length

          @start ||= MB::U.clock_now

          current_events = ''

          if blocking
            # Sleep until the scheduled time of the next event
            ev = @events[@index]
            delay = MB::U.clock_now - (@start + @seq.pulses_to_seconds(ev.time_from_start))
            sleep delay if delay > 0
          end

          now = MB::U.clock_now
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
