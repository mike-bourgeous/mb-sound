module MB
  module Sound
    class Filter
      # Implements a 6th-order phase difference network that converts a
      # real-valued input signal to a pair of complex-valued output signals
      # corresponding to the cosine and sine components of an analytic signal.
      # Both of these components have some varying absolute phase shift
      # relative to the input signal, but a consistent relative phase shift of
      # ~90 degrees relative to each other.
      #
      # Thus this is not directly a Hilbert transform of the input signal, but
      # rather the sine output is the Hilbert transform of the cosine output.
      #
      # The continuous-time pole frequencies in Hz were taken from CSound's
      # hilbertset function written by Sean M. Costello, which in turn were
      # taken from "Musical Engineer's Handbook" by Bernie Hutchins.  I then
      # converted them to angular frequencies to simplify the rest of the math.
      class HilbertIIR < Filter
        # Converted from original: cosine.map { |p| (p * 15 * Math::PI).round(4) }
        COSINE_POLES = [59.018, 262.3434, 1052.8561, 4223.5776, 17190.3897, 130538.4244]

        # Converted from original: sine.map { |p| (p * 15 * Math::PI).round(4) }
        SINE_POLES = [17.007, 129.176, 525.7754, 2109.1758, 8464.591, 37626.4374]

        # Creates a Hilbert IIR filterbank that returns cosine and sine components for
        def initialize(rate: 48000)
          @rate = rate.to_f

          # TODO: combine pairs of poles to use three biquads per value
          # TODO: experiment with combining cosine and sine coefficients into
          # complex values and computing biquads using complex coefficients
          # TODO: find out why the ratios between successive poles are
          # 3.47, 2.19, 2.03, 2.00, 2.00, 2.00, 2.00, 2.00, 2.03, 2.19, 3.47

          @filters = [
            filters_for_poles(COSINE_POLES),
            filters_for_poles(SINE_POLES)
          ]
        end

        # Returns cosine and sine components for an analytic signal form of
        # +data+ (with some phase variation relative to the input; see the
        # class comment).
        def process(data)
          @filters.map { |f| f.process(data) }
        end

        def cosine_polezero
          @filters[0].polezero
        end

        def sine_polezero
          @filters[1].polezero
        end

        def cosine_response(w)
          @filters[0].response(w)
        end

        def sine_response(w)
          @filters[1].response(w)
        end

        private

        # Converts an Array of angular frequencies (radians per second) into
        # a filter chain of MB::Sound::Filter::Biquads.
        def filters_for_poles(poles)
          FilterChain.new(
            *(0..(poles.length - 1)).step(0.1).map { |idx|
              i1 = idx.floor
              i2 = idx.ceil
              d = idx - i1
              v1 = poles[i1]
              v2 = poles[i2]
              p = (v1 ** (1.0 - d)) * (v2 ** d)
              a = p / @rate
              b = (1 - a) / (1 + a)
              MB::Sound::Filter::Biquad.new(-b, 1, 0, -b, 0)
            }
          )
        end
      end
    end
  end
end
