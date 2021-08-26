module MB
  module Sound
    # Acts as both an input stream and an output stream.  Whatever is written
    # can later be read.  Data must be written in #buffer_size chunks.
    class Loopback
      attr_reader :buffer_size, :rate, :channels

      # Initializes a loopback I/O.  A block may be given to process each
      # buffer as it is read.
      def initialize(channels:, rate: 48000, buffer_size: 800, &process)
        raise 'Channels must be an int >= 1' unless channels.is_a?(Integer) && channels >= 1

        @buffer_size = buffer_size
        @channels = channels
        @rate = rate
        @zero = [Numo::SFloat.zeros(@buffer_size).freeze] * @channels
        @buf = []

        @process = process
      end

      # Reads the oldest buffer that was given to #write, or reads all zeros if
      # there is no buffer available.
      def read(frames = @buffer_size)
        raise "Frame count to read (got #{frames.inspect}) must match buffer size (#{@buffer_size.inspect})" unless frames == @buffer_size

        buf = @buf.shift || @zero
        buf = @process.call(buf) if @process
        buf
      end

      # Adds the given +data+ (an Array of Numo::NArray) to the internal
      # buffer, to be read later by #read.
      def write(data)
        raise "Channel count must be #{@channels}" unless data.length == @channels
        raise "Buffer size must be #{@buffer_size}" unless data.all? { |d| d.length == @buffer_size }

        @buf << data
      end
    end
  end
end
