module MB
  module Sound
    module Plan
      # The Ruby mirror of mb_vec_exp2.h, the vectorizable 2^x of
      # Plan.precision :fast (the default) for note frequencies
      # (Op::NoteFreq) and powers of a constant base (Op::Pow): the same
      # double operations with Numo DFloat arithmetic, so it gives the C
      # kernel's floats exactly.  Matched libm's pow on every float tested
      # (see the header); counted as within TOLERANCE.
      module VecExp2
        # |x| limit (see MB_EXP2_LIMIT).
        LIMIT = 200.0

        # 1.5 * 2^52 (round to the nearest integer by adding and subtracting).
        ROUND = 6755399441055744.0

        LN2 = 0.6931471805599453

        # Taylor coefficients 1/n!, n = 11 down to 3 (as in the header).
        COEFFS = [39916800.0, 3628800.0, 362880.0, 40320.0, 5040.0, 720.0, 120.0, 24.0, 6.0].map { |d| 1.0 / d }.freeze

        # The largest difference from libm's pow allowed in check mode and
        # specs, relative to the output's level: two float steps (no
        # difference was found in testing).
        TOLERANCE = 2.4e-7

        # 2^x for a DFloat +x+ (a new DFloat).
        def self.exp2(x)
          x = Numo::DFloat.cast(x).dup
          x[x < -LIMIT] = -LIMIT
          x[x > LIMIT] = LIMIT
          m = x + ROUND
          kf = m - ROUND
          f = x - kf
          f = f * LN2
          p = f * COEFFS[0]
          COEFFS[1..].each do |c|
            p = p + c
            p = p * f
          end
          p = p + 0.5
          p = p * f
          p = p + 1.0
          p = p * f
          p = p + 1.0
          p * (Numo::DFloat.new(kf.length).fill(2.0)**kf)
        end

        # tfrq * 2^((a - tnum) / 12) as an SFloat (mb_vec_note_freq).
        def self.note_freq(a, tnum, tfrq)
          x = Numo::DFloat.cast(a) - tnum.to_f
          x = x / 12.0
          Numo::SFloat.cast(exp2(x) * tfrq.to_f)
        end

        # a ** b as an SFloat (mb_vec_pow): 2^(b log2 a) where a is positive
        # and finite and b finite, Numo's float power elsewhere.
        def self.pow(a, b)
          a = Numo::SFloat.cast(a)
          b = Numo::SFloat.cast(b)
          ad = Numo::DFloat.cast(a)
          bd = Numo::DFloat.cast(b)
          ok = (ad > 0) & (ad < Float::INFINITY) & bd.isfinite
          la = Numo::NMath.log2(ad)
          x = bd * la
          x[~ok] = 0.0
          out = Numo::SFloat.cast(exp2(x))
          unless ok.all?
            idx = (~ok).where
            out[idx] = (a[idx].dup.inplace ** b[idx]).not_inplace!
          end
          out
        end
      end
    end
  end
end
