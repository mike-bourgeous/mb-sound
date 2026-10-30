module MB
  module Sound
    # A knob gesture as keyframes (gesture-curves, agreed 2026-10-18): what
    # `turn :space, 0 => 0.30, 1.n8 => 0.50, 1.n4 => 0.62` writes, and what a
    # held key in the racks pane becomes when it ends (Session#gesture_line).
    #
    # Keys are [frame, value] pairs (frames after the gesture's start, the
    # knob's units).  Between keys the knob moves by +curve+:
    #
    # - nil (the default): a monotone cubic through the keys (Fritsch-Carlson
    #   slopes, the same as compand's: never overshoots, never leaves the
    #   range of its keys), in the knob's own scale (octaves for :exp knobs);
    # - :linear: straight lines;
    # - :step: a jump at each key (with the knob's short glide), the raw
    #   steps of a recorded gesture;
    # - any Curve name (:smooth, :elastic, ...): each segment shaped by it.
    #
    # The knob reaches each key's value on the key's frame exactly (frame t
    # of the segment from key a to key b holds a + (b - a) * s((t - ta) /
    # (tb - ta))), so keys printed and read back play the same samples.
    #
    # .fit simplifies a recorded gesture's steps into the fewest keys whose
    # curve (monotone cubic or linear, whichever needs fewer) passes within
    # +tolerance+ (1e-3 of the knob's range by default, in its own scale) of
    # every step, with a deterministic budget (MAX_KEYS keys; never
    # wall-clock time), so a gesture fits the same on any machine.  Stepped
    # knobs (read through Knob#choose) keep their steps; +tolerance: 0+ too.
    class Gesture
      # The default fitting tolerance, as a share of the knob's range (in
      # its own scale).
      TOLERANCE = 1e-3

      # The most keys a fit adds (its effort budget).
      MAX_KEYS = 64

      # Curves a gesture takes besides Curve names.
      SPECIAL_CURVES = [nil, :linear, :step].freeze

      # [[frame, value], ...], frames rising from the first.
      attr_reader :keys

      # nil (monotone cubic), :linear, :step, or a Curve name.
      attr_reader :curve

      # The largest distance of the raw steps from the fitted curve, as a
      # share of the knob's range (nil unless made by .fit).
      attr_reader :error

      def initialize(keys, curve: nil, error: nil)
        raise ArgumentError, 'A gesture needs at least one key' if keys.empty?
        unless keys.all? { |f, v| f.is_a?(Integer) && f >= 0 && v.is_a?(Numeric) && v.real? && v.finite? }
          raise ArgumentError, "Gesture keys are [[frame, value], ...] with whole frames from 0 (got #{keys.inspect})"
        end
        raise ArgumentError, 'Gesture keys must rise' unless keys.each_cons(2).all? { |a, b| b[0] > a[0] }
        Gesture.check_curve(curve)
        @keys = keys.map { |f, v| [f, v.to_f].freeze }.freeze
        @curve = curve
        @error = error
        freeze
      end

      # Checks a gesture curve (nil, :linear, :step, a Curve name, or a
      # Curve).
      def self.check_curve(curve)
        return if SPECIAL_CURVES.include?(curve)
        MB::Sound::Curve[curve]
      rescue ArgumentError => e
        raise ArgumentError, "A gesture's curve: is :linear, :step, or a Curve name (#{e.message})"
      end

      # Fits +steps+ ([[frame, value], ...]; a recorded gesture) for a knob
      # with Knob::Spec +spec+ (see the class description).  +stepped+
      # keeps the steps (a knob read through #choose).
      def self.fit(steps, spec, tolerance: TOLERANCE, stepped: false, budget: MAX_KEYS)
        steps = steps.map { |f, v| [Integer(f), v.to_f] }
        tol = tolerance.to_f
        return new(steps, curve: steps.length == 1 ? nil : :step, error: 0.0) if stepped || tol <= 0
        return new(steps, error: 0.0) if steps.length <= 2

        xs = steps.map(&:first)
        ps = steps.map { |_, v| spec.position(v) }
        cubic = fit_mode(xs, ps, :cubic, tol, budget)
        linear = fit_mode(xs, ps, :linear, tol, budget)
        # Fewer keys wins (within the tolerance); a tie goes to the default
        # (cubic: no curve: to print)
        mode, (idx, err) =
          if cubic[1] <= tol && linear[1] <= tol
            linear[0].length < cubic[0].length ? [:linear, linear] : [nil, cubic]
          elsif linear[1] <= tol then [:linear, linear]
          elsif cubic[1] <= tol then [nil, cubic]
          else linear[1] < cubic[1] ? [:linear, linear] : [nil, cubic]
          end
        new(idx.map { |i| steps[i] }, curve: mode, error: err)
      end

      # Greedy refinement (deterministic): from the end points, adds the
      # step farthest from the curve until every step is within
      # +tolerance+ or +budget+ keys are used.  Returns [indexes, error].
      def self.fit_mode(xs, ps, mode, tolerance, budget)
        idx = [0, xs.length - 1]
        loop do
          errs = errors(xs, ps, idx, mode)
          worst = errs.each_with_index.max_by { |e, i| [e, -i] }
          return [idx, worst[0]] if worst[0] <= tolerance || idx.length >= budget
          idx = (idx + [worst[1]]).sort
        end
      end

      # Distances of every step from the curve through keys +idx+.
      def self.errors(xs, ps, idx, mode)
        kx = idx.map { |i| xs[i] }
        kp = idx.map { |i| ps[i] }
        shapes = segment_shapes(kx, kp, mode)
        seg = 0
        xs.each_with_index.map do |x, i|
          next 0.0 if i == 0
          seg += 1 while seg < kx.length - 2 && x > kx[seg + 1]
          a, b = kx[seg], kx[seg + 1]
          u = (x - a).to_f / (b - a)
          v = kp[seg] + (kp[seg + 1] - kp[seg]) * shapes[seg].(u)
          (v - ps[i]).abs
        end
      end

      # Normalized shapes s(u) (0..1 -> 0..1) of each segment between keys
      # at frames +kx+ with positions +kp+: monotone cubic Hermite
      # segments (Fritsch-Carlson slopes), or straight lines.
      def self.segment_shapes(kx, kp, mode)
        n = kx.length - 1
        return Array.new(n) { ->(u) { u } } if mode == :linear || n < 2
        slopes = GraphNode::Dynamics::Transfer.pchip_slopes(kx.map(&:to_f), kp)
        Array.new(n) do |k|
          h = (kx[k + 1] - kx[k]).to_f
          dy = kp[k + 1] - kp[k]
          next ->(u) { u } if dy == 0
          a = h * slopes[k] / dy
          b = h * slopes[k + 1] / dy
          ->(u) { hermite(u, a, b) }
        end
      end

      # The normalized Hermite shape: h01(u) + a h10(u) + b h11(u).
      def self.hermite(u, a, b)
        u2 = u * u
        u3 = u2 * u
        (3 * u2 - 2 * u3) + a * (u3 - 2 * u2 + u) + b * (u3 - u2)
      end

      # The segments to schedule for a knob with Knob::Spec +spec+:
      # [[first frame, frames, from value, to value, Curve or nil], ...]
      # after the first key, which is [first key frame, value] (a jump);
      # :step gestures give their keys only.  Returns [first, segments].
      def segments(spec)
        first = @keys[0]
        return [first, []] if @keys.length == 1 || @curve == :step
        shape_curve = !SPECIAL_CURVES.include?(@curve) ? MB::Sound::Curve[@curve] : nil
        kx = @keys.map(&:first)
        kp = @keys.map { |_, v| spec.position(spec.clamp(v)) }
        cubic = @curve.nil? ? Gesture.segment_curves(kx, kp) : nil
        segs = @keys.each_cons(2).each_with_index.map do |((fa, va), (fb, vb)), k|
          [fa + 1, fb - fa, va, vb, shape_curve || cubic&.[](k)]
        end
        [first, segs]
      end

      # Curves for the monotone cubic segments (see .segment_shapes), as
      # MB::Sound::Curves for Knob#ramp_to (vectorized, the same floats at
      # any buffer size: each frame's value comes from its own position in
      # the segment).
      def self.segment_curves(kx, kp)
        n = kx.length - 1
        return Array.new(n) if n < 2
        slopes = GraphNode::Dynamics::Transfer.pchip_slopes(kx.map(&:to_f), kp)
        Array.new(n) do |k|
          h = (kx[k + 1] - kx[k]).to_f
          dy = kp[k + 1] - kp[k]
          next nil if dy == 0
          a = h * slopes[k] / dy
          b = h * slopes[k + 1] / dy
          MB::Sound::Curve.new(:gesture, monotonic: true,
                               scalar: ->(u) { hermite(u, a, b) },
                               vector: ->(u) { u2 = u * u; u3 = u2 * u; (u2 * 3 - u3 * 2) + (u3 - u2 * 2 + u) * a + (u3 - u2) * b })
        end
      end

      # The knob's value on frame +frame+ (after the gesture's start) for a
      # knob with Knob::Spec +spec+, as scheduled (exactly what the knob
      # plays, the glide of :step keys aside).
      def value_at(frame, spec)
        return @keys[0][1] if frame <= @keys[0][0]
        return @keys[-1][1] if frame >= @keys[-1][0]
        k = @keys.each_cons(2).find_index { |(fa, _), (fb, _)| frame > fa && frame <= fb }
        (fa, va), (fb, vb) = @keys[k], @keys[k + 1]
        return va if @curve == :step
        _, segs = segments(spec)
        c = segs[k][4]
        u = (frame - fa).to_f / (fb - fa)
        s = c ? c.call(u) : u
        pa = spec.position(va)
        pb = spec.position(vb)
        spec.value(pa + (pb - pa) * s)
      end

      # The `turn` line: `turn :space, 0 => 0.3, 1.n8 => 0.5, 1.n4 => 0.62`
      # (times in the most musical unit that is exact at +per_sample+ whole
      # notes per frame, else samples; values to 6 significant figures),
      # with `curve:` unless it is the default.  One key at frame 0 is
      # `turn :space, 0.42`.
      def to_ruby(name, per_sample:, rate: 48000)
        return "turn #{name.inspect}, #{GraphNode::Knob.number(@keys[0][1])}" if @keys.length == 1 && @keys[0][0] == 0
        times = Gesture.times_text(@keys.map(&:first), per_sample, rate)
        pairs = @keys.each_with_index.map { |(_f, v), i| "#{times[i]} => #{GraphNode::Knob.number(v)}" }
        pairs << "curve: #{@curve.inspect}" unless @curve.nil?
        "turn #{name.inspect}, #{pairs.join(', ')}"
      end

      # Frame offsets as Ruby, in ONE unit for the whole line (maintainer,
      # 2026-10-18: never mixed): note lengths (1.n8, 3.n16, 1.n12) when
      # every key is exactly on the grid at +per_sample+ whole notes per
      # frame, else milliseconds when every key is a whole millisecond at
      # +rate+, else exact seconds (`(1r/60).seconds`).  0 stays 0.
      def self.times_text(frames, per_sample, rate)
        rate = rate.to_r
        wns = frames.map { |f| f * per_sample.to_r }
        if wns.all? { |wn| (wn * 64).denominator == 1 || (wn * 24).denominator == 1 }
          return wns.map { |wn| wn == 0 ? '0' : RubyValue.duration(Sequence::Duration.new(wn)) }
        end
        secs = frames.map { |f| f / rate }
        if secs.all? { |x| (x * 1000).denominator == 1 }
          return secs.map { |x| x == 0 ? '0' : "#{(x * 1000).to_i}.ms" }
        end
        secs.map { |x|
          next '0' if x == 0
          RubyValue.unit(x.denominator == 1 ? x.to_i : x, 'seconds')
        }
      end

      # A Gesture from a `turn` Hash ({ time => value }; times as 0, note
      # lengths and Durations, Lengths (480.samples, 250.ms), or plain
      # numbers of bars), at +per_sample+ whole notes per frame, +rate+
      # frames per second, and +bar_length+ whole notes.
      def self.from_hash(hash, curve: nil, per_sample:, rate:, bar_length: 1)
        keys = hash.map { |t, v| [frames_of(t, per_sample: per_sample, rate: rate, bar_length: bar_length), v] }.sort_by(&:first)
        dup = keys.each_cons(2).find { |a, b| a[0] == b[0] }
        raise ArgumentError, "Two gesture keys land on frame #{dup[0][0]} (#{hash.keys.map(&:inspect).join(', ')})" if dup
        bad = keys.find { |_, v| !(v.is_a?(Numeric) && v.real?) }
        raise ArgumentError, "Gesture values are numbers (got #{bad[1].inspect} at #{bad[0]})" if bad
        new(keys, curve: curve)
      end

      # Frames after a gesture's start for time +t+ (see .from_hash).
      def self.frames_of(t, per_sample:, rate:, bar_length: 1)
        f = case t
            when Sequence::Duration then t.whole_notes / per_sample.to_r
            when Length::Samples then t.value.to_r
            when Length::Seconds then t.value.to_r * rate
            when Numeric
              raise ArgumentError, "Gesture times are 0 or more (got #{t})" unless t.real? && t >= 0
              t.to_r * bar_length / per_sample.to_r
            else
              raise ArgumentError, "Gesture times are note lengths (1.n8), Lengths (480.samples, 250.ms), or bars (got #{t.inspect})"
            end
        f.round
      end
    end
  end
end
