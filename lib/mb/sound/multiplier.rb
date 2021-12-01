module MB
  module Sound
    # Multiplies zero or more inputs that have a #sample method that takes a
    # buffer size parameter, such as an Oscillator or an ADSREnvelope.  The
    # main uses for this class are for applying envelopes to sounds, and for
    # amplitude modulation.
    #
    # See also the Mixer class.
    class Multiplier
      # The constant value by which the output will be multiplied.
      attr_accessor :constant

      # Creates a Multiplier with the given inputs, which must be either
      # Numeric values or objects that have a #sample method.  The
      # multiplicands or Numeric constants may all have complex values.  At
      # present, no attempt is made to detect cycles in the signal graph.
      #
      # Note: an empty Multiplier will return the constant value, not zero!
      # This DC may damage speakers if played directly.
      #
      # The +multiplicands+ must be an Array of Numerics or objects responding
      # to :sample (or you may also use a variable-length argument list).
      def initialize(*multiplicands)
        @constant = 1
        @multiplicands = {}

        @complex = false

        if multiplicands.is_a?(Array) && multiplicands.length == 1 && multiplicands[0].is_a?(Array)
          multiplicands = multiplicands[0] 
        end

        multiplicands.each_with_index do |m, idx|
          case
          when m.is_a?(Numeric)
            @constant *= m

          when m.is_a?(Array)
            raise "Multiplicand cannot be an Array, even though it responds to :sample"

          when m.respond_to?(:sample)
            raise "Duplicate multiplicand #{m} at index #{idx}" if @multiplicands.include?(m)
            @multiplicands[m] = m

          else
            raise ArgumentError, "Multiplicand #{m.inspect} at index #{idx} is not a Numeric and does not respond to :sample"
          end
        end

        @buf = nil
      end

      # Calls the #sample methods of all multiplicands, multiplies them
      # together with the initial #constant value, and returns the result.
      def sample(count)
        inputs = @multiplicands.map { |m, _|
          v = m.sample(count).not_inplace!
          @complex = true if v.is_a?(Numo::SComplex) || v.is_a?(Numo::DComplex)
          v = MB::M.zpad(v, count) if v && v.length < count
          v
        }

        setup_buffer(count)

        @buf.fill(@constant)

        inputs.each do |v, _|
          next if v.nil? || v.empty?
          @buf.inplace * v
        end

        @buf.not_inplace!
      end

      # Returns the multiplicand at the given index by insertion order
      # (starting at 0), or the given multiplicand by identity if present.
      def [](multiplicand)
        multiplicand = @multiplicands.keys[multiplicand] if multiplicand.is_a?(Integer)
        @multiplicands[multiplicand]
      end

      # Adds another multiplicand (e.g. an envelope generator) to the product.
      def <<(multiplicand)
        raise "Multiplicand #{multiplicand} must respond to :sample" unless multiplicand.respond_to?(:sample)
        @multiplicands[multiplicand] = multiplicand
      end
      alias add <<

      # Removes the given +multiplicand+ from the product.  The +multiplicand+
      # may be an Integer to refer to a multiplicand by insertion order
      # (starting at 0), in which case multiplicands added after this one will
      # have their index decremented by one.
      def delete(multiplicand)
        multiplicand = @multiplicands.keys[multiplicand] if multiplicand.is_a?(Integer)
        @multiplicands.delete(multiplicand)
      end

      # Removes all multiplicands, but does not reset the constant, if set.
      def clear
        @multiplicands.clear
      end

      # Returns the number of multiplicands (excluding constant(s)).
      def count
        @multiplicands.length
      end
      alias length count

      # Returns true if there are no multiplicands (exclusive of constant).
      def empty?
        @multiplicands.empty?
      end

      # Returns an Array of the multiplicands in this product (exclusive of
      # constant).
      def multiplicands
        @multiplicands.keys
      end

      private

      # TODO: Maybe this should be some kind of helper mixin
      def setup_buffer(length)
        @complex ||= @constant.is_a?(Complex)
        @bufclass = @complex ? Numo::SComplex : Numo::SFloat

        if @buf.nil? || @buf.length != length || @bufclass != @buf.class
          @buf = @bufclass.zeros(length)
        end
      end
    end
  end
end
