module MB
  module Sound
    # This mixin provides the setup_buffer method for use by any class that
    # needs an internal Numo::NArray buffer, and potentially needs to be able
    # to convert that buffer from real to complex when data types change.
    #
    # Typical usage is to call #setup_buffer from a GraphNode#sample method, or
    # to call #setup_buffer from the constructor and #grow_buffer from the
    # GraphNode#sample method.
    module BufferHelper
      private

      # Creates or replaces a Numo:NArray buffer in @buf and @tmpbuf as needed,
      # based on the given +:length+ and other parameters.  If the buffer
      # already matches the given values, no change is made.
      #
      # Buffer contents will be preserved as much as possible across type and
      # length changes.  Demotion from complex to float will raise an error.
      #
      # If +:complex+ is true, the buffer will use Numo::SComplex or
      # Numo::DComplex.  If +:complex+ is false, the buffer will use
      # Numo::SFloat or Numo::DFloat.
      #
      # If +:temp+ is true, then another buffer of the same size and type is
      # also created in @tmpbuf.
      #
      # If +:double+ is true, then double-precision buffers are used.
      # Otherwise the method will create single-precision buffers.
      def setup_buffer(length:, complex: false, temp: false, double: false)
        @buflen = length.ceil
        raise "Buffer length #{length} (rounded to #{@buflen}) cannot be zero" if @buflen == 0

        @bufcomplex = complex
        @buftemp = temp
        @bufdouble = double
        @buf ||= nil

        if @bufdouble
          @bufclass = @bufcomplex ? Numo::DComplex : Numo::DFloat
        else
          @bufclass = @bufcomplex ? Numo::SComplex : Numo::SFloat
        end

        @buf = create_or_convert_buffer(@buf)

        if @buftemp
          @tmpbuf ||= nil
          @tmpbuf = create_or_convert_buffer(@tmpbuf)
        end

        nil
      end

      # Promotes the buffer from real to complex if +:complex+ is true, or from
      # single- to double-precision if +:double+ is true.  Adds a temporary
      # buffer if +:temp+ is true.  Grows the buffer to at least +:length+
      # samples.  Does not demote the buffer or remove a temporary buffer.
      def promote_buffer(length: nil, complex: false, double: false, temp: false)
        length ||= @buflen
        length = @buflen if @buflen > length

        setup_buffer(
          length: [@buflen, length].compact.max,
          complex: @bufcomplex || complex,
          double: @bufdouble || double,
          temp: @buftemp || temp
        )
      end

      # Updates the buffer type and length based on the given example buffer,
      # only promoting types and growing -- never demoting or shrinking.  Call
      # #setup_buffer first.
      #
      # This method is useful for GraphNode#sample or Filter#process
      # implementations that want to maintain a buffer to hold whatever data
      # type comes in from upstream sources.
      #
      # The +:length+ parameter allows specifying a different minimum size when
      # +:grow+ is true, in case the +example_buf+ has the type to use for the
      # buffer but not the size.
      #
      # The +:complex+ and +:double+ parameters allow promotion to complex
      # and/or double even if the given buffer is float or real.
      #
      # If +:grow+ is false, then the buffer will not grow based on the example
      # buffer length -- only types will be promoted.
      #
      # See #setup_buffer.
      def expand_buffer(example_buf, length: nil, complex: @bufcomplex, double: @bufdouble, grow: true)
        raise "BUG: Call #setup_buffer before calling #expand_buffer" unless defined?(@bufcomplex)

        complex ||= example_buf.is_a?(Numo::SComplex) || example_buf.is_a?(Numo::DComplex)
        double ||= example_buf.is_a?(Numo::DFloat) || example_buf.is_a?(Numo::DComplex) ||
          example_buf.is_a?(Numo::Int32) || example_buf.is_a?(Numo::Int64)

        new_length = MB::M.max(length || example_buf.length, @buflen)

        promote_buffer(length: grow ? new_length : nil, complex: complex, double: double)
      end

      # Creates or converts the given buffer to the current type and length and
      # returns the buffer.  For use by #setup_buffer.
      def create_or_convert_buffer(b)
        if b.nil? || b.length == 0
          # Buffer doesn't exist; create it
          b = @bufclass.zeros(@buflen)
        elsif b.class != @bufclass
          # Buffer has the wrong type; cast it
          # TODO: should we support demotion from Complex to Float?
          b = @bufclass.cast(b)
        end

        if b.length < @buflen
          # Buffer is too short; extend it with zeros
          b = MB::M.zpad(b, @buflen)
        elsif b.length > @buflen
          # Buffer is too long; truncate it
          b = b[0...@buflen]
        else
          # Buffer needs no modification (e.g. this could happen for the
          # primary buffer if temp is changed from false to true)
          b
        end
      end
    end
  end
end
