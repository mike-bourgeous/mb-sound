module MB
  module Sound
    class Wavetable
      # Pre-emphasis for the :optimal interpolator.  Niemitalo's optimal
      # interpolators trade a flat passband for the best rejection of images
      # (his "modified SNR" leaves out passband droop, which a fixed filter
      # can undo): at 4x oversampling the 4-point, 4th-order design droops
      # 11% (-1 dB) at the top of the band, 0.3% at a quarter of it.  So
      # levels read with :optimal store each harmonic divided by the
      # interpolator's response at its frequency (see .gain), and the
      # interpolated waveform is flat to within about 1e-6.  Other
      # interpolators read unemphasized levels (see Wavetable#levels).
      module Emphasis
        # Gauss-Legendre quadrature nodes and weights on 0..1.
        def self.gauss_legendre(n)
          nodes = []
          weights = []
          (1..n).each do |i|
            x = Math.cos(Math::PI * (i - 0.25) / (n + 0.5))
            dp = 0.0
            20.times do
              p0 = 1.0
              p1 = x
              (2..n).each do |k|
                p0, p1 = p1, ((2 * k - 1) * x * p1 - (k - 1) * p0) / k
              end
              dp = n * (x * p1 - p0) / (x * x - 1)
              dx = p1 / dp
              x -= dx
              break if dx.abs < 1e-16
            end
            nodes << (1 - x) / 2
            weights << 1.0 / ((1 - x * x) * dp * dp)
          end
          [nodes, weights]
        end

        NODES, WEIGHTS = gauss_legendre(24)

        # The frequency response of interpolator +code+ (see INTERPOLATIONS)
        # at +f+ cycles per stored sample (a Float or DFloat): the gain of a
        # complex sinusoid through it (images left out).
        def self.response(code, f)
          # Each tap's weight at each quadrature node, from unit impulses
          @weights ||= {}
          taps, weights = @weights[code] ||= begin
            all = (-KernelRuby::SINC_HALF..(KernelRuby::SINC_HALF + 1)).to_a
            w = all.map { |k|
              row = Numo::DFloat.zeros(1, 2 * GUARD + 4)
              row[0, GUARD + k] = 1.0
              NODES.map { |x| KernelRuby.interpolate(row, 0, nil, 0.0, x, code, GUARD) }
            }
            used = all.each_index.reject { |t| w[t].all?(&:zero?) } # 4-point interpolators use 4 taps
            [used.map { |t| all[t] }, used.map { |t| w[t] }]
          end

          f = Numo::DFloat.cast(f) unless f.is_a?(Numeric)
          sum = f.is_a?(Numeric) ? 0.0 : Numo::DFloat.zeros(f.length)
          NODES.each_with_index do |x, i|
            taps.each_with_index do |k, t|
              sum = sum + (f.is_a?(Numeric) ? Math.cos(2 * Math::PI * f * (k - x)) : Numo::NMath.cos(f * (2 * Math::PI * (k - x)))) * (weights[t][i] * WEIGHTS[i])
            end
          end
          sum
        end

        # Grid points per cycle per sample for .gains (linear interpolation
        # between them is within 1e-7 of the response).
        GRID = 16384

        # Interpolators whose levels are emphasized.
        INTERPOLATORS = [:optimal].freeze

        # The gain that undoes +interpolation+'s droop at +f+ cycles per
        # stored sample.
        def self.gain(f, interpolation = :optimal)
          1.0 / response(INTERPOLATIONS.fetch(interpolation), f)
        end

        # Gains for bins 0...+count+ of a +length+-sample level read with
        # +interpolation+ (a DFloat; interpolated from a fine grid, within
        # about 1e-7).
        def self.gains(count, length, interpolation = :optimal)
          @gain_cache ||= {}
          @gain_cache[[count, length, interpolation]] ||= compute_gains(count, length, interpolation).freeze
        end

        # See .gains (uncached).
        def self.compute_gains(count, length, interpolation)
          @grids ||= {}
          grid = @grids[interpolation] ||= (1.0 / response(INTERPOLATIONS.fetch(interpolation), Numo::DFloat.new(GRID / 2 + 2).seq / GRID)).freeze
          pos = Numo::DFloat.new(count).seq * (GRID.to_f / length)
          raise ArgumentError, 'Emphasis only goes up to half the stored sample rate' if count > 0 && pos[-1] > GRID / 2
          idx = pos.floor.cast_to(Numo::Int64)
          frac = pos - idx
          a = grid[idx]
          b = grid[idx + 1]
          a + (b - a) * frac
        end
      end
    end
  end
end
