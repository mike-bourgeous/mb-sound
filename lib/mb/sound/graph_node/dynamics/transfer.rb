module MB
  module Sound
    module GraphNode
      class Dynamics
        # A static transfer curve for a Dynamics node's gain computer: input
        # level in dB to output level in dB (the gain is the difference).
        # Stored as segments [x0, y0, b, c, d] meaning
        # y = y0 + b dx + c dx^2 + d dx^3 with dx = x - x0, each used from
        # its x0 up to the next segment's; the first and last are linear, so
        # the curve continues its end slopes forever (the C kernel evaluates
        # the same segments; see FastDynamics.compand).
        #
        # Build one with:
        # - Transfer.corners: straight lines meeting at corners, each corner
        #   rounded by a quadratic soft knee (compressors, upward
        #   compression, expanders, gates, ducks; Giannoulis et al.'s knee),
        # - Transfer.points: points joined by straight lines, monotone cubics
        #   (+:cubic+, Fritsch-Carlson slopes, which never overshoot), or a
        #   Curve shape per segment,
        # - Transfer.from_block: any Ruby block sampled every +step+ dB and
        #   joined by monotone cubics.
        #
        # Examples:
        #     Transfer.corners(-20, [[-20, 1, 0.25]], knee: 6)       # 4:1 above -20 dB, 6 dB knee
        #     Transfer.points({ -60 => -80, -40 => -40, 0 => -12 }) # an expander below -40, 3.3:1 above
        #     Transfer.points([[-60, -80], [-40, -40, :smooth], [0, -12]])
        #     Transfer.from_block(-100..12) { |db| db < -50 ? db * 1.5 + 25 : db }
        class Transfer
          # The segments: an Array of frozen [x0, y0, b, c, d] Arrays.
          attr_reader :segments

          # A description for #to_s.
          attr_reader :description

          # Creates a curve from +segments+ (see the class comment), sorted by
          # x0; the first and last must be linear (c and d zero).
          def initialize(segments, description: 'curve')
            raise ArgumentError, 'A transfer curve needs at least one segment' if segments.empty?
            segments = segments.map { |s| s.map(&:to_f).freeze }
            unless segments.each_cons(2).all? { |a, b| a[0] <= b[0] }
              raise ArgumentError, 'Transfer curve segments must be sorted by input level'
            end
            [segments.first, segments.last].each do |s|
              raise ArgumentError, 'The first and last transfer curve segments must be linear' unless s[3] == 0 && s[4] == 0
            end
            unless segments.all? { |s| s.all?(&:finite?) }
              raise ArgumentError, 'Transfer curve segments must be finite'
            end

            @segments = segments.freeze
            @description = description
            @table = Numo::DFloat.cast(segments.flatten).freeze
          end

          # The segments as a flat Numo::DFloat (frozen), for the C kernel.
          def table
            @table
          end

          # The output level (dB) for input level +x+ (dB), as the C kernel
          # computes it.
          def call(x)
            self.class.evaluate(@segments, x.to_f)
          end
          alias [] call

          # The gain (dB) at input level +x+ (dB): call(x) - x.
          def gain(x)
            call(x) - x.to_f
          end

          def to_s
            @description
          end

          # Evaluates +segments+ at +x+ exactly as the C kernel does (binary
          # search for the last segment whose x0 <= x, Horner's rule).
          def self.evaluate(segments, x)
            lo = 0
            hi = segments.length - 1
            while lo < hi
              mid = (lo + hi + 1) / 2
              if segments[mid][0] <= x
                lo = mid
              else
                hi = mid - 1
              end
            end
            s = segments[lo]
            dx = x - s[0]
            s[1] + dx * (s[2] + dx * (s[3] + dx * s[4]))
          end

          # Straight lines meeting at corners, rounded by quadratic soft knees
          # +knee+ dB wide (centered on each corner; narrowed to fit between
          # corners closer than that).  +corners+ is an Array of
          # [level, slope_below, slope_above] sorted by level; the first
          # corner's output level is +start+ (dB), and the lines between
          # corners connect them.  A slope of 1 leaves levels unchanged, 1/R
          # compresses by R:1, R > 1 expands.
          def self.corners(start, corners, knee: 0, description: 'curve')
            raise ArgumentError, 'Transfer.corners needs at least one corner' if corners.empty?
            knee = knee.to_f
            raise ArgumentError, "Knee width must not be negative (got #{knee})" if knee < 0

            levels = corners.map { |c| c[0].to_f }
            unless levels.each_cons(2).all? { |a, b| a < b }
              raise ArgumentError, 'Transfer curve corners must be in increasing order of level'
            end
            corners.each_cons(2) do |a, b|
              raise ArgumentError, 'Slopes must agree between corners' unless a[2].to_f == b[1].to_f
            end
            gap = levels.each_cons(2).map { |a, b| b - a }.min
            w = gap ? [knee, gap].min : knee

            segments = []
            y = start.to_f
            prev_level = nil
            corners.each_with_index do |(t, s1, s2), idx|
              t = t.to_f
              s1 = s1.to_f
              s2 = s2.to_f
              y += s1 * (t - prev_level) if prev_level
              segments << [t - w / 2, y - s1 * w / 2, s1, 0, 0] if idx == 0
              if w > 0
                segments << [t - w / 2, y - s1 * w / 2, s1, (s2 - s1) / (2 * w), 0]
                segments << [t + w / 2, y + s2 * w / 2, s2, 0, 0]
              else
                segments << [t, y, s2, 0, 0]
              end
              prev_level = t
            end

            new(segments, description: description)
          end

          # Points joined by straight lines (default) or monotone cubics.
          # +points+ is a Hash of input dB => output dB, or an Array of
          # [input, output] or [input, output, shape] where shape sets the
          # segment from that point to the next: :linear, :cubic (a monotone
          # cubic, Fritsch-Carlson slopes from every point), or anything
          # MB::Sound::Curve.from takes (a Curve name like :smooth, a Curve,
          # a Proc on 0..1), sampled at 32 points and joined by monotone
          # cubics.  +interpolation+ (:linear or :cubic) is the default shape.
          # Outside the points the curve continues its end slopes.
          #
          # Output levels must not decrease (louder input never comes out
          # quieter), and Curve shapes must be monotonic.
          def self.points(points, interpolation: :linear, description: nil)
            raise ArgumentError, "Interpolation must be :linear or :cubic (got #{interpolation.inspect})" unless [:linear, :cubic].include?(interpolation)

            rows = points.is_a?(Hash) ? points.to_a : points.to_a
            rows = rows.map { |r|
              raise ArgumentError, "Transfer points are [input dB, output dB] or [input, output, shape] (got #{r.inspect})" unless r.is_a?(Array) && (2..3).cover?(r.length)
              unless r[0].is_a?(Numeric) && r[1].is_a?(Numeric) && r[0].to_f.finite? && r[1].to_f.finite?
                raise ArgumentError, "Transfer points must be finite dB numbers (got #{r.inspect})"
              end
              [r[0].to_f, r[1].to_f, r[2] || interpolation]
            }
            raise ArgumentError, 'A transfer curve needs at least two points' if rows.length < 2
            rows.sort_by!(&:first)
            rows.each_cons(2) do |a, b|
              raise ArgumentError, "Transfer point input levels must differ (#{a[0]} given twice)" if a[0] == b[0]
              raise ArgumentError, "Transfer curve output levels must not decrease (#{a[0]} => #{a[1]}, #{b[0]} => #{b[1]})" if b[1] < a[1]
            end

            xs = rows.map(&:first)
            ys = rows.map { |r| r[1] }
            slopes = pchip_slopes(xs, ys)

            segments = []
            rows.each_cons(2).with_index do |(a, b), idx|
              x0, y0, shape = a
              x1, y1 = b
              h = x1 - x0
              case shape
              when :linear
                segments << [x0, y0, (y1 - y0) / h, 0, 0]
              when :cubic
                segments << hermite(x0, y0, x1, y1, slopes[idx], slopes[idx + 1])
              else
                curve = MB::Sound::Curve.from(shape)
                raise ArgumentError, "Transfer curve segment shapes must be monotonic (#{curve} is not)" unless curve.monotonic?
                sx = Array.new(33) { |k| x0 + h * k / 32.0 }
                sy = Array.new(33) { |k| y0 + (y1 - y0) * curve.call(k / 32.0) }
                sy[0] = y0
                sy[-1] = y1
                sub = pchip_slopes(sx, sy)
                32.times do |k|
                  segments << hermite(sx[k], sy[k], sx[k + 1], sy[k + 1], sub[k], sub[k + 1])
                end
              end
            end

            first_slope = segments.first[2]
            last = segments.last
            hl = xs[-1] - last[0]
            last_slope = last[2] + hl * (2 * last[3] + 3 * last[4] * hl)
            segments.unshift([xs[0], ys[0], first_slope, 0, 0])
            segments << [xs[-1], ys[-1], last_slope, 0, 0]

            description ||= "compand #{rows.map { |r| "#{fmt(r[0])}=>#{fmt(r[1])}" }.join(', ')}#{interpolation == :cubic ? ' (cubic)' : ''}"
            new(segments, description: description)
          end

          # A curve from a block mapping input dB to output dB, sampled every
          # +step+ dB over +range+ (a Range of dB) and joined by monotone
          # cubics; outside +range+ it continues the end slopes.
          def self.from_block(range = -100..12, step: 1, &block)
            raise ArgumentError, 'Transfer.from_block needs a block' unless block
            lo = range.begin.to_f
            hi = range.end.to_f
            raise ArgumentError, "The range must go up (got #{range})" unless hi > lo
            count = ((hi - lo) / step).ceil
            pts = Array.new(count + 1) { |k|
              x = [lo + k * step, hi].min
              [x, Float(block.call(x))]
            }
            points(pts, interpolation: :cubic, description: "compand { block } over #{range}")
          end

          # Fritsch-Carlson monotone slopes (weighted harmonic means of the
          # neighboring secants, zero at local extremes; the end slopes are
          # the end secants).
          def self.pchip_slopes(xs, ys)
            n = xs.length
            h = Array.new(n - 1) { |k| xs[k + 1] - xs[k] }
            delta = Array.new(n - 1) { |k| (ys[k + 1] - ys[k]) / h[k] }
            Array.new(n) { |k|
              if k == 0
                delta[0]
              elsif k == n - 1
                delta[-1]
              elsif delta[k - 1] * delta[k] <= 0
                0.0
              else
                w1 = 2 * h[k] + h[k - 1]
                w2 = h[k] + 2 * h[k - 1]
                (w1 + w2) / (w1 / delta[k - 1] + w2 / delta[k])
              end
            }
          end

          # The cubic Hermite segment from (x0, y0) to (x1, y1) with end
          # slopes m0 and m1, as [x0, y0, b, c, d].
          def self.hermite(x0, y0, x1, y1, m0, m1)
            h = x1 - x0
            delta = (y1 - y0) / h
            [x0, y0, m0, (3 * delta - 2 * m0 - m1) / h, (m0 + m1 - 2 * delta) / (h * h)]
          end

          def self.fmt(v)
            v == v.round ? v.round.to_s : MB::M.sigfigs(v, 4).to_s
          end
          private_class_method :fmt
        end
      end
    end
  end
end
