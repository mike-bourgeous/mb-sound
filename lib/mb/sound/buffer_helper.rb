module MB
  module Sound
    # This mixin provides the setup_buffer method for use by any class that
    # needs an internal Numo::NArray buffer, and potentially needs to be able
    # to convert that buffer from real to complex when data types change.
    #
    # Typical usage is to call #setup_buffer from a GraphNode's #sample
    # method.
    module BufferHelper
      private

      # Based on the given +length+ and whether to use +complex+ values,
      # creates or replaces a buffer in @buf as needed.  If @buf already
      # matches +length+ and +complex+, no change is made.
      #
      # If +temp+ is true, then another buffer of the same size and type is
      # also created in @tmpbuf.
      #
      # If +:double+ is true, then double-precision buffers are used.
      # Otherwise the method will create single-precision buffers.
      def setup_buffer(length:, complex: false, temp: false, double: false)
        # TODO: is this trying too hard to avoid a few conditionals by using
        # too many conditionals?
        return unless !defined?(@buf) || @buf.nil? ||
          !defined?(@buflen) || @buflen != length ||
          !defined?(@bufcomplex) || @bufcomplex != complex ||
          !defined?(@buftemp) || @buftemp != temp ||
          !defined?(@bufdouble) || @bufdouble != double ||
          (temp && (!defined?(@tmpbuf) || @tmpbuf.nil?))

        @buflen = length
        @bufcomplex = complex
        @buftemp = temp
        @bufdouble = double
        @buf ||= nil

        if double
          @bufclass = complex ? Numo::DComplex : Numo::DFloat
        else
          @bufclass = complex ? Numo::SComplex : Numo::SFloat
        end

        if @buf.nil?
          # Buffer doesn't exist; create it
          @buf = @bufclass.zeros(length)
        elsif @buf.length == length && @buf.class != @bufclass
          # Buffer has the wrong type; cast it
          @buf = @bufclass.cast(@buf)
        elsif @buf.length < length
          @buf = MB::M.zpad(@buf, length)
        elsif @buf.length > length
          @buf = @buf[0...length]
        end

        if temp
          @tmpbuf ||= nil
          if @tmpbuf.nil?
            # Buffer doesn't exist; create it
            @tmpbuf = @bufclass.zeros(length)
          elsif @tmpbuf.length == length && @tmpbuf.class != @bufclass
            # Buffer has the wrong type; cast it
            @tmpbuf = @bufclass.cast(@tmpbuf)
          elsif @tmpbuf.length < length
            @tmpbuf = MB::M.zpad(@tmpbuf, length)
          elsif @tmpbuf.length > length
            @tmpbuf = @tmpbuf[0...length]
          end
        end
      end
    end
  end
end
