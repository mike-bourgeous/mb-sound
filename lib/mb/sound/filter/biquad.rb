require 'cmath'

module MB
  module Sound
    class Filter
      # Implements a biquad filter with internal state, so new samples can be
      # passed in chunks instead of having to process an entire file at once.
      #
      # See https://shepazu.github.io/Audio-EQ-Cookbook/audio-eq-cookbook.html
      # See https://www.earlevel.com/main/2013/10/13/biquad-calculator-v2/
      # See http://rs-met.com/documents/dsp/BasicDigitalFilters.pdf
      class Biquad < Filter
        attr_reader :b0, :b1, :b2, :a1, :a2

        # The sample rate for which the biquad's coefficients were generated,
        # as provided to the constructor.
        attr_reader :sample_rate

        # Initializes a biquad filter from the given set of poles and zeros.
        #
        # TODO: accept a total gain factor and/or normalize peak gain to 1.0
        # (poles+zeros alone do not indicate overall gain)
        def self.from_pole_zero(poles:, zeros:, sample_rate:)
          raise 'A biquad can only have two poles' if poles.length > 2
          raise 'A biquad can only have two zeros' if zeros.length > 2

          # The coefficients come from multiplying the two binomials for the
          # numerator and denominator to get the resulting quadratic equations,
          # where each pole is a binomial in the denominator, and each zero is
          # a binomial in the numerator.
          if poles.nil? || poles.empty?
            a0 = 1.0
            a1 = 0.0
            a2 = 0.0
          elsif poles.length == 1
            a0 = 1.0
            a1 = -poles[0]
            a2 = 0.0
          else
            a0 = 1.0
            a1 = -poles.reduce(0, &:+)
            a2 = poles.reduce(1, &:*)
          end

          if zeros.nil? || zeros.empty?
            b0 = 1
            b1 = 0
            b2 = 0
          elsif zeros.length == 1
            b0 = 1
            b1 = -zeros[0]
            b2 = 0
          else
            b0 = 1
            b1 = -zeros.reduce(0, &:+)
            b2 = zeros.reduce(1, &:*)
          end

          b0 /= a0
          b1 /= a0
          b2 /= a0
          a1 /= a0
          a2 /= a0

          self.new(b0, b1, b2, a1, a2, sample_rate: sample_rate)
        end

        # b0..b2 are numerator coefficients, a1..a2 denominator (all normalized
        # by a0); some references use the opposite notation
        def initialize(b0, b1, b2, a1, a2, sample_rate:)
          b0 = b0.real if MB::M.round(b0, 7).imag == 0
          b1 = b1.real if MB::M.round(b1, 7).imag == 0
          b2 = b2.real if MB::M.round(b2, 7).imag == 0
          a1 = a1.real if MB::M.round(a1, 7).imag == 0
          a2 = a2.real if MB::M.round(a2, 7).imag == 0

          @b0 = b0
          @b1 = b1
          @b2 = b2
          @a1 = a1
          @a2 = a2

          # TODO: would we ever see a fractional sample rate?
          raise "Sample rate must be a positive numeric (got #{sample_rate.inspect})" unless sample_rate.is_a?(Numeric) && sample_rate > 0
          @sample_rate = sample_rate.to_f

          reset
        end

        # Resets the filter's internal state as if it had received the given
        # value for a very long time.  The filter's output will be this value
        # multiplied by the DC gain (Biquad#response(0)).
        #
        # Returns the steady-state output value for the given input value.
        def reset(initial_value = 0)
          @x1 = initial_value
          @x2 = initial_value
          @y1 = initial_value * (@b0 + @b1 + @b2) / (1.0 + @a1 + @a2)
          @y2 = @y1
          @y1
        end

        # Returns an array with b0, b1, b2, a1, a2.
        def coefficients
          [@b0, @b1, @b2, @a1, @a2]
        end

        # Wraps Filter#impulse_response to preserve the filter's internal
        # state, allowing this function to be called on a filter that is in
        # active use.
        def impulse_response(count = 500)
          x1 = @x1
          x2 = @x2
          y1 = @y1
          y2 = @y2
          super(count).tap {
            @x1 = x1
            @x2 = x2
            @y1 = y1
            @y2 = y2
          }
        end

        # Returns the complex z-plane response of the filter transfer function at
        # the given angular frequency on the unit circle from 0 to Math::PI (0Hz
        # to fs/2).  Call .abs on the result to get the magnitude, and .arg to
        # get the phase.
        def response(omega)
          (
            @b0 * Math::E ** (2i * omega) + @b1 * Math::E ** (1i * omega) + @b2
          ) / (
            1.0 * Math::E ** (2i * omega) + @a1 * Math::E ** (1i * omega) + @a2
          )
        end

        # Returns the complex z-plane response at the given location of the Z
        # plane.  See also the #response method for calculating frequency
        # response on the unit circle.
        def z_response(z)
          z = z.to_c if z.is_a?(Numeric)

          # Numerator and denominator multiplied by z**2 to remove negative power
          # and thus remove division by zero at the origin
          numerator = @b0 * z ** 2 + @b1 * z + @b2
          denominator = 1.0 * z ** 2 + @a1 * z + @a2

          numerator / denominator
        end

        # Returns a Hash with the z-plane :poles and :zeros of the filter based
        # on its coefficients, using the quadratic formula.  Poles and zeroes
        # at the origin are omitted.
        def polezero
          # Poles
          # 0 = ax^2 + bx + c
          # 0 = @a2 * z^-2, @a1 * z^-1, 1.0*z^0 -- multiply by num/denom by z^2 to get rid of negative exponent
          # 0 = 1.0 * z^2 + @a1 * z^1 + @a2 * z^0
          # a = 1.0, b = @a1, c = @a2
          # Zeros
          # a = @b0, b = @b1, c = @b2
          {
            poles: MB::M.quadratic_roots(1.0, @a1, @a2).reject(&:zero?),
            zeros: MB::M.quadratic_roots(@b0, @b1, @b2).reject(&:zero?)
          }
        end

        # Processes +samples+ through the filter, updating the internal state
        # along the way.  If +reset+ is given, the internal state is reset to the
        # first sample before processing.
        #
        # If +samples+ is a Numo::NArray in in-place mode, then the samples will
        # be processed in-place, saving an array allocation.
        def process(samples)
          process_c(samples)
        end

        # Process a single real (not Complex) sample through the filter.
        def process_one(sample)
          out = MB::FastSound.biquad(@b0, @b1, @b2, @a1, @a2, sample, @x1, @x2, @y1, @y2)
          @y2 = @y1
          @y1 = out
          @x2 = @x1
          @x1 = sample
          out
        end

        # C loop, C math (much faster than pure Ruby)
        def process_c(samples)
          # FIXME: convert to SComplex/DComplex if coefficients are complex
          result, @x1, @x2, @y1, @y2 = MB::FastSound.biquad_narray(
            @b0, @b1, @b2, @a1, @a2,
            [samples, @x1, @x2, @y1, @y2]
          )

          result
        end

        # Ruby outer loop, C math (slightly faster than pure Ruby)
        def process_ruby_c(samples)
          if samples.is_a?(Numo::DComplex) || samples.is_a?(Numo::SComplex) || samples[0].is_a?(Complex)
            # Direct Form I
            samples.map do |x0|
              out = MB::FastSound.biquad_complex(@b0, @b1, @b2, @a1, @a2, x0, @x1, @x2, @y1, @y2)
              @y2 = @y1
              @y1 = out
              @x2 = @x1
              @x1 = x0
              out
            end
          else
            samples.map do |x0|
              out = MB::FastSound.biquad(@b0, @b1, @b2, @a1, @a2, x0, @x1, @x2, @y1, @y2)
              @y2 = @y1
              @y1 = out
              @x2 = @x1
              @x1 = x0
              out
            end
          end
        end

        # Ruby outer loop, Ruby math
        def process_ruby(samples)
          # Direct Form I
          samples.map do |x0|
            out = @b0 * x0 + @b1 * @x1 + @b2 * @x2 - @a1 * @y1 - @a2 * @y2
            out = 0 if out.abs < 1e-18 && @y2.abs < 1e-18 && @y1.abs < 1e-18
            @y2 = @y1
            @y1 = out
            @x2 = @x1
            @x1 = x0
            out
          end
        end

        # Processes one +sample+ through the filter, with +strength+ (a value
        # between 0.0 and 1.0) blending between the incoming +sample+ (at 0.0)
        # and the filter output (at 1.0).  The filter's internal state is updated
        # with the result.
        #
        # This was used in an experiment with content-adaptive filtering.
        def weighted_process(sample, strength = 1.0)
          out = @b0 * sample + @b1 * @x1 + @b2 * @x2 - @a1 * @y1 - @a2 * @y2
          out = 0 if out.abs < 1e-18 && @y2.abs < 1e-18 && @y1.abs < 1e-18
          out = strength * out + (1.0 - strength) * sample
          @y2 = @y1
          @y1 = out
          @x2 = @x1
          @x1 = sample
          out
        end
      end
    end
  end
end
