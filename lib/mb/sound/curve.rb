module MB
  module Sound
    # A tweening (easing) curve: maps progress from 0 to 1 onto 0 to 1,
    # possibly passing 1 (overshoot) or 0 (anticipation) on the way.  One
    # library of shapes shared by everything that moves from one value to
    # another over time or maps a value through a shape:
    #
    # - glides between notes (`v.hz.glide(200.ms, shape: :squiggle)`, also
    #   per unison copy, see Notes::NotePitch#glide and Pitch#swarm),
    # - control sequences tweened from value to value (MB::Sound.tween,
    #   Sequence::Clip#tween),
    # - step-change smoothing (GraphNode#smooth with +curve:+),
    # - shaping a signal through a curve (GraphNode#ease, a waveshaper or
    #   LFO reshaper; see GraphNode::CurveShaper),
    # - keyframe blends (TimelineInterpolator).
    #
    # Why "Curve": it is the word the library already uses (Envelope's
    # +curve:+ in signed dB is Curve.db here, and its :s shape is Curve.s),
    # and curves are useful for more than time (waveshaping, velocity), so
    # "easing" or "tween" would be too narrow; tweening is what the nodes
    # that use them do (MB::Sound.tween).
    #
    # Curves are immutable values.  Evaluate one with #call (alias #[]) on a
    # number, or #map on an Array or Numo::NArray (vectorized, returning a
    # Numo::DFloat; #call and #map give the same values).  Build them with
    # Curve.from (a name, a curve, a Proc, a dB number, or four bezier
    # control values) or Curve[name, options]:
    #
    #     Curve[:smoothstep].(0.25)                    # => 0.15625
    #     Curve[:elastic, overshoot: 0.4, cycles: 4]   # a springier spring
    #     Curve[:sine_in]                              # suffixes _in, _out, _in_out, _out_in
    #     Curve.db(30)                                 # Envelope's +30 dB curve
    #     Curve.bezier(0.25, 0.1, 0.25, 1)             # CSS's "ease"
    #     Curve.new { |x| x ** 0.5 }                   # any Proc
    #     Curve[:bounce].reverse                       # bounces before leaving instead
    #     Curve[:back] >> Curve.steps(8)               # one curve after another
    #
    # Named curves (NAMES; #kind says which way a curve leans: :in starts
    # slowly, :out arrives gently, :in_out both, :linear neither):
    # - :linear
    # - :smoothstep (aliases :smooth, :s), :smootherstep - zero slope at
    #   both ends (smootherstep also zero curvature)
    # - :sine (in-out), :sine_in, :sine_out
    # - :quad, :cubic, :quart, :quint (powers 2 to 5; in), Curve.power(n)
    # - :exp (Curve.db(60): fast first, like an analog decay), Curve.db(d)
    #   for any signed dB (Envelope's curvature: positive fast first, 0
    #   linear, negative slow first); Curve.s(d) is Envelope's :s shape
    # - :back - passes the target by +overshoot+ (default 0.1) and settles
    #   back, with zero slope at both ends (Notes::Glide's overshoot curve);
    #   :anticipate is its reverse (backs up first, then goes)
    # - :elastic - a spring: shoots off, rings around the target with
    #   decaying swings (+overshoot+ is the first swing, default 0.3;
    #   +cycles+ the swings, default 3) and lands exactly on it
    # - :squiggle - a smooth glide with a decaying wiggle riding on it
    #   (+overshoot+ is the wiggle's size, default 0.15; +cycles+ default
    #   4), loudest as it arrives, settling onto the target
    # - :bounce - falls onto the target and bounces under it (+overshoot+
    #   is the first bounce's height, default 0.25; +cycles+ the bounces,
    #   default 3: Robert Penner's easeOutBounce)
    # - :steps - a staircase of +cycles+ (default 4) equal jumps, the first
    #   right after the start, holding the target for the last step
    #   (Curve.steps(n, curve) steps along another curve)
    # - :ease, :ease_in, :ease_out, :ease_in_out - CSS's cubic-bezier
    #   presets (Curve.bezier for any)
    #
    # Composition: #reverse (the same motion played backwards: an :in curve
    # becomes :out), #in / #out / #in_out / #out_in (Penner-style variants
    # of a curve), #then (alias #>>) to feed one curve into another,
    # #blend, #steps.
    #
    # Outside 0..1, #map_edges extends a curve for shapers (see
    # GraphNode::CurveShaper): clamped, wrapped, mirrored, extended (the
    # formula where it is defined, else a line with the end slope), or raw.
    class Curve
      # Which way a curve leans (see the class description).
      KINDS = [:in, :out, :in_out, :linear].freeze

      # Multiplies a curve in dB to give the curvature c of Curve.db
      # (Envelope::CURVE_SCALE, computed the same way so both are equal).
      DB_SCALE = -Math.log(10) / 20.0

      # Curvature below which Curve.db is a line (Envelope::LINEAR_LIMIT).
      LINEAR_LIMIT = 1e-9

      # Edge modes for #map_edges.
      EDGES = [:clamp, :extend, :wrap, :mirror, :none].freeze

      # Default options of the curves that take +overshoot:+ and +cycles:+.
      DEFAULTS = {
        back: { overshoot: 0.1 },
        anticipate: { overshoot: 0.1 },
        elastic: { overshoot: 0.3, cycles: 3 },
        squiggle: { overshoot: 0.15, cycles: 4 },
        bounce: { overshoot: 0.25, cycles: 3 },
        steps: { cycles: 4 },
      }.freeze

      # The name (with options) shown by #to_s.
      attr_reader :name

      # :in, :out, :in_out, or :linear (see the class description).
      attr_reader :kind

      # Options given to a named curve (e.g. { overshoot: 0.3, cycles: 3 }).
      attr_reader :options

      # Creates a curve from a scalar block (x -> y), or from lambdas:
      # +generic+ (x, math) -> y evaluated with Math for Floats and
      # Numo::NMath for arrays (one formula for both), or +scalar+ and
      # +vector+ (a Numo::DFloat in, a new array out).  Without a vector
      # form, arrays are mapped element by element; without a scalar form,
      # numbers go through a one-element array.
      #
      # +natural+ means the formula is meaningful outside 0..1 (for
      # #map_edges :extend); +monotonic+ that it never goes down on 0..1;
      # +slopes+ gives the end slopes [at 0, at 1] for :extend (measured
      # otherwise).
      #
      #     Curve.new { |x| x * x }
      #     Curve.new(:sqrt, kind: :out, monotonic: true) { |x| Math.sqrt(x) }
      def initialize(name = :custom, kind: :in_out, monotonic: false, natural: false, slopes: nil,
                     generic: nil, scalar: nil, vector: nil, options: {}, key: nil, form: nil, cells: nil, &block)
        raise ArgumentError, "Curve kind must be one of #{KINDS.inspect} (got #{kind.inspect})" unless KINDS.include?(kind)
        scalar ||= block
        raise ArgumentError, 'A curve needs a block or a scalar, vector, or generic formula' unless generic || scalar || vector

        @name = name.to_s
        @kind = kind
        @monotonic = !!monotonic
        @natural = !!natural
        @slopes = slopes&.map(&:to_f)&.freeze
        @generic = generic
        @scalar = scalar
        @vector = vector
        @options = options.freeze
        @key = key || (block ? object_id : @name)
        @form = form&.freeze
        @cells = cells
      end

      # The closed form the antialiased shaper (GraphNode::CurveShaper)
      # integrates exactly, or nil to use a table: [:poly, coefficients
      # from x^0 up], [:cos, a, b, w, phase] for a + b cos(w x + phase), or
      # [:exp, c] for Curve.db's (1 - e^(cx)) / (1 - e^c).  These formulas
      # hold outside 0..1 too.
      attr_reader :form

      # Table cells over 0..1 for the antialiased shaper's antiderivative
      # table (a multiple of the step count for #steps, so jumps fall on
      # cell edges), or nil for the default (CurveShaper::TABLE_CELLS).
      attr_reader :cells

      # Returns the curve's value at +x+ (a Float).
      def call(x)
        x = x.to_f
        if @scalar
          @scalar.call(x).to_f
        elsif @generic
          @generic.call(x, Math).to_f
        else
          @vector.call(Numo::DFloat[x])[0].to_f
        end
      end
      alias [] call

      # Returns a Proc that calls #call.
      def to_proc
        method(:call).to_proc
      end

      # Returns the curve's values at every element of +x+ (an Array or
      # Numo::NArray) as a new Numo::DFloat (vectorized; the same values as
      # #call).  +x+ is never modified.
      def map(x)
        x = Numo::DFloat.cast(x)
        return Numo::DFloat[] if x.empty?

        y = if @vector
              @vector.call(x)
            elsif @generic
              @generic.call(x, Numo::NMath)
            else
              x.map { |v| @scalar.call(v).to_f }
            end
        y.is_a?(Numo::NArray) ? Numo::DFloat.cast(y) : Numo::DFloat.new(x.length).fill(y)
      end

      # Like #map, for inputs outside 0..1 too, handled by +edges+:
      # - :clamp (default) - clamps to 0..1 (holds the end values)
      # - :extend - the formula itself where it is defined outside 0..1
      #   (#natural?: linear, sine, dB), else a line with the curve's slope
      #   at that end
      # - :wrap - repeats the curve every 1 (sawtooth-like)
      # - :mirror - ping-pongs (0..1 forward, 1..2 backward, ...)
      # - :none (alias :raw) - the formula as is (may give anything)
      def map_edges(x, edges = :clamp)
        x = Numo::DFloat.cast(x)
        case edges
        when :clamp then map(x.clip(0.0, 1.0))
        when :wrap then map(x - x.floor)
        when :mirror
          t = x - (x * 0.5).floor * 2.0
          map(1.0 - (t - 1.0).abs)
        when :none, :raw then map(x)
        when :extend
          return map(x) if @natural
          y = map(x.clip(0.0, 1.0))
          s0, s1 = slopes
          lo = x.lt(0.0)
          hi = x.gt(1.0)
          y[lo] = y[lo] + s0 * x[lo] if lo.any?
          y[hi] = y[hi] + s1 * (x[hi] - 1.0) if hi.any?
          y
        else
          raise ArgumentError, "Curve edges must be one of #{EDGES.inspect} or :raw (got #{edges.inspect})"
        end
      end

      # The antiderivative table of this curve over 0..1 for the antialiased
      # shaper (GraphNode::CurveShaper): [integral from 0, left limits,
      # right limits] at +cells+ + 1 nodes (frozen Numo::DFloats).  The
      # limits differ only at jumps (e.g. #steps, whose cells line up with
      # the jumps); each cell is integrated with Simpson's rule.  Made once
      # per cell count.
      def integral_table(cells = nil)
        cells = Integer(cells || @cells || 4096)
        (@integral_tables ||= {})[cells] ||= begin
          h = 1.0 / cells
          x = Numo::DFloat.new(cells + 1).seq * h
          x[-1] = 1.0
          f = map(x)
          delta = 1e-7
          fl = map((x - delta).clip(0.0, 1.0))
          fr = map((x + delta).clip(0.0, 1.0))
          jump = (fr - fl).abs.gt(1e-5)
          fl[~jump] = f[~jump]
          fr[~jump] = f[~jump]
          mid = map(x[0...cells] + 0.5 * h)
          cell = (fr[0...cells] + mid * 4.0 + fl[1..]) * (h / 6.0)
          integral = Numo::DFloat.zeros(cells + 1)
          integral[1..] = cell.cumsum
          [integral, fl, fr].map(&:freeze).freeze
        end
      end

      # Cells of the value table for #lookup (glides): fine enough that the
      # cubic Hermite between nodes matches #map within about 1e-9 for the
      # library's smooth curves.
      LOOKUP_CELLS = 2048

      # Positions within this fraction of a cell after a table node take
      # the node's value in #lookup (the C CURVE_NODE_SNAP), as Curve.steps
      # snaps rounding errors.
      NODE_SNAP = 1e-6

      # The value table of this curve for #lookup: [left values, right
      # values, left slopes, right slopes] at +cells+ + 1 nodes over 0..1
      # (frozen Numo::DFloats).  Left and right differ only at jumps (e.g.
      # #steps, whose jumps land on nodes) and the slopes also at kinks;
      # slopes are central differences, one-sided at the ends and at jumps.
      def value_table(cells = nil)
        cells = Integer(cells || @cells || LOOKUP_CELLS)
        (@value_tables ||= {})[cells] ||= begin
          h = 1e-6
          step = 1.0 / cells
          x = Numo::DFloat.new(cells + 1).seq * step
          x[-1] = 1.0
          f = map(x)
          fl = map((x - 1e-7).clip(0.0, 1.0))
          fr = map((x + 1e-7).clip(0.0, 1.0))
          jump = (fr - fl).abs.gt(1e-5)
          fl[~jump] = f[~jump]
          fr[~jump] = f[~jump]

          right = map((x + h).clip(0.0, 1.0))
          left = map((x - h).clip(0.0, 1.0))
          right2 = map((x + 2 * h).clip(0.0, 1.0))
          left2 = map((x - 2 * h).clip(0.0, 1.0))
          central = (right - left) / (2 * h)
          dr = central.dup
          dl = central.dup
          # One-sided inside each cell at jumps and at the ends
          dr[jump] = ((right2 - right) / h)[jump]
          dl[jump] = ((left - left2) / h)[jump]
          dr[0] = jump[0] == 1 ? (right2[0] - right[0]) / h : (right[0] - f[0]) / h
          dl[0] = dr[0]
          dl[-1] = jump[-1] == 1 ? (left[-1] - left2[-1]) / h : (f[-1] - left[-1]) / h
          dr[-1] = dl[-1]
          [fl, fr, dl, dr].map(&:freeze).freeze
        end
      end

      # Like #map for positions within 0..1 (clamped), from the value table
      # (#value_table) in C: about the cost of a plain smoothstep for any
      # curve (4 us per 512 positions, against 10 to 170 us for #map),
      # matching #map within about 1e-7 for smooth curves, exactly on the
      # table's nodes and for staircases, within 1e-4 at the bounce's
      # contacts (kinks inside cells), and only roughly in the first or
      # last cell of curves with a vertical slope there (sqrt-like
      # beziers and Procs; 1/2048 of the way).  Modifies +t+ in place if it is
      # a contiguous Numo::DFloat; returns the values.  Used by glides.
      def lookup(t)
        t = Numo::DFloat.cast(t) unless t.is_a?(Numo::DFloat) && t.contiguous?
        MB::Sound::FastClip.curve_lookup(t, *value_table)
      end

      # Ruby mirror of #lookup's C kernel (MB::Sound::FastClip.curve_lookup)
      # for one position +x+ with value +table+ (see #value_table).
      def self.lookup_ruby(table, x)
        fl, fr, dl, dr = table
        cells = fl.length - 1
        pos = x * cells.to_f
        pos = 0.0 unless pos > 0
        pos = cells.to_f if pos > cells.to_f
        j = pos.to_i
        u = pos - j.to_f
        return fl[j] if u < NODE_SNAP

        h = 1.0 / cells.to_f
        u2 = u * u
        u3 = u2 * u
        h00 = 2.0 * u3 - 3.0 * u2 + 1.0
        h10 = u3 - 2.0 * u2 + u
        h01 = -2.0 * u3 + 3.0 * u2
        h11 = u3 - u2
        h00 * fr[j] + h10 * h * dr[j] + h01 * fl[j + 1] + h11 * h * dl[j + 1]
      end

      # The slopes [at 0, at 1] used by #map_edges :extend.
      def slopes
        @slopes ||= begin
          h = 1e-6
          y = map(Numo::DFloat[0.0, h, 1.0 - h, 1.0])
          [(y[1] - y[0]) / h, (y[3] - y[2]) / h].freeze
        end
      end

      # True if the curve never goes down on 0..1 (as promised by its
      # definition; specs check it).
      def monotonic?
        @monotonic
      end

      # True if the formula is meaningful outside 0..1 (see #map_edges).
      def natural?
        @natural
      end

      # The lowest and highest values on 0..1 (sampled at +points+ points),
      # e.g. to see how far a curve overshoots.
      def extent(points = 2001)
        y = map(Numo::DFloat.linspace(0, 1, points))
        [y.min, y.max]
      end

      # The same motion played backwards: 1 - f(1 - x).  An :in curve
      # becomes :out (Curve.db(d).reverse equals Curve.db(-d) on 0..1).
      # Composed curves are never #natural? (they extend with their end
      # slopes).
      def reverse
        f = self
        Curve.new(
          "#{@name}.reverse", kind: Curve.flip_kind(@kind), monotonic: @monotonic, key: [:reverse, key], cells: @cells,
          scalar: ->(x) { 1.0 - f.call(1.0 - x) },
          vector: ->(x) { 1.0 - f.map(1.0 - x) },
        )
      end

      # The curve leaning in (starting slowly): itself if :in or :linear,
      # the #reverse of an :out curve, and the first half of an :in_out
      # curve stretched to 0..1.
      def in
        case @kind
        when :in, :linear then self
        when :out then reverse
        else half(:in)
        end
      end

      # The curve leaning out (arriving gently); see #in.
      def out
        case @kind
        when :out, :linear then self
        when :in then reverse
        else half(:out)
        end
      end

      # The curve's #in form on the first half and its #out form on the
      # second, each at half size (Penner's in-out easing).
      def in_out
        @kind == :in_out ? self : Curve.join(self.in, out, "#{@name}.in_out", :in_out)
      end

      # The #out form on the first half and the #in form on the second.
      def out_in
        Curve.join(out, self.in, "#{@name}.out_in", :in_out)
      end

      # Feeds this curve's output into +other+ (anything Curve.from takes):
      # other(self(x)).
      #
      #     Curve[:sine] >> Curve.steps(8)    # a sine-shaped staircase
      def then(other)
        other = Curve.from(other)
        f = self
        Curve.new(
          "#{@name} >> #{other.name}", kind: @kind, monotonic: @monotonic && other.monotonic?,
          key: [:then, key, other.key],
          scalar: ->(x) { other.call(f.call(x)) },
          vector: ->(x) { other.map(f.map(x)) },
        )
      end
      alias >> then

      # Mixes this curve with +other+: (1 - +amount+) × self + +amount+ ×
      # other.
      #
      #     Curve[:linear].blend(:bounce, 0.5)   # half a bounce
      def blend(other, amount = 0.5)
        other = Curve.from(other)
        a = amount.to_f
        f = self
        Curve.new(
          "#{@name}.blend(#{other.name}, #{MB::M.sigfigs(a, 4)})", kind: @kind, monotonic: @monotonic && other.monotonic? && (0..1).cover?(a),
          key: [:blend, key, other.key, a],
          scalar: ->(x) { (1.0 - a) * f.call(x) + a * other.call(x) },
          vector: ->(x) { f.map(x) * (1.0 - a) + other.map(x) * a },
        )
      end

      # This curve in +count+ equal steps (see Curve.steps).
      def steps(count)
        Curve.steps(count, self)
      end

      # A value identifying the curve for #== and #hash (its name for
      # built-in curves; custom Procs are only equal to themselves).
      def key
        @key
      end

      def ==(other)
        other.is_a?(Curve) && other.key == key
      end
      alias eql? ==

      def hash
        [Curve, key].hash
      end

      def to_s
        @name
      end

      def inspect
        "#<#{self.class.name} #{@name} (#{@kind})>"
      end

      # The opposite lean (:in <-> :out).
      def self.flip_kind(kind)
        { in: :out, out: :in }.fetch(kind, kind)
      end

      # Converts +value+ to a Curve: a Curve, a name (see .named), a Proc
      # (a scalar formula), a number (signed dB, like Envelope's +curve:+),
      # or four numbers (Curve.bezier).  nil stays nil.  +options+ go to
      # named curves.
      def self.from(value, **options)
        case value
        when nil then nil
        when Curve
          raise ArgumentError, "Options #{options} need a curve name, not a Curve (#{value})" unless options.empty?
          value
        when Symbol, String then named(value, **options)
        when Proc then new(&value)
        when Numeric then db(value)
        when Array
          raise ArgumentError, "A bezier curve needs four numbers (got #{value.inspect})" unless value.length == 4
          bezier(*value)
        else
          raise ArgumentError, "Expected a curve name, Curve, Proc, dB number, or bezier values (got #{value.inspect})"
        end
      end

      # Returns the named curve (see the class description and NAMES),
      # with +options+ (+overshoot:+, +cycles:+) for the curves that take
      # them.  Names may end in _in, _out, _in_out, or _out_in.
      def self.named(name, **options)
        name = name.to_sym
        options = options.compact
        if (builder = NAMES[name])
          return builder.call(**options)
        end

        if (m = name.to_s.match(/\A(.+?)_(in_out|out_in|in|out)\z/)) && (builder = NAMES[m[1].to_sym])
          return builder.call(**options).public_send(m[2].to_sym)
        end

        raise ArgumentError, "Unknown curve #{name.inspect} (known: #{NAMES.keys.join(', ')}, with _in, _out, _in_out, or _out_in)"
      end

      # Same as .named, or .from for anything else (e.g. Curve[curve_or_name]).
      def self.[](value, **options)
        from(value, **options)
      end

      # The names .named knows.
      def self.names
        NAMES.keys
      end

      # Joins +first+ (on 0..0.5) and +second+ (on 0.5..1) at half size.
      def self.join(first, second, name, kind)
        Curve.new(
          name, kind: kind, monotonic: first.monotonic? && second.monotonic?, key: [:join, first.key, second.key],
          scalar: ->(x) { x < 0.5 ? first.call(x * 2.0) * 0.5 : 0.5 + second.call(x * 2.0 - 1.0) * 0.5 },
          vector: ->(x) {
            y = Numo::DFloat.zeros(x.length)
            lo = x.lt(0.5)
            hi = ~lo
            y[lo] = first.map(x[lo] * 2.0) * 0.5 if lo.any?
            y[hi] = second.map(x[hi] * 2.0 - 1.0) * 0.5 + 0.5 if hi.any?
            y
          },
        )
      end

      private

      # The #in (or #out) part of an :in_out curve: its first (or second)
      # half stretched to 0..1.
      def half(which)
        f = self
        if which == :in
          Curve.new("#{@name}.in", kind: :in, monotonic: @monotonic, key: [:in, key],
                    scalar: ->(x) { f.call(x * 0.5) * 2.0 }, vector: ->(x) { f.map(x * 0.5) * 2.0 })
        else
          Curve.new("#{@name}.out", kind: :out, monotonic: @monotonic, key: [:out, key],
                    scalar: ->(x) { f.call(x * 0.5 + 0.5) * 2.0 - 1.0 }, vector: ->(x) { f.map(x * 0.5 + 0.5) * 2.0 - 1.0 })
        end
      end
    end
  end
end

require_relative 'curve/library'
