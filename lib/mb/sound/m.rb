module MB
  module Sound
    # Sound-related mathematical functions for clamping, scaling,
    # interpolating, etc.
    module M
      # Raises the given +value+ to the given +power+, but using the absolute
      # value function to prevent complex results.
      def self.safe_power(value, power)
        sign = value.positive? ? 1.0 : -1.0
        value.abs ** power * sign
      end

      # Scales a numeric value or NArray from from_range to to_range.  Converts
      # values to floats.
      #
      # Example:
      #   scale(5, 0..10, 0..1) # => 0.5
      #   scale(Numo::SFloat[5, 10], 0..10, 0..1) # => Numo::SFloat[0.5, 1.0]
      def self.scale(value, from_range, to_range)
        if value.is_a?(Numo::NArray)
          if value.length != 0 && !value[0].is_a?(Float)
            value = value.cast_to(Numo::SFloat)
          end
        elsif value.respond_to?(:to_f)
          value = value.to_f
        end

        in_min, in_max = from_range.min || from_range.first, from_range.max || from_range.last
        out_min, out_max = to_range.min || to_range.first, to_range.max || to_range.last
        ratio = (out_max.to_f - out_min.to_f) / (in_max.to_f - in_min.to_f)

        (value - in_min) * ratio + out_min
      end

      # Clamps the +value+ (or all values within an NArray) to be between +min+ and
      # +max+ (passing through NaN).  Ignores nil limits, so this can also be used
      # as min() or max() by passing nil for the unwanted limit (or pass nil for
      # both to do nothing).
      #
      # Note that for scalar values the types for +min+ and +max+ are preserved, so
      # pass the same type as +value+ if that matters to you.
      def self.clamp(min, max, value)
        if value.is_a?(Numo::NArray)
          return with_inplace(value, false) { |vnotinp|
            if vnotinp.length > 0 && vnotinp[0].is_a?(Integer) && (min || max)
              # Ensure that an int array clipped to float returns float
              vnotinp = vnotinp.cast_to(Numo::NArray[*[min, max].compact].class)
            end

            vnotinp.clip(min, max)
          }
        end

        value = value < min ? min : value if min
        value = value > max ? max : value if max
        value
      end

      # Converts a Ruby Array of any nesting depth to a Numo::NArray with a
      # matching number of dimensions.  All nested arrays at a particular depth
      # should have the same size (that is, all positions should be filled).
      #
      # Chained subscripts on the Array become comma-separated subscripts on the
      # NArray, so array[1][2] would become narray[1, 2].
      def self.array_to_narray(array)
        return array if array.is_a?(Numo::NArray)
        narray = Numo::NArray[array]
        narray.reshape(*narray.shape[1..-1])
      end

      # Sets in-place processing to +inplace+ on the given +narray+, then yields
      # the narray to the given block.
      def self.with_inplace(narray, inplace)
        was_inplace = narray.inplace?
        inplace ? narray.inplace! : narray.not_inplace!
        yield narray
      ensure
        was_inplace ? narray.inplace! : narray.not_inplace!
      end
    end
  end
end
