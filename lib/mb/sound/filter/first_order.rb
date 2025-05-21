module MB
  module Sound
    class Filter
      # Implements first-order low-pass and high-pass filters based on
      # experimentation with online filter generators, as well as pole-only (no
      # zero) filters.
      #
      # See http://www.dspguide.com/ch19/2.htm
      class FirstOrder < Biquad
        FILTER_TYPES = [
          :lowpass,
          :highpass,
          :lowpass1p,
          :highpass1p,
        ]

        attr_reader :filter_type, :sample_rate, :center_frequency

        # Initializes a first-order filter (one pole, maybe one zero) where
        # +filter_type+ is one of the symbols in FILTER_TYPES above.
        def initialize(filter_type, f_samp, f_center)
          set_parameters(filter_type, f_samp, f_center)
          super(@b0, @b1, @b2, @a1, @a2, sample_rate: f_samp)
        end

        # Recalculates filter coefficients based on the given filter parameters.
        def set_parameters(filter_type, f_samp, f_center)
          @filter_type = filter_type
          @sample_rate = f_samp
          @center_frequency = f_center

          omega = 2.0 * Math::PI * f_center / f_samp
          x = Math.exp(-omega)
          cosine = Math.cos(omega)
          sine = Math.sin(omega)

          case filter_type
          when :lowpass1p
            @a1 = -x
            @a2 = 0
            @b0 = 1.0 - x
            @b1 = 0
            @b2 = 0

          when :highpass1p
            # FIXME: this is nearly identical to :highpass and returns a zero in Biquad#polezero
            @a1 = -x
            @a2 = 0
            @b0 = 0.5 * (1.0 + x)
            @b1 = -0.5 * (1.0 + x)
            @b2 = 0

          when :lowpass
            @a1 = -cosine / (1.0 + sine) # TODO: why?
            @a2 = 0
            @b0 = (1.0 + @a1) * 0.5
            @b1 = @b0
            @b2 = 0

          when :highpass
            @a1 = -cosine / (1.0 + sine)
            @a2 = 0
            @b0 = (1.0 - @a1) * 0.5
            @b1 = -@b0
            @b2 = 0

          else
            raise "Invalid filter type #{filter_type.inspect}"
          end
        end
      end
    end
  end
end
