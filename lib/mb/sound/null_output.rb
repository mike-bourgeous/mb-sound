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

      # The number of samples that have been written.
      attr_reader :samples_written

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
        @samples_written = 0
      end

      # Verifies the correct number of channels were given, sleeps for the
      # duration of the data, then ignores the data.
      def write(data)
        raise "Expected #{@channels} channels, got #{data.length}" unless @channels == data.length
        @samples_written += data[0].length
        sleep data[0].length.to_f / @rate if @sleep
      end
    end
  end
end
