module MB
  module Sound
    module Plan
      # Fast sine and cosine for Plan.precision = :fast (the Ruby mirror of
      # mb_fast_math.h, giving identical doubles): one range reduction to a
      # quarter cycle and Taylor polynomials to degree 11/10 on
      # |theta| <= pi/4, error under 2e-10 before rounding to float32.
      module FastMath
        HALF_PI = 1.5707963267948966
        TWO_PI = 2.0 * Math::PI

        # [sin, cos] of 2 pi +x+ (+x+ in cycles).
        def self.sincos_cycles(x)
          t = x * 4.0
          q = (t + 0.5).floor.to_f
          f = t - q
          th = f * HALF_PI
          t2 = th * th

          ps = t2 * (1.0 / 110.0)
          ps = 1.0 - ps
          ps *= t2
          ps *= (1.0 / 72.0)
          ps = 1.0 - ps
          ps *= t2
          ps *= (1.0 / 42.0)
          ps = 1.0 - ps
          ps *= t2
          ps *= (1.0 / 20.0)
          ps = 1.0 - ps
          ps *= t2
          ps *= (1.0 / 6.0)
          ps = 1.0 - ps
          sn = th * ps

          pc = t2 * (1.0 / 90.0)
          pc = 1.0 - pc
          pc *= t2
          pc *= (1.0 / 56.0)
          pc = 1.0 - pc
          pc *= t2
          pc *= (1.0 / 30.0)
          pc = 1.0 - pc
          pc *= t2
          pc *= (1.0 / 12.0)
          pc = 1.0 - pc
          pc *= t2
          pc *= 0.5
          cs = 1.0 - pc

          case (q - 4.0 * (q * 0.25).floor).to_i
          when 0 then [sn, cs]
          when 1 then [cs, -sn]
          when 2 then [-sn, -cs]
          else [-cs, sn]
          end
        end

        # The fast twin of Tone.shape_ruby for :sine and :complex_sine:
        # +phases+ in cycles (a DFloat), +phase_mod+ radians (a number or
        # NArray, real parts), as DFloat or DComplex (sin, -cos).
        def self.shape_ruby(wave_type, phases, phase_mod)
          n = phases.length
          pm = phase_mod.is_a?(Numo::NArray) ? Numo::DFloat.cast(phase_mod.is_a?(Numo::SComplex) || phase_mod.is_a?(Numo::DComplex) ? phase_mod.real : phase_mod).to_a : Array.new(n, (phase_mod || 0).to_f)
          ph = phases.to_a
          if wave_type == :complex_sine
            out = Numo::DComplex.zeros(n)
            n.times { |i| s, c = sincos_cycles(ph[i] + pm[i] * (1.0 / TWO_PI)); out[i] = Complex(s, -c) }
          else
            out = Numo::DFloat.zeros(n)
            n.times { |i| out[i] = sincos_cycles(ph[i] + pm[i] * (1.0 / TWO_PI))[0] }
          end
          out
        end
      end
    end
  end
end
