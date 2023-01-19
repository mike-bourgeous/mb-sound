module MB
  module Sound
    # A process_stream-compatible input stream that generates a stream of a
    # constant value of a given length.  Primarily used for testing.
    #
    # Note: the buffer will be reused unless it has to be resized, so do not make
    # any modifications to the buffer.
    class NullInput
      attr_reader :channels, :length, :remaining, :samples_read, :rate, :buffer_size

      # Initializes a null audio stream that returns the +fill+ value +length+
      # times for the given number of +channels+ (or forever if length <= 0).
      # The initial internal buffer size will be +initial_buffer+ frames, but
      # will be grown if #read is called with a size larger than the buffer.
      def initialize(channels:, rate: 48000, length: 0, fill: 0, initial_buffer: 4096, buffer_size: nil)
        raise 'Channels must be an int >= 1' unless channels.is_a?(Integer) && channels >= 1

        @channels = channels
        @rate = rate
        @length = length
        @remaining = length
        @fill = fill
        @buffer = Numo::SFloat.new(initial_buffer).fill(@fill)
        @empty = Numo::SFloat[]
        @buffer_size = buffer_size&.to_i
        @samples_read = 0
        @closed = false
      end

      # Reads +frames+ frames of raw 32-bit floats of +@fill+ for +@channels+
      # channels.  Returns an array of buffers, one buffer per channel.
      def read(frames)
        raise 'This input is closed' if @closed

        if frames == 0
          return [@empty] * @channels
        end

        if @length > 0
          if @remaining < frames
            frames = @remaining
          end

          @remaining -= frames
        end

        return [Numo::SFloat[]] * @channels if frames <= 0

        @buffer = Numo::SFloat.new(frames).fill(@fill) if frames > @buffer.length

        @samples_read += frames

        [@buffer[0..(frames - 1)]] * @channels
      end

      # Closes the input, preventing future writing (for compatibility with
      # other input types).
      def close
        @closed = true
      end

      # Returns true if this input has been closed.
      def closed?
        @closed
      end
    end
  end
end
