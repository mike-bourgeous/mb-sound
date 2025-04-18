module MB
  module Sound
    module GraphNode
      # Multiplies zero or more inputs that have a #sample method that takes a
      # buffer size parameter, such as an Oscillator or an ADSREnvelope.  The
      # main uses for this class are for applying envelopes to sounds, and for
      # amplitude modulation.
      #
      # See also the Mixer class.
      class Multiplier
        include GraphNode
        include BufferHelper

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
        #
        # If +:stop_early+ is true (the default), then any multiplicand returning
        # nil or an empty NArray from its #sample method will cause this #sample
        # method to return nil.  Otherwise, the #sample method only returns nil
        # when all multiplicands return nil or empty.
        def initialize(*multiplicands, stop_early: true)
          @constant = 1
          @multiplicands = {}

          @complex = false

          @stop_early = stop_early

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
        #
        # If any multiplicand (or every multiplicand if stop_early was set to
        # false in the constructor) returns nil or an empty buffer, then this
        # method will return nil.
        def sample(count)
          @complex ||= @constant.is_a?(Complex)

          inputs = @multiplicands.map.with_index { |(m, _), idx|
            v = m.sample(count)&.not_inplace!

            # Continue instead of aborting if one input ends, so that all
            # inputs have a chance to finish (see @stop_early condition below)
            next if v.nil? || v.empty?

            if v.length != count
              raise "Input #{idx}/#{m} on #{self} gave us #{v.length} samples when we asked for #{count}"
            end

            @complex ||= v.is_a?(Numo::SComplex) || v.is_a?(Numo::DComplex)
            v = MB::M.opad(v, count) if v && v.length > 0 && v.length < count
            v
          }

          inputs.compact!

          if @stop_early
            return nil if inputs.length != @multiplicands.length
          else
            return nil if inputs.empty? && !@multiplicands.empty?
          end

          setup_buffer(length: count, complex: @complex)

          @buf.fill(@constant)

          inputs.each.with_index do |v, idx|
            next if v.empty?
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

        # See GraphNode#sources
        def sources
          @multiplicands.keys + [@constant]
        end

        # Adds the given +other+ sample source to this multiplier.
        def *(other)
          if other.is_a?(Numeric)
            @constant *= other
          else
            raise "Multiplicand #{other} is already present on multiplier #{self}" if @multiplicands.include?(other)
            other.or_for(nil) if other.respond_to?(:or_for) # Default to playing forever
            other.or_at(1) if other.respond_to?(:or_at) # Keep amplitude high
            add(other)
          end

          self
        end
      end
    end
  end
end
