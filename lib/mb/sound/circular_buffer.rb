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

      # XXX multi-reader idea; see also GraphNode::MultitapDelay
      class Reader
        attr_reader :read_pos

        def initialize(cbuf:, index:, read_pos:)
          @cbuf = cbuf
          @index = index
          @read_pos = read_pos
          @tmpbuf = nil
        end

        def length
          (@cbuf.write_pos - @read_pos) % @cbuf.buffer_size
        end

        def read(count)
          raise BufferUnderflow, "Reader #{@index} has #{length}, but #{count} requested" if count > length

          @cbuf.direct_read(pos: @read_pos, count: count, target: nil).tap {
            @read_pos = (@read_pos + count) % @cbuf.buffer_size
          }
        end
      end

      # Maximum buffer size
      attr_reader :buffer_size

      # Number of values available for reading
      attr_reader :length
      alias count length

      # Whether the buffer is real (false) or complex (true)
      attr_reader :bufcomplex
      alias complex bufcomplex

      # Whether the buffer is single-precision (false) or double-precision (true)
      attr_reader :bufdouble
      alias double bufdouble

      # Internal buffer's write position (for use by Reader class)
      attr_reader :write_pos

      # Creates a circular buffer of the given maximum +:buffer_size+.  Creates
      # a complex buffer if +:complex+ is true (real by default).  Creates a
      # double-precision buffer if +:double+ is true (single-precision by
      # default).  The buffer type will change to complex or double
      # automatically if upstream data becomes complex or double precision, but
      # specifying complex or double up front saves a buffer reallocation.
      def initialize(buffer_size:, complex: false, double: false)
        raise ArgumentError, 'Buffer size must be a positive integer' unless buffer_size.is_a?(Integer) && buffer_size > 0

        @buffer_size = buffer_size

        @read_pos = 0
        @write_pos = 0
        @length = 0

        @readers = []

        setup_buffer(length: @buffer_size, complex: complex, temp: true, double: double)
      end

      # XXX multi-reader idea/experiment
      def reader(delay_samples = 0)
        # FIXME: include read pos in exception check or something
        raise 'Cannot delay more than the buffer size' if delay_samples > @buffer_size

        Reader.new(cbuf: self, index: @readers.length, read_pos: (@read_pos - delay_samples) % @buffer_size).tap { |r|
          @readers << r
        }
      end

      # Returns the next +count+ samples of the buffer.
      #
      # Raises BufferUnderflow if +count+ is greater than #length.
      def read(count)
        # TODO: XXX Just have an internal reader by default and call that?

        # TODO: should we allow short reads (return less than requested)?
        if count > @length
          raise BufferUnderflow, "Read of size #{count} is greater than #{@length} available samples"
        end

        # Return an empty NArray if asked to read nothing, even if the buffer is empty
        return @buf.class[] if count == 0

        MB::M.circular_read(@buf, @read_pos, count, target: @tmpbuf)[0...count].tap {
          @read_pos = (@read_pos + count) % @buffer_size
          @length -= count
        }
      end

      # For internal use by Reader.  Does a direct circular read from the
      # internal buffer at the given position.
      def direct_read(pos:, count:, target:)
        MB::M.circular_read(@buf, pos, count, target: target)
      end

      # Appends the given +narray+ to the circular buffer, returning the
      # new count of available samples to read.
      #
      # Raises BufferOverflow without writing any data if there's not enough
      # room for the given +narray+ in the buffer.
      def write(narray)
        # TODO: should the buffer grow automatically?  If we grow the buffer
        # here we will have to recompute the read and/or write positions if
        # they straddle the buffer end, and probably have to move data around
        # to preserve continuity of reads.
        #
        # A slower option would be to just create a brand new buffer with
        # whatever we already have by calling the read method, then growing the
        # buffer, so we don't have to move any data (apart from what #read
        # already does).
        if narray.length > available
          raise BufferOverflow, "Write of size #{narray.length} is greater than #{available} space available"
        end

        # TODO: XXX take readers buffers into account
        expand_buffer(narray, grow: false)

        MB::M.circular_write(@buf, narray, @write_pos)
        @write_pos = (@write_pos + narray.length) % @buffer_size
        @length += narray.length
      end

      # Returns the available space left in the circular buffer.  See also
      # #length.
      def available
        # TODO: XXX take readers into account
        @buffer_size - @length
      end

      # Returns true if there are no samples in the circular buffer.
      def empty?
        @length == 0
      end
    end
  end
end
