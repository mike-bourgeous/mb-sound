module MB
  module Sound
    class Filter
      # Whenever the incoming sample value changes, this filter draws a
      # smoothstep curve of constant length (given to the constructor) from the
      # current value to the new value.  That is, each step change in the input
      # is replaced by a longer smoothstep curve in the output.  This is most
      # useful for values that change infrequently.
      #
      # TODO: Use an FIR filter instead of triggering on step changes?
      class Smoothstep < Filter
        # The sample rate given to the constructor, in Hz.
        attr_reader :sample_rate

        # The duration of a full transition in samples.
        attr_reader :fade_samples

        # The duration of a full transition in seconds, quantized to sample
        # rate (so this value may not exactly match a value passed to the
        # constructor).
        attr_reader :fade_seconds

        # Initializes a smoothstep signal interpolator (see the class
        # description).
        #
        # +:rate+ is the sample rate of the system in Hz.
        # +:samples+ is the duration of a full transition in samples.  Only
        #            one of +:samples+ or +:seconds+ may be specified, not
        #            both.
        # +:seconds+ is the duration of a full transition in seconds.  Only one
        #            of +:samples+ or +:seconds+ may be specified, not both.
        def initialize(sample_rate:, samples: nil, seconds: nil)
          raise 'Sample rate must be a positive number' unless rate.is_a?(Numeric) && rate > 0
          @sample_rate = rate.to_f

          raise 'Specify a transition duration in either samples or seconds' if samples.nil? && seconds.nil?
          raise 'Specify only one of samples or seconds, not both' unless samples.nil? || seconds.nil?

          if samples
            self.fade_samples = samples
          else
            self.fade_seconds = seconds
          end

          reset
        end

        # Sets the duration of a transition in samples.
        def fade_samples=(samples)
          raise 'Sample duration must be a Numeric' unless samples.is_a?(Numeric)

          samples = samples.round
          raise 'Sample duration must be >= 1' if samples <= 0

          @fade_samples = samples
          @fade_seconds = @fade_samples / @sample_rate
        end

        # Sets the duration of a transition in seconds.
        def fade_seconds=(seconds)
          @fade_samples = (seconds * @sample_rate).round
        end

        # Resets the output to 0, or to the given value.
        def reset(initial_value = 0.0)
          @s = initial_value.to_f
          @old = @s
          @v = @s
          @d = 0
          @t = @fade_samples
        end

        # Processes the given array of samples, updating the state of the
        # smoothstep interpolator along the way.  Returns the
        # smoothstep-limited result.  Supports in-place processing of NArray.
        def process(samples)
          samples.map { |s|
            if s != @s
              @old = @v
              @s = s
              @d = @s - @old
              @t = 0
            end

            # TODO: Support other interpolators?
            # TODO: Port to C if it's slow?
            if @t < @fade_samples
              @t += 1
              @v = MB::FastSound.smoothstep(@t.to_f / @fade_samples) * @d + @old
            else
              @v = s
            end
          }
        end

        # Returns the current output value without changing the filter state.
        def peek
          @v
        end
      end
    end
  end
end
