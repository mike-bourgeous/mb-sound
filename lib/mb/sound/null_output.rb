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
      attr_reader :rate

      # The number of sample frames that have been written, independent of the
      # number of channels.
      attr_reader :frames_written

      # Whether this null output will sleep to simulate the normal playback
      # speed of audio.  If false, #write will return immediately.  If true,
      # #write will sleep for the normal duration of the audio buffer given,
      # based on sample #rate.
      attr_reader :sleep

      # Initializes a null output stream for the given number of +:channels+.
      # The sample +:rate+ controls sleep duration.  The +:buffer_size+ is
      # stored for compatibility, but otherwise ignored.
      #
      # if +:sleep+ is true (the default), then #write will simulate a normal
      # playback speed by sleeping for the duration of the data given,
      # calculated using the sample rate.
      def initialize(channels:, rate: 48000, buffer_size: 800, sleep: true)
        raise 'Channels must be positive' if channels < 1
        @channels = channels
        @rate = rate
        @buffer_size = buffer_size
        @sleep = sleep
        @frames_written = 0
      end

      # Verifies the correct number of channels were given, sleeps for the
      # duration of the data (unless #sleep is false), then ignores the data.
      def write(data)
        raise "Expected #{@channels} channels, got #{data.length}" unless @channels == data.length
        @frames_written += data[0].length

        # FIXME: This should sleep relative to the previous call to maintain a
        # rate, rather than sleeping for a fixed duration.
        Kernel.sleep(data[0].length.to_f / @rate) if @sleep
      end
    end
  end
end
