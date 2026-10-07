module MB
  module Sound
    class Curve
      # The straight line y = x.
      def self.linear
        @linear ||= new(:linear, kind: :linear, monotonic: true, natural: true, generic: ->(x, _m) { x * 1.0 }, form: [:poly, [0.0, 1.0]])
      end

      # 3x² - 2x³: zero slope at both ends (the shape of GraphNode#smooth,
      # Notes::Glide, and Envelope's :s at 0 dB).
      def self.smoothstep
        @smoothstep ||= new(:smoothstep, kind: :in_out, monotonic: true, generic: ->(x, _m) { x * x * (3.0 - 2.0 * x) }, form: [:poly, [0.0, 0.0, 3.0, -2.0]])
      end

      # 6x⁵ - 15x⁴ + 10x³: zero slope and curvature at both ends.
      def self.smootherstep
        @smootherstep ||= new(
          :smootherstep, kind: :in_out, monotonic: true,
          generic: ->(x, _m) { x * x * x * (x * (x * 6.0 - 15.0) + 10.0) }, form: [:poly, [0.0, 0.0, 0.0, 10.0, -15.0, 6.0]]
        )
      end

      # Half a cosine: (1 - cos(πx)) / 2, an in-out curve.
      def self.sine
        @sine ||= new(:sine, kind: :in_out, monotonic: true, natural: true,
                             generic: ->(x, m) { (1.0 - m.cos(Math::PI * x)) * 0.5 }, form: [:cos, 0.5, -0.5, Math::PI, 0.0])
      end

      # A quarter cosine starting slowly: 1 - cos(πx/2).
      def self.sine_in
        @sine_in ||= new(:sine_in, kind: :in, monotonic: true, natural: true,
                                   generic: ->(x, m) { 1.0 - m.cos(Math::PI * 0.5 * x) }, form: [:cos, 1.0, -1.0, Math::PI * 0.5, 0.0])
      end

      # A quarter sine arriving gently: sin(πx/2).
      def self.sine_out
        @sine_out ||= new(:sine_out, kind: :out, monotonic: true, natural: true,
                                     generic: ->(x, m) { m.sin(Math::PI * 0.5 * x) }, form: [:cos, 0.0, 1.0, Math::PI * 0.5, -Math::PI * 0.5])
      end

      # x to the power +n+ (> 0): starts slowly for n > 1 (:in), fast for
      # n < 1 (:out).
      def self.power(n)
        raise ArgumentError, "A power curve needs a positive exponent (got #{n.inspect})" unless n.is_a?(Numeric) && n > 0

        e = n.to_f
        form = nil
        if e == e.round && e <= 8
          coeffs = Array.new(e.to_i + 1, 0.0)
          coeffs[e.to_i] = 1.0
          form = [:poly, coeffs]
        end
        name = "power(#{MB::M.sigfigs(e, 6)})"
        kind = e > 1 ? :in : (e < 1 ? :out : :linear)
        return new(name, kind: kind, monotonic: true, generic: ->(x, _m) { x**e }, form: form) if form

        # Fractional powers of negative numbers are odd: -(-x)^e
        new(name, kind: kind, monotonic: true,
                  scalar: ->(x) { x < 0 ? -((-x)**e) : x**e },
                  vector: ->(x) {
                    y = x.abs**e
                    neg = x.lt(0)
                    y[neg] = -y[neg] if neg.any?
                    y
                  })
      end

      # Envelope's signed-dB curve (see MB::Sound::Envelope): (1 - e^(cx)) /
      # (1 - e^c) with c = -+db+ ln(10) / 20.  Positive dB moves fast first
      # (+60 is like an analog decay), 0 is linear, negative moves slowly
      # first.  Curve.db(d).reverse equals Curve.db(-d).
      def self.db(db)
        db = db.to_f
        c = db * DB_SCALE
        return linear if c.abs < LINEAR_LIMIT

        inv = 1.0 / (1.0 - Math.exp(c))
        new("db(#{MB::M.sigfigs(db, 6)})", kind: db > 0 ? :out : :in, monotonic: true, natural: true,
                                           generic: ->(x, m) { (1.0 - m.exp(c * x)) * inv }, form: [:exp, c])
      end

      # Envelope's :s shape at curve +db+ (see MB::Sound::Envelope): a
      # smoothstep of Curve.db(+db+), so zero slope at both ends, skewed
      # toward the start for positive dB.  Curve.s(0) is the smoothstep.
      def self.s(db = 0)
        return smoothstep if (db.to_f * DB_SCALE).abs < LINEAR_LIMIT

        p = Curve.db(db)
        new("s(#{MB::M.sigfigs(db.to_f, 6)})", kind: :in_out, monotonic: true,
                                                scalar: ->(x) { v = p.call(x); v * v * (3.0 - 2.0 * v) },
                                                vector: ->(x) { v = p.map(x); v * v * (3.0 - 2.0 * v) })
      end

      # The bump scale k for which x²(3 - 2x) + k x³(1 - x)² peaks at 1 +
      # +overshoot+ (found by bisection; 0 for no overshoot).  The bump
      # only passes the target once k > 3, so tiny overshoots still need k
      # near 3.  (Notes::Glide.overshoot_k.)
      def self.back_k(overshoot)
        return 0.0 if overshoot <= 0

        (@back_k ||= {})[overshoot] ||= begin
          peak = ->(k) {
            (1..999).map { |j| t = j / 1000.0; t * t * (3 - 2 * t) + k * t**3 * (1 - t)**2 }.max - 1
          }
          lo = 3.0
          hi = 6.0
          hi *= 2 while peak.(hi) < overshoot
          60.times do
            mid = (lo + hi) / 2
            peak.(mid) < overshoot ? lo = mid : hi = mid
          end
          (lo + hi) / 2
        end
      end

      # Passes the target by +overshoot+ (a fraction of the distance, 0 to
      # 1; default 0.1) late in the motion and settles back, with zero slope
      # at both ends: the smoothstep plus a bump k x³(1 - x)² (the curve of
      # Notes::Glide's +overshoot:+; see .back_k).
      def self.back(overshoot: 0.1)
        ov = check_amount(:back, overshoot, 0..1)
        k = back_k(ov)
        new("back(#{MB::M.sigfigs(ov, 6)})", kind: :out, monotonic: ov == 0, options: { overshoot: ov },
                                             generic: ->(x, _m) { x * x * (3.0 - 2.0 * x) + k * x * x * x * (1.0 - x) * (1.0 - x) },
                                             form: [:poly, [0.0, 0.0, 3.0, k - 2.0, -2.0 * k, k]])
      end

      # The reverse of .back: backs up by +overshoot+ first, then goes (a
      # wind-up).
      def self.anticipate(overshoot: 0.1)
        b = back(overshoot: overshoot)
        f = b
        new("anticipate(#{MB::M.sigfigs(b.options[:overshoot], 6)})", kind: :in, options: b.options,
                                                                    scalar: ->(x) { 1.0 - f.call(1.0 - x) },
                                                                    vector: ->(x) { 1.0 - f.map(1.0 - x) })
      end

      # A spring: 1 - e^(-kx) (1 - x)² cos(2π +cycles+ x).  It leaves fast,
      # swings past the target by +overshoot+ (the first swing, as a fraction
      # of the distance; default 0.3), rings around it with decaying swings,
      # and lands exactly on it with zero slope.  More +cycles+ (default 3)
      # ring faster; at least 0.75.
      def self.elastic(overshoot: 0.3, cycles: 3)
        ov = check_amount(:elastic, overshoot, 0..1)
        c = check_amount(:elastic, cycles, 0.75.., :cycles)
        w = 2.0 * Math::PI * c
        k = elastic_k(ov, c)
        new("elastic(#{MB::M.sigfigs(ov, 6)}, #{MB::M.sigfigs(c, 6)})", kind: :out, options: { overshoot: ov, cycles: c },
                                                                         generic: ->(x, m) { 1.0 - m.exp(-k * x) * (1.0 - x) * (1.0 - x) * m.cos(w * x) })
      end

      # The decay k of .elastic for a first swing of +overshoot+ with
      # +cycles+ (bisection on a 2001-point grid).
      def self.elastic_k(overshoot, cycles)
        (@elastic_k ||= {})[[overshoot, cycles]] ||= begin
          x = Numo::DFloat.linspace(0, 1, 2001)
          w = 2.0 * Math::PI * cycles
          base = (1.0 - x) * (1.0 - x) * Numo::NMath.cos(w * x)
          peak = ->(k) { (-(Numo::NMath.exp(-k * x) * base)).max }
          max = peak.(0.0)
          if overshoot >= max
            raise ArgumentError, "Elastic overshoot must be below #{MB::M.sigfigs(max, 4)} with #{cycles} cycles (got #{overshoot})"
          end

          if overshoot <= 0
            1e3
          else
            lo = 0.0
            hi = 1.0
            hi *= 2 while peak.(hi) > overshoot
            60.times do
              mid = (lo + hi) / 2
              peak.(mid) > overshoot ? lo = mid : hi = mid
            end
            (lo + hi) / 2
          end
        end
      end

      # The peak of x³(1 - x)², the wiggle window of .squiggle.
      SQUIGGLE_PEAK = 0.6**3 * 0.4**2

      # Where .squiggle's glide arrives (as a fraction of the time).
      SQUIGGLE_ARRIVE = 0.6

      # A wobbly glide: a smoothstep that arrives at 60% of the time
      # (SQUIGGLE_ARRIVE), with a wiggle riding on it: +overshoot+ (default
      # 0.15, a fraction of the distance) times sin(2π +cycles+ x) in a
      # window x³(1 - x)² that peaks at 60%, so the wiggle is largest as it
      # arrives, swings around the target (passing it by up to about
      # +overshoot+), and dies away, settling onto it with zero slope.
      # +cycles+ (default 4) counts the sine's cycles over the whole time.
      def self.squiggle(overshoot: 0.15, cycles: 4)
        a = check_amount(:squiggle, overshoot, 0..1) / SQUIGGLE_PEAK
        c = check_amount(:squiggle, cycles, 0.., :cycles)
        w = 2.0 * Math::PI * c
        inv = 1.0 / SQUIGGLE_ARRIVE
        new("squiggle(#{MB::M.sigfigs(a * SQUIGGLE_PEAK, 6)}, #{MB::M.sigfigs(c, 6)})", kind: :out,
            options: { overshoot: a * SQUIGGLE_PEAK, cycles: c },
            scalar: ->(x) {
              u = x * inv
              u = u < 0 ? 0.0 : (u > 1 ? 1.0 : u)
              u * u * (3.0 - 2.0 * u) + a * x * x * x * (1.0 - x) * (1.0 - x) * Math.sin(w * x)
            },
            vector: ->(x) {
              u = (x * inv).clip(0.0, 1.0)
              u * u * (3.0 - 2.0 * u) + a * x * x * x * (1.0 - x) * (1.0 - x) * Numo::NMath.sin(w * x)
            })
      end

      # A ball dropped onto the target: a fall (x/T)², then +cycles+ bounces
      # (default 3) below the target, each lower by the restitution r =
      # sqrt(+overshoot+): the first bounce rises +overshoot+ (default 0.25)
      # of the distance back.  The defaults are Robert Penner's
      # easeOutBounce exactly.  Lands on the target at 1.
      def self.bounce(overshoot: 0.25, cycles: 3)
        ov = check_amount(:bounce, overshoot, 0..1)
        raise ArgumentError, 'Bounce overshoot must be below 1' if ov >= 1
        n = Integer(check_amount(:bounce, cycles, 0.., :cycles).round)
        r = Math.sqrt(ov)

        t0 = 1.0 / (1.0 + 2.0 * (1..n).sum { |i| r**i })
        inv_t0 = 1.0 / t0
        # Each bounce: [start, middle, 1 / half-width, height]
        segments = []
        start = t0
        (1..n).each do |i|
          half = t0 * r**i
          segments << [start, start + half, 1.0 / half, r**(2 * i)]
          start += 2 * half
        end

        scalar = ->(x) {
          return (x * inv_t0) * (x * inv_t0) if x < t0 || segments.empty?
          seg = segments.reverse_each.find { |s| x >= s[0] }
          q = (x - seg[1]) * seg[2]
          1.0 - (1.0 - q * q) * seg[3]
        }
        vector = ->(x) {
          q0 = x * inv_t0
          y = q0 * q0
          segments.each do |s|
            mask = x.ge(s[0])
            next unless mask.any?
            q = (x[mask] - s[1]) * s[2]
            y[mask] = 1.0 - (1.0 - q * q) * s[3]
          end
          y
        }
        new("bounce(#{MB::M.sigfigs(ov, 6)}, #{n})", kind: :out, options: { overshoot: ov, cycles: n }, scalar: scalar, vector: vector)
      end

      # A staircase of +count+ equal jumps (default 4) along +curve+ (linear
      # by default): the first jump right after the start, the last at
      # (count - 1) / count, so the final step holds the target (e.g. four
      # beats of stepped automation over a bar).  Holds its ends outside
      # 0..1.
      def self.steps(count = 4, curve = nil)
        n = Integer(check_amount(:steps, count, 1.., :cycles).round)
        base = curve && from(curve)
        nf = n.to_f
        quant = ->(x) { q = (x * nf - 1e-9).ceil / nf; q <= 0 ? 0.0 : (q > 1 ? 1.0 : q) }
        cells = n * (4096.0 / n).ceil
        new("steps(#{n}#{", #{base.name}" if base})", kind: base ? base.kind : :linear, monotonic: base.nil? || base.monotonic?,
                                                       options: { cycles: n }, slopes: [0.0, 0.0], cells: cells, key: [:steps, n, base&.key],
                                                       scalar: ->(x) { q = quant.(x); base ? base.call(q) : q },
                                                       vector: ->(x) { q = ((x * nf - 1e-9).ceil / nf).clip(0.0, 1.0) + 0.0; base ? base.map(q) : q })
      end

      # A CSS-style cubic bezier from (0, 0) to (1, 1) with control points
      # (+x1+, +y1+) and (+x2+, +y2+); +x1+ and +x2+ must be within 0..1,
      # the y values may overshoot.  E.g. CSS's "ease" is
      # Curve.bezier(0.25, 0.1, 0.25, 1) (also Curve[:ease]).
      def self.bezier(x1, y1, x2, y2)
        x1, y1, x2, y2 = [x1, y1, x2, y2].map(&:to_f)
        raise ArgumentError, "Bezier x values must be within 0..1 (got #{x1}, #{x2})" unless (0..1).cover?(x1) && (0..1).cover?(x2)

        cx = 3.0 * x1
        bx = 3.0 * (x2 - x1) - cx
        ax = 1.0 - cx - bx
        cy = 3.0 * y1
        by = 3.0 * (y2 - y1) - cy
        ay = 1.0 - cy - by
        xt = ->(t) { ((ax * t + bx) * t + cx) * t }

        # Inverse table: t where x(t) = j / 256 (x(t) never goes down)
        table = Numo::DFloat.cast((0..256).map { |j|
          target = j / 256.0
          lo = 0.0
          hi = 1.0
          60.times { mid = (lo + hi) / 2; xt.(mid) < target ? lo = mid : hi = mid }
          (lo + hi) / 2
        })

        vector = ->(x) {
          x = x.clip(0.0, 1.0)
          pos = x * 256.0
          j = pos.floor.clip(0, 255)
          ji = Numo::Int32.cast(j)
          t0 = table[ji]
          t = t0 + (table[ji + 1] - t0) * (pos - j)
          3.times do
            err = ((t * ax + bx) * t + cx) * t - x
            slope = (t * (3.0 * ax) + 2.0 * bx) * t + cx
            step = err / slope
            step[slope.abs.lt(1e-9)] = 0.0
            t = (t - step).clip(0.0, 1.0)
          end
          ((t * ay + by) * t + cy) * t
        }

        mid = vector.(Numo::DFloat[0.5])[0]
        kind = (mid - 0.5).abs < 1e-6 ? :in_out : (mid < 0.5 ? :in : :out)
        values = [x1, y1, x2, y2].map { |v| MB::M.sigfigs(v, 6) }.join(', ')
        new("bezier(#{values})", kind: kind, monotonic: (0..1).cover?(y1) && (0..1).cover?(y2), vector: vector)
      end

      # Checks a curve option: a number in +range+.
      def self.check_amount(curve, value, range, name = :overshoot)
        unless value.is_a?(Numeric) && range.cover?(value)
          raise ArgumentError, "The #{curve} curve's #{name} must be a number in #{range} (got #{value.inspect})"
        end
        value.to_f
      end

      # Builders for .named: each takes the options it understands
      # (+overshoot:+, +cycles:+) and rejects others.
      def self.plain(name, &block)
        ->(**options) {
          raise ArgumentError, "The #{name} curve takes no options (got #{options})" unless options.empty?
          block.call
        }
      end

      NAMES = {
        linear: plain(:linear) { linear },
        smoothstep: plain(:smoothstep) { smoothstep },
        smooth: plain(:smooth) { smoothstep },
        s: plain(:s) { smoothstep },
        smootherstep: plain(:smootherstep) { smootherstep },
        sine: plain(:sine) { sine },
        sine_in: plain(:sine_in) { sine_in },
        sine_out: plain(:sine_out) { sine_out },
        quad: plain(:quad) { power(2) },
        cubic: plain(:cubic) { power(3) },
        quart: plain(:quart) { power(4) },
        quint: plain(:quint) { power(5) },
        exp: plain(:exp) { db(60) },
        exp_in: plain(:exp_in) { db(-60) },
        exp_out: plain(:exp_out) { db(60) },
        back: ->(**o) { back(**o.slice(:overshoot)).tap { reject_options(:back, o, [:overshoot]) } },
        anticipate: ->(**o) { reject_options(:anticipate, o, [:overshoot]); anticipate(**o) },
        elastic: ->(**o) { reject_options(:elastic, o, [:overshoot, :cycles]); elastic(**o) },
        squiggle: ->(**o) { reject_options(:squiggle, o, [:overshoot, :cycles]); squiggle(**o) },
        bounce: ->(**o) { reject_options(:bounce, o, [:overshoot, :cycles]); bounce(**o) },
        steps: ->(**o) { reject_options(:steps, o, [:cycles]); steps(o.fetch(:cycles, 4)) },
        ease: plain(:ease) { bezier(0.25, 0.1, 0.25, 1.0) },
        ease_in: plain(:ease_in) { bezier(0.42, 0.0, 1.0, 1.0) },
        ease_out: plain(:ease_out) { bezier(0.0, 0.0, 0.58, 1.0) },
        ease_in_out: plain(:ease_in_out) { bezier(0.42, 0.0, 0.58, 1.0) },
      }.freeze

      # Raises if +options+ has keys other than +allowed+.
      def self.reject_options(name, options, allowed)
        extra = options.keys - allowed
        raise ArgumentError, "The #{name} curve takes #{allowed.join(' and ')}, not #{extra.join(', ')}" unless extra.empty?
      end
    end
  end
end
