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

        # Creates a filter chain that returns cosine and sine components for a
        # single input at the given sample +:rate+.  For experimentation,
        # filters may be skipped by passing indices to skip as an Array in
        # +:skip+, or values may be +:scaled+, +:stretched+, or +:offset+.
        def initialize(rate: 48000, skip: nil, scale: nil, stretch: nil, offset: nil, interp: nil)
          @skip = skip
          @scale = scale&.to_f || 1.0
          @stretch = stretch&.to_f || 1.0
          @offset = offset&.to_f || 0.0
          @rate = rate.to_f

          # Empirical testing shows scaling by 2.25 puts 20Hz and 20kHz at the
          # same error, at about 83 degrees instead of 90.
          @scale *= 2.25

          # TODO: combine pairs of poles to use three biquads per value
          # TODO: experiment with combining cosine and sine coefficients into
          # complex values and computing biquads using complex coefficients
          # TODO: find out why the ratios between successive poles are
          # 3.47, 2.19, 2.03, 2.00, 2.00, 2.00, 2.00, 2.00, 2.03, 2.19, 3.47
          #

          if interp
            # I read somewhere that poles must alternate between the cosine and
            # sine set, so this is an experiment with adding more poles but
            # then still alternating.
            all_poles = SINE_POLES.zip(COSINE_POLES).flatten
            interp_poles = (0.0..(all_poles.length - 1)).step(1.0 / interp).map { |idx|
              MB::M.fractional_index(all_poles, idx)
            }
            sines, cosines = interp_poles.partition.with_index { |_, idx| idx.even? }
          else
            sines = SINE_POLES
            cosines = COSINE_POLES
          end

          @filters = [
            filters_for_poles(cosines),
            filters_for_poles(sines)
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
            *poles.map.with_index { |p, idx|
              next if @skip && @skip.include?(idx.to_i)
              p *= @stretch
              a = (p * @scale * (1 + (@stretch - 1) * idx / (poles.length - 1)) + @offset) / @rate
              b = (1 - a) / (1 + a)
              MB::Sound::Filter::Biquad.new(-b, 1, 0, -b, 0)
            }.compact
          )
        end
      end
    end
  end
end
