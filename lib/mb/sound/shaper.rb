require_relative 'fast_clip'

module MB
  module Sound
    # Waveshapers with antiderivative antialiasing (ADAA): soft clip, hard
    # clip, absolute value, and quantize.  A nonlinearity creates harmonics
    # above Nyquist that fold back down as inharmonic tones; first-order ADAA
    # replaces f(x[n]) with the average of f between the last two inputs,
    # (F(x[n]) - F(x[n-1])) / (x[n] - x[n-1]), using the antiderivative F.
    #
    # Plain ADAA also dulls the unclipped signal (-6 dB at 16 kHz), so each
    # shaper is split into x + g(x), with g = f - x zero wherever the shaper
    # is linear: ADAA applies to g only, and x passes through a half-sample
    # Thiran allpass so the two paths line up (flat level, half a sample of
    # delay).  The high band the ADAA midpoint loses (allpass minus
    # midpoint) is scaled by the shaper's mean slope over the two inputs
    # (.band_gain: 1 where linear, 0 where flat, so bright input beyond the
    # limits no longer leaks through the flat parts; 2026-11-10), and the
    # result is limited to the shaper's output range (:lo, :hi).  Measured at drive 4 into softclip(0.25, 1), non-harmonic power
    # below 20 kHz: 1 kHz -57.7 -> -71.6 dB (aliases below the fundamental
    # -68.7 -> -102), 3 kHz -30.6 -> -41.6 (-40.1 -> -66.7), about as good as
    # 2x oversampling below the fundamental, at a fraction of its cost.
    #
    # The DSL methods (GraphNode#softclip, #clip, #abs, #quantize) use ADAA;
    # #asoftclip, #aclip, #aabs, and #aquantize are the plain (aliased)
    # shapers, exact for control signals.  See GraphNode::Shaper.
    #
    # The C kernel is MB::Sound::FastClip.shape (the fast_clip extension);
    # .shape_ruby mirrors it exactly for testing.
    module Shaper
      TINY = 1e-6
      ALLPASS = 1.0 / 3.0

      MODES = [:softclip, :clip, :abs, :quantize].freeze

      # Parameters for +mode+ (see FastClip.shape): a Hash with :p1, :p2,
      # and for :softclip the curve constants :a, :b, :c, :k.
      def self.params(mode, p1, p2)
        case mode
        when :softclip
          t = p1.abs.to_f
          l = p2.abs.to_f
          raise ArgumentError, 'Limit must be greater than or equal to threshold' if l < t

          a = -(l - t) * (l - t)
          b = l
          c = l - 2.0 * t
          k = 0.5 * t * t - b * t - (a != 0 ? a * Math.log(t + c) : 0)
          { mode: mode, p1: t, p2: l, a: a, b: b, c: c, k: k, lo: -l, hi: l, trend: false }
        when :clip
          raise ArgumentError, 'Clip max must be greater than or equal to min' if p2 < p1
          { mode: mode, p1: p1.to_f, p2: p2.to_f, lo: p1.to_f, hi: p2.to_f, trend: false }
        when :abs
          { mode: mode, p1: p1.to_f, p2: p2.to_f, lo: 0.0, hi: Float::INFINITY, trend: false }
        when :quantize
          raise ArgumentError, 'Quantize step must be positive and finite' unless p1 > 0 && p1.to_f.finite?
          # The quantizer's high band keeps the identity's slope (see
          # mb_clip_run in mb_clip_shape.h)
          { mode: mode, p1: p1.to_f, p2: p2.to_f, lo: -Float::INFINITY, hi: Float::INFINITY, trend: true }
        else
          raise ArgumentError, "Unknown shaper #{mode.inspect}"
        end
      end

      # The plain shaper.
      def self.f(cp, x)
        case cp[:mode]
        when :softclip
          ax = x.abs
          return x if ax <= cp[:p1]

          v = cp[:a] / (ax + cp[:c]) + cp[:b]
          x < 0 ? -v : v
        when :clip
          x < cp[:p1] ? cp[:p1] : (x > cp[:p2] ? cp[:p2] : x)
        when :abs
          x.abs
        when :quantize
          cp[:p1] * (x / cp[:p1] + 0.5).floor.to_f
        end
      end

      # Ruby mirror of clip_band_gain in mb_clip_shape.h: the gain of the dry
      # path's high band for inputs +x1+..+x+ (+fx+, +fx1+ their shaped
      # values, +m+ their midpoint), the mean slope of the shaper (the block)
      # over them, or over TINY around +m+ for closer inputs, limited to
      # -1..1.
      def self.band_gain(x, x1, fx, fx1, m)
        d = x - x1
        w = if d.abs < TINY
              ma = m - 0.5 * TINY
              mb = m + 0.5 * TINY
              (yield(mb) - yield(ma)) / (mb - ma)
            else
              (fx - fx1) / d
            end
        w < -1.0 ? -1.0 : (w > 1.0 ? 1.0 : w)
      end

      # Limits +v+ to +lo+..+hi+ (the C clip_limit).
      def self.limit(v, lo, hi)
        v < lo ? lo : (v > hi ? hi : v)
      end

      # The antiderivative of g = f - x (see clip_g_integral in fast_clip.c).
      def self.g_integral(cp, x)
        case cp[:mode]
        when :softclip
          ax = x.abs
          return 0.0 if ax <= cp[:p1]

          v = cp[:b] * ax + cp[:k] - 0.5 * x * x
          v += cp[:a] * Math.log(ax + cp[:c]) if cp[:a] != 0
          v
        when :clip
          if x > cp[:p2]
            d = x - cp[:p2]
            -0.5 * d * d
          elsif x < cp[:p1]
            d = x - cp[:p1]
            -0.5 * d * d
          else
            0.0
          end
        when :abs
          x < 0 ? -x * x : 0.0
        when :quantize
          d = x - cp[:p1] * (x / cp[:p1] + 0.5).floor.to_f
          -0.5 * d * d
        end
      end

      # Ruby mirror of MB::Sound::FastClip.shape: returns +data+ (an SFloat)
      # through the shaper, updating +state+ like the C version.
      def self.shape_ruby(data, mode, p1, p2, antialias, state)
        cp = params(mode, p1, p2)
        x1, ap_x1, ap_y1, primed = state
        primed = primed != 0
        fx1 = antialias && primed ? f(cp, x1) : 0.0
        lo = cp[:lo]
        hi = cp[:hi]

        out = Numo::SFloat.zeros(data.length)
        Numo::SFloat.cast(data).to_a.each_with_index do |x, i|
          unless antialias
            out[i] = f(cp, x)
            next
          end

          unless primed
            x1 = ap_x1 = ap_y1 = x
            fx1 = f(cp, x)
            primed = true
          end

          d = x - x1
          m = 0.5 * (x + x1)
          fx = f(cp, x)
          g = if d.abs < TINY
                f(cp, m) - m
              else
                (g_integral(cp, x) - g_integral(cp, x1)) / d
              end

          w = cp[:trend] ? 1.0 : band_gain(x, x1, fx, fx1, m) { |v| f(cp, v) }

          dry = ALLPASS * x + ap_x1 - ALLPASS * ap_y1
          ap_x1 = x
          ap_y1 = dry
          x1 = x
          fx1 = fx

          out[i] = limit(dry + g + (w - 1.0) * (dry - m), lo, hi)
        end

        state.replace([x1, ap_x1, ap_y1, 1]) if antialias && data.length > 0
        Kernels.inplace_result(data, out)
      end

      Kernels.register :shape, c: FastClip.method(:shape), ruby: Shaper.method(:shape_ruby)
    end
  end
end
