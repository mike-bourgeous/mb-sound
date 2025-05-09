module MB
  module Sound
    class Filter
      # A filter that applies a constant gain to its input.
      #
      # TODO: do we need this?  this might be superseded by the graph node system and its mixer and multiplier nodes
      class Gain < Filter
        # The filter gain (should be an integer or float).
        attr_accessor :gain

        attr_reader :sample_rate

        # Initializes a filter that applies the given constant +gain+.
        def initialize(gain, sample_rate:)
          @gain = gain
          @sample_rate = sample_rate
        end

        # Multiplies the sample(s) by the filter's gain value.
        def process(samples)
          samples * gain
        end

        # Does nothing, as the filter has no state.
        def reset(value = 0)
        end

        # Returns the filter's gain value regardless of +omega+.
        def response(omega)
          gain
        end
      end
    end
  end
end
