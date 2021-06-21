module MB
  module Sound
    # A process_stream-compatible input stream that generates a stream of a
    # constant value of a given length.  Primarily used for testing.
    #
    # Note: the buffer will be reused unless it has to be resized, so do not make
    # any modifications to the buffer.
    class NullInput
      attr_reader :channels, :length, :remaining

      # Initializes a null audio stream that returns the +fill+ value +length+
      # times for the given number of +channels+ (or forever if length <= 0).
      # The initial internal buffer size will be +initial_buffer+ frames, but
      # will be grown if #read is called with a size larger than the buffer.
      def initialize(channels:, length: 0, fill: 0, initial_buffer: 4096)
        raise 'Channels must be an int >= 1' unless channels.is_a?(Integer) && channels >= 1

        @channels = channels
        @length = length
        @remaining = length
        @fill = fill
        @buffer = Numo::SFloat.new(initial_buffer).fill(@fill)
      end

      # Reads +frames+ frames of raw 32-bit floats of +@fill+ for +@channels+
      # channels.  Returns an array of buffers, one buffer per channel.
      def read(frames)
        raise 'Must read at least one frame' if frames < 1

        if @length > 0
          if @remaining < frames
            frames = @remaining
          end

          @remaining -= frames
        end

        return [Numo::SFloat[]] * @channels if frames <= 0

        @buffer = Numo::SFloat.new(frames).fill(@fill) if frames > @buffer.length

        [@buffer[0..(frames - 1)]] * @channels
      end
    end
  end
end
