module MB
  module Sound
    module MIDI
      # Reads a MIDI file or live MIDI input as it plays in real time,
      # without audio: for tools that show events as they happen (the
      # bin/midi charts and event printer).  Files play through a FileSource,
      # live input through a LiveSource (:asap timing unless MIDI_TIMING says
      # otherwise), both read through a Stream, with the wall clock deciding
      # how far to read.
      #
      # Example:
      #     reader = MB::Sound::MIDI::RealtimeReader.new('spec/test_data/midi.mid')
      #     while (events = reader.read)
      #       events.each { |e| puts e }
      #     end
      class RealtimeReader
        # The Source being read (a FileSource or LiveSource).
        attr_reader :source

        # The Stream reading #source.
        attr_reader :stream

        # +input+ is a MIDI filename (.mid or .midi), part of a live MIDI
        # source's name to connect to, or nil for a port that other software
        # connects to (MIDI::Input.open_live prints where to connect).
        # #read checks for new events every +:poll+ seconds while waiting.
        def initialize(input = nil, poll: 0.002)
          if input && File.file?(input) && input.downcase.end_with?('.mid', '.midi')
            @source = FileSource.new(input)
          else
            @source = LiveSource.new(Input.open_live(input), timing: :asap)
            @owned_input = @source.input
          end

          @stream = Stream.new(@source)
          @reader = @stream.reader
          @poll = poll
          @start = nil
        end

        # True when reading a MIDI file.
        def file?
          @source.is_a?(FileSource)
        end

        # Seconds since the first #read.
        def elapsed
          @start ? MB::U.clock_now - @start : 0.0
        end

        # Waits until events arrive (or are due, for a file), returning every
        # event up to now (a frozen Array of MIDI::Events, with times in
        # seconds since the first read), or nil once a file has ended.
        # Realtime messages (clock, active sensing, ...) are left out unless
        # +:realtime+ is true.  With +:wait+ false, returns an empty Array
        # instead of waiting.
        def read(wait: true, realtime: false)
          @start ||= MB::U.clock_now

          loop do
            return nil if @reader.ended?

            now = Rational((elapsed * 1_000_000).round, 1_000_000)
            events = @reader.events(@reader.cursor, MB::M.max(now, @reader.cursor))
            events = events.reject { |e| e.type == :system && e.raw >= 0xf8 } unless realtime
            return events if !events.empty? || !wait

            sleep @poll
          end
        end

        # Closes live input opened by this reader.  Returns nil.
        def close
          return nil unless @owned_input

          @source.close
          @owned_input.close
          nil
        end
      end
    end
  end
end
