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
        include SampleRateHelper
        include ArithmeticNodeHelper

        # The constant value by which the output will be multiplied.
        attr_accessor :constant

        # The graph sample rate (irrelevant for a multiplier).
        #
        # TODO: should there be a way of indicating a sample-rate-independent
        # node type?
        attr_reader :sample_rate

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
        def initialize(*multiplicands, stop_early: true, sample_rate: nil)
          @constant = 1
          @multiplicands = {}
          @sample_rate = sample_rate&.to_f

          setup_buffer(length: 1024)

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

          multiplicands.each_with_index do |m, idx|
            check_rate(m, idx) if m.respond_to?(:sample_rate)
          end

          raise 'No sample rate given via constructor or multiplicands' unless @sample_rate
        end

        # Calls the #sample methods of all multiplicands, multiplies them
        # together with the initial #constant value, and returns the result.
        #
        # If any multiplicand (or every multiplicand if stop_early was set to
        # false in the constructor) returns nil or an empty buffer, then this
        # method will return nil.  Similarly if there is a short read, if
        # stop_early is true then all inputs will be truncated to the shortest
        # buffer, or if stop_early is false than all short inputs will be
        # zero-padded.
        def sample(count)
          arithmetic_sample(count, sources: @multiplicands, pad: 1, fill: @constant, stop_early: @stop_early) do |retbuf, inputs|
            inputs.each.with_index do |(v, _), idx|
              retbuf.inplace * v
            end
          end
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
          raise "Multiplicand may not be an Array" if multiplicand.is_a?(Array)
          check_rate(multiplicand)
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

        # Adds the given +other+ sample source to this multiplier, or
        # multiplies the constant by +other+ if it is a Numeric.
        def *(other)
          if other.is_a?(Numeric)
            @constant *= other
          else
            raise "Multiplicand #{other} is already present on multiplier #{self}" if @multiplicands.include?(other)
            other.or_for(nil) if other.respond_to?(:or_for) # Default to playing forever
            other.or_at(1) if other.respond_to?(:or_at) # Keep amplitude high
            other.at_rate(@sample_rate) if other.respond_to?(:at_rate) # Match sample rates
            add(other)
          end

          self
        end
      end
    end
  end
end
