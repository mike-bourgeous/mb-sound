module MB
  module Sound
    # A process_stream-compatible output stream that ignores all audio given,
    # but verifies that the correct number of channels are provided.  Primarily
    # used for testing.
    class NullOutput
      # Number of channels this null output will expect to be passed to #write.
      attr_reader :channels

      # Not actually relevant, but provided for compatibility with PlotOutput.
      attr_reader :buffer_size

      # The fake sample rate given to the constructor.
      attr_reader :sample_rate

      # The number of sample frames that have been written, independent of the
      # number of channels.
      attr_reader :frames_written

      # Whether this null output will sleep to simulate the normal playback
      # speed of audio.  If false, #write will return immediately.  If true,
      # #write will sleep for the normal duration of the audio buffer given,
      # based on sample #sample_rate.  If :virtual, #write keeps a virtual
      # clock instead (see #consume).
      attr_reader :sleep

      # With sleep: :virtual, how many frames #write may run ahead of what
      # was consumed (see #consume).
      attr_reader :ahead

      # With sleep: :virtual, the frames consumed so far (see #consume).
      attr_reader :frames_consumed

      # Whether this output should ask writers to use exactly the specified
      # buffer size.
      attr_reader :strict_buffer_size
      alias strict_buffer_size? strict_buffer_size

      # Initializes a null output stream for the given number of +:channels+.
      # The +:sample_rate+ controls sleep duration.  The +:buffer_size+ is
      # stored for compatibility, but otherwise ignored.
      #
      # if +:sleep+ is true (the default), then #write will simulate a normal
      # playback speed by sleeping for the duration of the data given,
      # calculated using the sample rate.
      #
      # If +:sleep+ is :virtual, time is a virtual clock that moves only as
      # audio is consumed: #write blocks once it is +:ahead+ frames (default
      # three buffers) past what #consume has let through, and whoever waits
      # for the sound (MB::Sound::Internal.wait_audio, used by foreground
      # #play and #wait) consumes it.  A realtime Session on such an output
      # renders as fast as its waiter consumes, never by wall clock, with
      # bounded memory, and the same frames reach each check of the waiter
      # (deterministic).  For specs of things a render thread is part of;
      # everything else uses Session.new(realtime: false) and
      # #process_buffer.
      def initialize(channels:, sample_rate: 48000, buffer_size: 800, sleep: true, strict_buffer_size: false, ahead: nil)
        raise 'Channels must be positive' if channels < 1
        raise ArgumentError, "sleep: must be true, false, or :virtual (got #{sleep.inspect})" unless [true, false, :virtual].include?(sleep)
        @channels = channels
        @sample_rate = sample_rate.to_f
        @buffer_size = buffer_size || 800
        @sleep = sleep
        @strict_buffer_size = strict_buffer_size

        @frames_written = 0
        @closed = false

        @ahead = Integer(ahead || 3 * @buffer_size)
        @frames_consumed = 0
        @clock = sleep == :virtual ? Mutex.new : nil
        @clock_cv = sleep == :virtual ? ConditionVariable.new : nil
        @next_time = nil
        @released = false
      end

      # Returns true if this output keeps a virtual clock (sleep: :virtual).
      def virtual?
        @sleep == :virtual
      end

      # With sleep: :virtual, lets +seconds+ more audio be written (a
      # Numeric, or a Length), then waits until the writer has written up to
      # what it may run ahead (so a check after this sees the same frames
      # every time), the output closed, or nothing was written for
      # +:stall+ seconds of wall time (a writer that stopped; a safety net,
      # not a clock).  Returns the frames written.
      def consume(seconds, stall: 1.0)
        raise ArgumentError, 'Only a NullOutput with sleep: :virtual keeps a virtual clock' unless virtual?

        frames = (seconds.to_f * @sample_rate).round
        @clock.synchronize do
          @frames_consumed += frames
          @clock_cv.broadcast
          target = @frames_consumed + @ahead
          last = @frames_written
          until @closed || @frames_written >= target
            @clock_cv.wait(@clock, stall)
            break if @frames_written == last
            last = @frames_written
          end
          @frames_written
        end
      end

      # With sleep: :virtual, unblocks a waiting #write without closing
      # (Session#close calls it before joining its render thread); writes
      # no longer block afterwards.
      def release_writer
        return unless virtual?

        @clock.synchronize do
          @released = true
          @clock_cv.broadcast
        end
      end

      # Verifies the correct number of channels were given, sleeps for the
      # duration of the data (unless #sleep is false), then ignores the data.
      def write(data)
        raise 'This output is closed' if @closed
        raise "Expected #{@channels} channels, got #{data.length}" unless @channels == data.length

        if virtual?
          @clock.synchronize do
            @clock_cv.wait(@clock) until @closed || @released || @frames_written - @frames_consumed < @ahead
            @frames_written += data[0].length
            @clock_cv.broadcast
          end
        else
          @frames_written += data[0].length
          pace(data[0].length.to_f / @sample_rate) if @sleep
        end
      end

      # How far behind the playback rate writing may fall (e.g. after a pause
      # between writes) before #write stops trying to catch up.
      MAX_LAG = 0.5

      # Sleeps until the audio written so far would have finished playing, so
      # writes keep the playback rate even when the caller takes time between
      # them (sleeping a fixed duration per call would add that time on top).
      def pace(duration)
        now = MB::U.clock_now
        @next_time = now if @next_time.nil? || now - @next_time > MAX_LAG
        @next_time += duration

        delay = @next_time - now
        Kernel.sleep(delay) if delay > 0
      end
      private :pace

      # Closes the output, preventing future writing (for compatibility with
      # other output types).
      def close
        if virtual?
          @clock.synchronize do
            @closed = true
            @clock_cv.broadcast
          end
        else
          @closed = true
        end
      end

      # Returns true if this output has been closed.
      def closed?
        @closed
      end
    end
  end
end
