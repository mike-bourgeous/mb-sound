module MB
  module Sound
    # A 1D circular buffer implemented around Numo::SFloat, Numo::DFloat,
    # Numo::SComplex, or Numo::DComplex, supporting reads and writes of
    # arbitrary sizes.
    class CircularBuffer
      include BufferHelper

      # Thrown when more data is written than there is space for.
      class BufferOverflow < RuntimeError; end

      # Thrown when more data is read than has been written.
      class BufferUnderflow < RuntimeError; end

      # Maximum buffer size
      attr_reader :buffer_size

      # Number of values available for reading
      attr_reader :length
      alias count length

      # Whether the buffer is real (false) or complex (true)
      attr_reader :complex

      # Whether the buffer is single-precision (false) or double-precision (true)
      attr_reader :double

      def initialize(buffer_size:, complex: false, double: false)
        raise ArgumentError, 'Buffer size must be a positive integer' unless buffer_size.is_a?(Integer) && buffer_size > 0

        @buffer_size = buffer_size.to_i
        @complex = complex
        @double = double

        @read_pos = 0
        @write_pos = 0
        @length = 0

        # TODO: call this again if any attributes change
        setup_buffer(length: buffer_size, complex: complex, temp: true, double: double)
      end

      def read(count)
        if count > @length
          raise BufferUnderflow, "Read of size #{count} is greater than #{@length} available samples"
        end

        MB::M.circular_read(@buf, @read_pos, count, target: @tmpbuf)[0...count].tap {
          @read_pos = (@read_pos + count) % @buffer_size
          @length -= count
        }
      end

      # Appends the given +narray+ to the circular buffer, returning the
      # new count of available samples to read.
      def write(narray)
        # TODO: should the buffer grow automatically?
        if narray.length > available
          raise BufferOverflow, "Write of size #{narray.length} is greater than #{available} space available"
        end

        MB::M.circular_write(@buf, narray, @write_pos)
        @write_pos = (@write_pos + narray.length) % @buffer_size
        @length += narray.length
      end

      # Returns the available space left in the circular buffer.  See also
      # #length.
      def available
        @buffer_size - @length
      end
    end
  end
end
