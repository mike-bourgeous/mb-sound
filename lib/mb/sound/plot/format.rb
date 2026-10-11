module MB
  module Sound
    module Plot
      # One tick on an axis: its data +value+, its +label+ (String, or nil
      # for an unlabeled minor tick), and whether it is +major+ (gets a grid
      # line).
      Tick = Data.define(:value, :label, :major) do
        def initialize(value:, label: nil, major: true)
          super
        end
      end

      # Number formatting for tick labels: nice steps, shared decimals, and
      # SI prefixes.
      module Format
        SI_PREFIXES = {
          -12 => 'p', -9 => 'n', -6 => 'µ', -3 => 'm', 0 => '', 3 => 'k', 6 => 'M', 9 => 'G',
        }.freeze

        module_function

        # A nice step (1, 2, or 5 times a power of ten) for about +count+
        # intervals over +span+.
        def nice_step(span, count)
          span = span.to_f.abs
          return 1.0 if span == 0 || !span.finite?

          raw = span / [count, 1].max
          mag = 10.0**Math.log10(raw).floor
          f = raw / mag
          nice = f < 1.5 ? 1 : f < 3 ? 2 : f < 7 ? 5 : 10
          nice * mag
        end

        # Multiples of +step+ from +lo+ to +hi+ (inclusive, within a tiny
        # tolerance), rounded to the step's precision.
        def steps(lo, hi, step)
          lo, hi = hi, lo if lo > hi
          first = (lo / step - 1e-9).ceil
          last = (hi / step + 1e-9).floor
          digits = [-Math.log10(step).floor + 1, 0].max
          (first..last).map { |k| (k * step).round(digits) + 0.0 }
        end

        # Decimals needed to show values spaced +step+ apart.
        def decimals(step)
          return 0 if step <= 0 || !step.finite?

          d = -Math.log10(step * 1.000001).floor
          d = 0 if d < 0
          # 2.5, 0.25: one more digit when the step isn't a single digit
          d += 1 if ((step / 10.0**-d) - (step / 10.0**-d).round).abs > 1e-6
          d
        end

        # Formats Numeric +values+ (spaced +step+ apart) as tick labels with
        # shared decimals.  With +si+, large or small values get an SI
        # prefix chosen from the largest magnitude (1k, 2.5k, 10M).
        def labels(values, step, si: false)
          return [] if values.empty?

          exp = 0
          if si
            big = values.map(&:abs).max
            exp = big > 0 ? (Math.log10(big * 1.000001) / 3).floor * 3 : 0
            exp = exp.clamp(-12, 9)
            exp = 0 if exp < 0 && si == :up
          end
          scale = 10.0**exp
          d = decimals(step / scale)
          values.map { |v|
            s = format("%.#{d}f", v / scale)
            s = s.sub(/\A-(0\.?0*)\z/, '\1') # no negative zero
            s + SI_PREFIXES[exp]
          }
        end

        # A compact label for any single +value+ (for legends, colorbars,
        # and readouts): about +digits+ significant digits.
        def value(v, digits: 3, unit: nil)
          return v.to_s unless v.is_a?(Numeric)
          return v.to_s if v.respond_to?(:finite?) && !v.finite?

          s = v == 0 ? '0' : format("%.#{digits}g", v)
          s = s.sub(/e\+?(-?)0*(\d+)/, 'e\1\2')
          unit ? "#{s} #{unit}" : s
        end
      end
    end
  end
end
