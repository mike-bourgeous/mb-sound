module MB
  module Sound
    # A 1D circular buffer implemented around Numo::SFloat, Numo::DFloat,
    # Numo::SComplex, or Numo::DComplex, supporting reads and writes of
    # arbitrary sizes.  Also supports multiple readers with different offsets,
    # useful for fanout or delays.
    #
    # Single-reader example:
    #
    #     cbuf = MB::Sound::CircularBuffer.new(buffer_size: 100)
    #     cbuf.write(Numo::SFloat[1,2,3])
    #     cbuf.read(2) # => Numo::SFloat[1,2]
    #
    # Multi-reader example:
    #
    #     cbuf = MB::Sound::CircularBuffer.new(buffer_size: 100)
    #     r1 = cbuf.reader
    #     r2 = cbuf.reader
    #     cbuf.write(Numo::SComplex[1i,2i,3i])
    #     r1.read(2) # => Numo::SComplex[1i,2i]
    #     r2.read(3) # => Numo::SComplex[1i,2i,3i]
    #     r1.read(1) # => Numo::SComplex[3i]
    class CircularBuffer
      include BufferHelper

      # Thrown when more data is written than there is space for.
      class BufferOverflow < RuntimeError; end

      # Thrown when more data is read than has been written.
      class BufferUnderflow < RuntimeError; end

      # Thrown when #read is called after #reader, or vice versa.
      class ReaderModeError < RuntimeError; end

      # Single reader with an independent read pointer as returned by #reader.
      class Reader
        include BufferHelper

        # The number of samples available for reading from this Reader's
        # position.
        attr_reader :length
        alias count length

        # For internal use by CircularBuffer#reader.  Creates a new Reader at
        # the given read position with the given initial length of available
        # samples.
        def initialize(cbuf:, index:, read_pos:, length:)
          @cbuf = cbuf
          @index = index
          @read_pos = read_pos
          @tmpbuf = nil
          @length = length

          setup_buffer(length: cbuf.buffer_size, complex: cbuf.complex, double: cbuf.double)
        end

        # Consumes and returns the next +count+ samples.
        def read(count)
          peek(count).tap { |v|
            @read_pos = (@read_pos + count) % @cbuf.buffer_size
            @length -= v.length
          }
        end

        # Returns the next +count+ samples without consuming them or
        # incrementing the read pointer.  Do not modify the returned buffer as
        # it may be a view into the internal buffer.
        def peek(count)
          if count > @length
            raise BufferUnderflow, "Read of size #{count} is greater than #{@length} available samples " \
              "on #{@index < 0 ? 'default reader' : "reader #{@index}"}"
          end

          setup_buffer(length: @cbuf.buffer_size, complex: @cbuf.complex, double: @cbuf.double)

          # Return an empty NArray if asked to read nothing, even if the buffer is empty
          return @buf.class[] if count == 0

          @cbuf.direct_read(pos: @read_pos, count: count, target: @buf)
        end

        # Discards/consumes the next +count+ samples as if they have been
        # #read, without paying the cost of extracting or duplicating them.
        # Useful with #peek for implementing atypical access patterns.
        #
        # Returns the number of available samples remaining.
        def discard(count)
          if count > @length
            raise BufferUnderflow, "Discard of size #{count} is greater than #{@length} available samples " \
              "on #{@index < 0 ? 'default reader' : "reader #{@index}"}"
          end

          @read_pos = (@read_pos + count) % @cbuf.buffer_size
          @length -= count
        end

        # For internal use by CircularBuffer.  Increments this reader's internal length value.
        def wrote(count)
          raise "BUG: wrote past read position on reader #{@index}" if (count + @length) >
          @length += count
        end

        # Returns true if there are no samples available for this reader to read.
        def empty?
          @length == 0
        end
      end

      # Maximum buffer size
      attr_reader :buffer_size

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
        raise ArgumentError, "Buffer size must be a positive integer (got #{buffer_size.inspect})" unless buffer_size.is_a?(Integer) && buffer_size > 0

        @buffer_size = buffer_size

        @write_pos = 0

        # In multi-reader mode, we store all readers in @readers.  In
        # single-reader mode, we store one reader in @r0.
        @readers = []
        @r0 = nil

        setup_buffer(length: @buffer_size, complex: complex, temp: false, double: double)
      end

      # Creates a new circular buffer of the given size, then copies the data
      # from this circular buffer into the new buffer.  This is a temporary
      # solution to growing a circular buffer until automatic resizing might be
      # implemented.
      #
      # Raises BufferOverflow if the requested size is smaller than the data
      # stored in the buffer.
      #
      # Raises ReaderModeError if the buffer is in multi-reader mode.
      def dup(new_size = @buffer_size)
        len = self.length
        if new_size < len
          raise BufferOverflow, "New buffer size #{new_size} is smaller than data stored in the buffer #{len}"
        end

        # TODO: add in-place resizing if this is too slow
        newbuf = self.class.new(buffer_size: new_size, complex: @bufcomplex, double: @bufdouble)
        newbuf.write(self.peek(self.length)) unless self.empty?
        newbuf
      end

      # Creates and returns a new Reader for this buffer in multi-reader mode,
      # with its own independent read pointer.  The read position defaults to
      # the current write position at time of reader creation (e.g. an empty
      # buffer), minus the delay specified by +delay_samples+.
      #
      # Call this before calling any other methods, as most other methods will
      # switch the buffer into single-reader mode.
      #
      # Raises ReaderModeError if the buffer is in single-reader mode (e.g.
      # #read, #write, or another method has been called first).
      #
      # Raises ArgumentError if +delay_samples+ would put the read pointer
      # behind the write pointer.
      def reader(delay_samples = 0)
        raise ReaderModeError, 'Buffer is in single-reader mode.  You must call #reader before calling any other methods.' unless @r0.nil?

        raise ArgumentError, 'Cannot delay more than the buffer size' if delay_samples > @buffer_size

        Reader.new(
          cbuf: self,
          index: @readers.count,
          read_pos: (@write_pos - delay_samples) % @buffer_size,
          length: delay_samples
        ).tap { |r|
          @readers << r
        }
      end

      # Consumes and returns the next +count+ samples of the buffer when in
      # single-reader mode.
      #
      # Raises ReaderModeError if the buffer is in multi-reader mode (i.e. if
      # #reader has been called).
      #
      # Raises BufferUnderflow if +count+ is greater than #length.
      def read(count)
        default_reader.read(count)
      end

      # Returns the next +count+ samples of the buffer without consuming them
      # when in single-reader mode.  Future calls to #read or #peek will return
      # the same samples.
      #
      # Raises ReaderModeError if the buffer is in multi-reader mode (i.e. if
      # #reader has been called).
      #
      # Raises BufferUnderflow if +count+ is greater than #length.
      def peek(count)
        default_reader.peek(count)
      end

      # In single-reader mode, consumes/discards +count+ samples as if they
      # had been #read.  This is useful with #peek and #peek_last for
      # implementing more creative access patterns.
      #
      # Raises ReaderModeError if the buffer is in multi-reader mode.
      #
      # Raises BufferUnderflow if +count+ is greater than #length.
      def discard(count)
        default_reader.discard(count)
      end

      # For internal use by Reader.  Does a direct circular read from the
      # internal buffer at the given position, storing the result in +:target+,
      # and windowing the target to the given +:count+.
      def direct_read(pos:, count:, target:)
        MB::M.circular_read(@buf, pos, count, target: target)[0...count].not_inplace!
      end

      # Appends the given +narray+ to the circular buffer, returning the new
      # count of available samples to read from the furthest-behind reader.
      #
      # Raises BufferOverflow without writing any data if there's not enough
      # room for the given +narray+ in the buffer.
      def write(narray)
        # TODO: should the buffer grow automatically?  If we grow the buffer
        # here we will have to recompute the read and/or write positions of
        # every reader if they straddle the buffer end, and probably have to
        # move data around to preserve continuity of reads.
        #
        # A slower option would be to just create a brand new buffer with
        # whatever we already have by calling the read method, then writing to
        # the new buffer (see #dup).
        #
        # Multiple readers could be updated by resetting the read position to
        # write_pos minus the reader's length, I think, as long as the
        # end-straddling data is shifted accordingly.  Basically the new zeros
        # have to be inserted somewhere in the middle of the data, rather than
        # at either end.
        if narray.length > available
          raise BufferOverflow, "Write of size #{narray.length} is greater than #{available} space available"
        end

        expand_buffer(narray, grow: false)

        MB::M.circular_write(@buf, narray, @write_pos)
        @write_pos = (@write_pos + narray.length) % @buffer_size

        # Update each reader in multi-reader mode
        @readers&.each do |r|
          r.wrote(narray.length)
        end

        # Update default reader in single-reader mode
        @r0&.wrote(narray.length)

        @readers&.map(&:length)&.max || length
      end

      # Returns the number of samples available for reading in single-reader
      # mode.  Switches to single-reader mode if no mode has been set.
      #
      # Raises ReaderModeError if the buffer is in multi-reader mode.
      def length
        default_reader.length
      end
      alias count length

      # Returns the available space left for writing in the circular buffer,
      # whether in single-reader or multi-reader mode.  Switches to
      # single-reader mode if no mode has been set.  See also #length.
      def available
        @buffer_size - (@readers.max_by { |v| v.length }&.length || default_reader.length)
      end

      # Returns true if there are no samples in the circular buffer in any
      # readers, whether in single-reader (#read) or multi-reader (#reader)
      # mode.
      def empty?
        @readers.empty? ? default_reader.empty? : @readers.all?(&:empty?)
      end

      private

      # Returns the default reader if it exists, or switches to single-reader
      # mode by creating the default reader.  Raises an error if we're already
      # in multi-reader mode.
      def default_reader
        raise ReaderModeError, 'Reader is in multi-reader mode.  Do not call #read or #length after creating a reader with #reader.' unless @readers.empty?
        @r0 ||= Reader.new(cbuf: self, index: -1, read_pos: 0, length: @write_pos)
      end
    end
  end
end
