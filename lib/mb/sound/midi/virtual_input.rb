module MB
  module Sound
    module MIDI
      # A MIDI input that Ruby code plays into: anything (the terminal UI's
      # virtual keyboard, a test) calls #send_bytes (or #note_on, #note_off,
      # #cc) from any thread, and a MIDI::LiveSource reads the messages with
      # #read_raw like RtMidi's, each timed by when it was sent (the time
      # between messages kept, the whole placed a constant latency after it
      # arrived; see LiveSource's :exact timing).  So events typed on a
      # computer keyboard take the same path as a hardware keyboard's.
      #
      #     vin = MIDI::VirtualInput.new
      #     stream = MIDI::Stream.new(MIDI::LiveSource.new(vin, output: Session.default.output))
      #     Session.current.midi_in.add_source(stream)
      #     vin.note_on(60, 0.8)
      #     vin.note_off(60)
      class VirtualInput
        # The most messages waiting between reads (older ones are dropped).
        QUEUE_LIMIT = 4096

        attr_reader :name

        # Messages dropped because nothing read them in time.
        attr_reader :dropped

        # +clock+ gives monotonic seconds (for specs).
        def initialize(name = 'virtual', clock: nil)
          @name = name
          @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
          @lock = Mutex.new
          @queue = []
          @last = nil
          @closed = false
          @dropped = 0
        end

        # Sends one or more MIDI messages (a String or Array of bytes), sent
        # at +time+ (monotonic seconds, default now).  Returns self.
        def send_bytes(bytes, time: @clock.call)
          bytes = bytes.pack('C*') if bytes.is_a?(Array)
          @lock.synchronize do
            next if @closed
            @queue << [time, bytes.b.freeze]
            if @queue.length > QUEUE_LIMIT
              @queue.shift
              @dropped += 1
            end
          end
          self
        end

        # Sends a note-on (+velocity+ 0..1; 0 is still a note-on with
        # velocity 1, as Event.note_on).
        def note_on(note, velocity = 1.0, channel: 0, time: @clock.call)
          send_bytes(Event.note_on(note, velocity, channel: channel).bytes, time: time)
        end

        # Sends a note-off.
        def note_off(note, velocity = Event::DEFAULT_RELEASE / 127.0, channel: 0, time: @clock.call)
          send_bytes(Event.note_off(note, velocity, channel: channel).bytes, time: time)
        end

        # Sends a control change (+value+ 0..1).
        def cc(index, value, channel: 0, time: @clock.call)
          send_bytes(Event.cc(index, value, channel: channel).bytes, time: time)
        end

        # The messages sent since the last read as [[delta, bytes], ...]:
        # each message's time in seconds after the previous one (0 for the
        # first), as RtMidi gives them.  Never waits.
        def read_raw
          @lock.synchronize do
            next [] if @queue.empty?
            out = @queue.map do |time, bytes|
              delta = @last ? MB::M.max(time - @last, 0.0) : 0.0
              @last = time
              [delta, bytes]
            end
            @queue.clear
            out
          end
        end

        # Messages waiting for a read.
        def pending
          @lock.synchronize { @queue.length }
        end

        # Free-running timestamps (see LiveSource), not JACK frames.
        def frame_times?
          false
        end

        def frame_rate
          nil
        end

        def port
          @name
        end

        # Stops taking messages.  Returns nil.
        def close
          @lock.synchronize do
            @closed = true
            @queue.clear
          end
          nil
        end

        def closed?
          @closed
        end
      end
    end
  end
end
