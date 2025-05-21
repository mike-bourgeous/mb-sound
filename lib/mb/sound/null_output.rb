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
      # based on sample #sample_rate.
      attr_reader :sleep

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
      def initialize(channels:, sample_rate: 48000, buffer_size: 800, sleep: true, strict_buffer_size: false)
        raise 'Channels must be positive' if channels < 1
        @channels = channels
        @sample_rate = sample_rate.to_f
        @buffer_size = buffer_size || 800
        @sleep = sleep
        @strict_buffer_size = strict_buffer_size

        @frames_written = 0
        @closed = false
      end

      # Verifies the correct number of channels were given, sleeps for the
      # duration of the data (unless #sleep is false), then ignores the data.
      def write(data)
        raise 'This output is closed' if @closed
        raise "Expected #{@channels} channels, got #{data.length}" unless @channels == data.length
        @frames_written += data[0].length

        # FIXME: This should sleep relative to the previous call to maintain a
        # rate, rather than sleeping for a fixed duration.
        Kernel.sleep(data[0].length.to_f / @sample_rate) if @sleep
      end

      # Closes the output, preventing future writing (for compatibility with
      # other output types).
      def close
        @closed = true
      end

      # Returns true if this output has been closed.
      def closed?
        @closed
      end
    end
  end
end
