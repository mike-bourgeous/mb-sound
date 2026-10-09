module MB
  module Sound
    module Plan
      # The Ruby mirror of mb_vec_sine.h, the vectorizable sine of
      # Plan.precision :fast (the default): the same float operations with
      # Numo SFloat arithmetic, so it gives the C kernel's floats exactly.
      # Within about 5e-7 of the exact sine (-126 dB; see
      # Op::Tone::FAST_TOLERANCE).
      module VecSine
        # 1.5 * 2^52 (round to the nearest integer by adding and subtracting).
        ROUND = 6755399441055744.0

        # The coefficients and 2 pi as their float values (see the header).
        S3 = -0.166666672
        S5 = 0.00833333377
        S7 = -0.000198412701
        S9 = 2.75573188e-06
        S11 = -2.50521079e-08
        TWO_PI = 6.28318548

        # sin(2 pi (phases + phase_mod)) * gain + offset as an SFloat, for
        # +phases+ in cycles (a DFloat from Tone#phases_ruby) and
        # +phase_mod+ in cycles (a number or an NArray; real parts).
        def self.shape_ruby(phases, phase_mod, gain, offset)
          pm = phase_mod
          if pm.is_a?(Numo::NArray)
            pm = pm.real if pm.is_a?(Numo::SComplex) || pm.is_a?(Numo::DComplex)
            pm = Numo::DFloat.cast(pm)
          else
            pm = (pm || 0).to_f
          end

          r = phases + pm
          r = Numo::DFloat.cast(r) unless r.is_a?(Numo::NArray)
          k = (r + ROUND) - ROUND
          x = Numo::SFloat.cast(r - k)

          a = x.abs
          a = -a + 0.25
          a = a.abs
          a = -a + 0.25
          f = a.copysign(x)
          t = f * TWO_PI
          t2 = t * t
          p = t2 * S11
          p = p + S9
          p = p * t2
          p = p + S7
          p = p * t2
          p = p + S5
          p = p * t2
          p = p + S3
          p = p * t2
          p = p * t
          s = t + p
          s = s * gain.to_f
          s + offset.to_f
        end
      end
    end
  end
end
