module MB
  module Sound
    module Plot
      # A filter's magnitude response in dB from its transfer function's
      # coefficients, written into a reused SFloat without allocating
      # (ui-wave-perf-1: the sound-design screen's live filter curves, every
      # frame).  The C kernel is FastUI.response_db; #db_ruby is its Ruby
      # mirror (the same formula in Numo, within 1e-4 dB), registered as the
      # :plot_response kernel (MB::Sound::Kernels).
      #
      #     b = Array.new(5, 0.0); a = Array.new(5, 0.0)
      #     filter.z_polynomials(b, a)            # Filter::FourPole, Filter::SVF
      #     out = Numo::SFloat.new(256)
      #     Plot::Response.db(out, b, a, 48000, 20, 23976, -60.0)
      #
      # H(z) = B(z^-1) / A(z^-1), +b+ and +a+ Arrays of up to 16 numbers,
      # lowest power first; out.size frequencies spaced evenly in log
      # frequency from +lo+ to +hi+ Hz (as Presets.response_db spaces them);
      # values below +floor+ dB, and 0/0, read +floor+.
      module Response
        module_function

        # Writes the response into +out+ through the :plot_response kernel.
        # Returns +out+.
        def db(out, b, a, rate, lo, hi, floor)
          Kernels.plot_response(out, b, a, rate.to_f, lo.to_f, hi.to_f, floor.to_f)
        end

        # The Ruby mirror of FastUI.response_db (same arguments and result).
        def db_ruby(out, b, a, rate, lo, hi, floor)
          raise ArgumentError, 'The output must be a contiguous 1D Numo::SFloat' unless out.is_a?(Numo::SFloat) && out.ndim == 1
          raise FrozenError, "can't modify frozen #{out.class}" if out.frozen?
          [[b, 'numerator'], [a, 'denominator']].each do |c, name|
            raise TypeError, "wrong argument type #{c.class} (expected Array)" unless c.is_a?(Array)
            raise ArgumentError, "The #{name} coefficients must be 1 to 16 numbers (got #{c.length})" unless (1..16).cover?(c.length)
          end
          rate = rate.to_f
          lo = lo.to_f
          hi = hi.to_f
          floor = floor.to_f
          unless rate > 0 && lo > 0 && hi > 0 && rate.finite? && lo.finite? && hi.finite? && !floor.nan?
            raise ArgumentError, 'The rate and frequencies must be positive and finite, and the floor a number'
          end
          n = out.size
          return out if n == 0

          l0 = Math.log10(lo)
          step = n > 1 ? (Math.log10(hi) - l0) / (n - 1) : 0.0
          f = 10.0**(Numo::DFloat.new(n).seq * step + l0)
          w = f * (2.0 * Math::PI / rate)
          z = Numo::DComplex.cast(Numo::NMath.cos(w)) - Numo::DComplex.cast(Numo::NMath.sin(w)) * 1i
          num = b[0...-1].reverse.inject(Numo::DComplex.new(n).fill(b[-1].to_f)) { |acc, c| acc * z + c.to_f }
          den = a[0...-1].reverse.inject(Numo::DComplex.new(n).fill(a[-1].to_f)) { |acc, c| acc * z + c.to_f }
          mag = Numo::NMath.sqrt(num.abs**2 / den.abs**2)
          floor_mag = 10.0**(floor / 20.0)
          mag[~mag.ge(floor_mag)] = floor_mag
          out.store(Numo::SFloat.cast(20 * Numo::NMath.log10(mag)))
          out
        end
      end

      Kernels.register :plot_response, c: FastUI.method(:response_db), ruby: Response.method(:db_ruby), group: :fast_ui, tolerance: 1e-4
    end
  end
end
