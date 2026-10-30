module MB
  module Sound
    class Param
      # The one range mapping (knobs-1, 2026-10-30; arch-session section 1):
      # how a 0..1 position maps onto a span of base-unit numbers from +lo+
      # (position 0) to +hi+ (position 1) along +curve+ (:exp logarithmic,
      # anything else linear), and back.  Param#position/#value, knob specs
      # (GraphNode::Knob::Spec), MIDI controller specs (MIDI::ControlSpec,
      # centered ones as two scales from the center), knob ramps (in C too:
      # #ramp_terms), crossfades and gesture curves (#between), Knob#mod
      # (#shift), and envelope velocity peaks (Envelope.velocity_peak, the
      # mirror of the C env_peak) all read it, so a knob, a controller, and
      # a slider on the same range answer alike.
      #
      # The formulas (kept as they were in the knob ramp kernel, the
      # controller map, and the envelope kernel, so knobs sound the same):
      #
      #     value     exp: lo * (hi / lo) ** pos      linear: lo + (hi - lo) * pos
      #     position  exp: log(v / lo) / log(hi / lo) linear: (v - lo) / (hi - lo)
      #     ramp      exp: exp((t * k + a) + b)       linear: t * k + a
      #               (k, a, b from #ramp_terms: the knob_ramp kernel's)
      #
      # +lo+ may be above +hi+ (inverted controllers, velocity ranges that
      # fall); :exp needs both on the same side of 0.  Positions outside
      # 0..1 give values outside the span.  The class functions take the
      # span as arguments (no allocation on hot paths); a Scale holds one.
      class Scale < Data.define(:lo, :hi, :curve)
        # The value at +pos+ (a Float, or a Numo::DFloat of positions) on
        # the span +lo+..+hi+ along +curve+.
        def self.value(pos, lo, hi, curve)
          if curve == :exp
            pos.is_a?(Numo::NArray) ? (hi / lo) ** pos * lo : lo * (hi / lo) ** pos
          else
            pos.is_a?(Numo::NArray) ? pos * (hi - lo) + lo : lo + (hi - lo) * pos
          end
        end

        # The position of +v+ (a number, or a Numo::DFloat) on the span
        # +lo+..+hi+ along +curve+ (the inverse of .value).
        def self.position(v, lo, hi, curve)
          if curve == :exp
            v.is_a?(Numo::NArray) ? Numo::NMath.log(v / lo) / Math.log(hi / lo) : Math.log(v.to_f / lo) / Math.log(hi / lo)
          else
            v.is_a?(Numo::NArray) ? (v - lo) / (hi - lo) : (v.to_f - lo) / (hi - lo)
          end
        end

        def initialize(lo:, hi:, curve: :linear)
          lo = lo.to_f
          hi = hi.to_f
          c = curve == :exp ? :exp : :linear
          raise ArgumentError, "An exponential scale can't include or cross 0 (got #{lo}..#{hi})" if c == :exp && !(lo * hi > 0)
          super(lo: lo, hi: hi, curve: c)
        end

        # A Scale over +range+ (base-unit numbers) with +curve+.
        def self.of(range, curve)
          new(lo: range.begin, hi: range.end, curve: curve)
        end

        # True for a logarithmic scale.
        def exp?
          curve == :exp
        end

        # The span as a Range.
        def range
          lo..hi
        end

        # The value at position +pos+ (see .value).
        def value(pos)
          Scale.value(pos, lo, hi, curve)
        end

        # The position of +v+ (see .position).
        def position(v)
          Scale.position(v, lo, hi, curve)
        end

        # The terms [k, a, b] of a move from value +from+ to value +to+ in
        # this scale, so the value +t+ of the way there (0..1, a curve's
        # output) is exp((t * k + a) + b) on an :exp scale and t * k + a on
        # a linear one: what knob ramps compute (Knob#ramp_values, the C
        # FastArithmetic.knob_ramp, Knob#value_at) and #between reads.
        def ramp_terms(from, to)
          if curve == :exp
            r = Math.log(hi / lo)
            p0 = position(from)
            [r * (position(to) - p0), Math.log(lo), p0 * r]
          else
            [to - from, from, 0.0]
          end
        end

        # The value +t+ of the way from +a+ to +b+ in this scale (+t+ a
        # Float or a Numo::DFloat; crossfades between snapshots, gesture
        # curves): even in pitch on an :exp scale.
        def between(a, b, t)
          k, x, y = ramp_terms(a, b)
          if curve == :exp
            t.is_a?(Numo::NArray) ? Numo::NMath.exp(t * k + x + y) : Math.exp(t * k + x + y)
          else
            t * k + x
          end
        end

        # +x+ (a number or a graph node) moved by +by+ (a number or a node,
        # e.g. an LFO) times +amount+ positions: multiplied by a power of
        # the span's ratio on an :exp scale (octaves for a knob over
        # 100..800 Hz moved by 1/3), shifted by a share of the span on a
        # linear one.  Knob#mod's baseline plus modulation.
        def shift(x, by, amount)
          if curve == :exp
            x * (2.0 ** (by * (amount.to_f * Math.log2(hi / lo))))
          else
            x + by * (amount.to_f * (hi - lo))
          end
        end
      end
    end
  end
end
