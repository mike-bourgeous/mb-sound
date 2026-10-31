module MB
  module Sound
    module GraphNode
      # Drift: a slow random line for detune, cutoffs, pans, and anything
      # that should wander: +rate+ new random points per second on average
      # (a number, Pitch, or node of Hz; or the time between points, e.g.
      # `4.seconds` or `1.bar`, which follows the tempo), joined by +smooth+:
      #
      # - :cubic (default): a cubic B-spline through the points' neighborhood,
      #   smooth in value, slope, and curvature; never leaves +range+, and
      #   wanders a little less far than the points themselves.
      # - :cosine: a half-cosine glide from point to point (no corners in
      #   value, a gentle stop at each point).
      # - :linear: straight lines between points.
      # - :step (aliases :hold, :sah): each point held for its step, the
      #   classic sample-and-hold random LFO.
      # - any tweening MB::Sound::Curve (a Curve, a curve name other than
      #   the four above, a Proc, or anything Curve.from takes):
      #   `smooth: Curve[:back, overshoot: 0.3]`, `smooth: :elastic`,
      #   `smooth: :ease_in_out`.  Each step moves from point to point along
      #   the curve; curves that overshoot (:back, :elastic, :squiggle)
      #   pass their target and may leave +range+ (not clamped: the
      #   overshoot is the point; clamp after with `.clip(lo, hi)` if
      #   something downstream can't take it).
      #
      # All of them read the same points from the same seed, so switching
      # +smooth+ keeps the path.  +range+ (-1..1 by default, numbers) is
      # where the points lie; `.at(a..b)` maps the default range like any
      # node.  +walk+ (0..1, a share of the range) makes each new point a
      # step of up to that much from the last, reflected at the ends of the
      # range: a bounded random walk that strays slowly instead of jumping
      # anywhere (nil, the default, draws independent points).  +from+ (a
      # number in +range+) starts the line there instead of at a random
      # point (the step, linear, cosine, and curve shapes start exactly on
      # it; :cubic starts near it).
      #
      # +hold+ rests on each point before moving on: a number (0..1) is the
      # share of each step spent holding (1 holds the whole step, like
      # :step); a Length or Duration (`80.ms`, `1.n16`) is a time; a Range
      # of either (`0.1..0.8`, `50.ms..1.seconds`) draws a random hold for
      # each point; a node (e.g. a knob) is a share read at each point.
      # +jitter+ (0..1, a number or node read at each point) spaces the
      # points unevenly: 0 (default) evenly, 1 at Poisson-like random
      # intervals (exponential lengths), the average rate staying +rate+.
      # Walk, hold, jitter, and an overshooting curve together make a
      # restless, creature-like line, best heard as a pan (`drift(3, range:
      # -0.75..0.75, walk: 0.5, hold: 30.ms..400.ms, jitter: 0.5, smooth:
      # Curve[:elastic, overshoot: 0.5])`, the maintainer's picks).
      #
      # Random numbers come from splitmix64 generators seeded from +seed+
      # (or a sub-seed drawn from MB::Sound's root generator when the node
      # is made): one stream for the points, one for holds, one for the
      # spacing, so the points stay the same whatever +hold+, +jitter+, and
      # +smooth+ are.  Renders repeat, at any buffer size.  Plays until its
      # rate node ends (forever for a fixed rate).
      #
      # C kernel MB::Sound::FastTexture.drift, exact Ruby mirror
      # Drift.process_ruby.
      #
      #     play 220.hz.transpose(drift(0.3, walk: 0.3).at(0.1)).saw.lp4(1200).at(-20.db)  # (semitones)
      #     play noise.lp4(drift(0.5).at(300..3000)).at(-18.db)                     # wind
      #     play 110.hz.saw.pan(drift(2.seconds, smooth: :cosine)).at(-20.db)       # wandering pan
      class Drift
        include GraphNode
        include SampleRateHelper
        include TextureRate
        # (draws per point, caught up by sleepers: #catch_up_draws)
        node_traits memory: :short, random: :catch_up_draws

        # Interpolation names and the kernel's mode numbers (4 is a Curve).
        SMOOTH = { step: 0, linear: 1, cosine: 2, cubic: 3 }.freeze

        # The kernel's mode number for a Curve.
        CURVE_MODE = 4

        # Other names for SMOOTH entries.
        SMOOTH_ALIASES = { hold: :step, sah: :step, sample_hold: :step, lerp: :linear, cos: :cosine, spline: :cubic }.freeze

        # Seeds of the hold and spacing streams are the seed XOR these.
        HOLD_STREAM = 0x5851F42D4C957F2D
        SPACING_STREAM = 0x2545F4914F6CDD1D

        # The shortest step spacing jitter allows, in average steps
        # (DRIFT_MIN_LENGTH).
        MIN_LENGTH = 1e-3

        # The random seed.
        attr_reader :seed

        # Creates a drift (see the class description).
        def initialize(rate = 0.2, range: -1.0..1.0, smooth: :cubic, walk: nil, hold: nil, jitter: nil, from: nil, seed: nil, sample_rate: 48000)
          init_rate(rate, 'Drift')
          unless range.is_a?(Range) && range.begin.is_a?(Numeric) && range.end.is_a?(Numeric)
            raise ArgumentError, "Drift range must be a Range of numbers (got #{range.inspect}; use .at(a..b) for node ranges)"
          end
          @range = range.begin.to_f..range.end.to_f

          init_smooth(smooth)

          unless walk.nil? || (walk.is_a?(Numeric) && walk.real? && walk > 0 && walk <= 1)
            raise ArgumentError, "Drift walk must be nil or a share of the range above 0, at most 1 (got #{walk.inspect})"
          end
          @walk = walk.to_f

          init_hold(hold)
          init_jitter(jitter)

          unless from.nil? || (from.is_a?(Numeric) && from.real? && from.between?(*[@range.begin, @range.end].minmax))
            raise ArgumentError, "Drift from must be a number in the range #{@range} (got #{from.inspect})"
          end
          @from = from&.to_f

          init_seed(seed)
          @sample_rate = sample_rate.to_f
          @buf = nil
          @held_inputs = [nil, nil, nil, nil] # (rate, holds, jitter last read, for #catch_up_draws)
          @node_type_name = 'Drift'
          reset
        end

        # Restarts from the seed: the first four points drawn again (the
        # first two at +from+ if given), at the start of a step.
        def reset
          @rng = Numo::UInt64[@seed & Tone::MASK64, (@seed ^ HOLD_STREAM) & Tone::MASK64, (@seed ^ SPACING_STREAM) & Tone::MASK64]
          seed = [@rng[0].to_i]
          points = []
          4.times do
            u = Tone.noise_random(seed)
            points << (points.empty? ? u : self.class.next_point(points.last, u, @walk))
          end
          if @from
            f = @range.end == @range.begin ? 0.0 : (@from - @range.begin) / (@range.end - @range.begin)
            points[0] = points[1] = f
          end
          @rng[0] = seed[0]
          @state = Numo::DFloat[0.0, *points, Float::NAN, Float::NAN]
          self
        end

        def sample(count)
          r = rate_hz(count)
          return nil if r.nil? || (r.is_a?(Numo::NArray) && r.empty?)
          count = r.length if r.is_a?(Numo::NArray)

          hold_lo, hold_hi = hold_inputs(count)
          return nil if @hold_kind && (hold_lo.nil? || hold_hi.nil?)
          jitter = @jitter_node ? @jitter_node.sample(count) : @jitter
          return nil if @jitter_node && jitter.nil?

          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          h = @held_inputs
          h[0] = NodeTraits.held(r)
          h[1] = NodeTraits.held(hold_lo)
          h[2] = NodeTraits.held(hold_hi)
          h[3] = NodeTraits.held(jitter)
          Kernels.drift(
            @buf, r, @state, @rng, @sample_rate, @range.begin, @range.end, @mode, @walk,
            @table, hold_lo, hold_hi, @hold_kind == :samples ? 1 : 0, jitter
          )
        end

        # NodeTraits' catch-up: renders (and drops) +frames+ samples at the
        # rate, holds, and jitter last read, so a voice that slept moves on
        # through the points it would have moved through awake (exact while
        # they hold still, as constants do).
        def catch_up_draws(frames)
          h = @held_inputs
          return if h[0].nil?

          Kernels.drift(
            NodeTraits.scratch(frames), h[0], @state, @rng, @sample_rate, @range.begin, @range.end, @mode, @walk,
            @table, h[1], h[2], @hold_kind == :samples ? 1 : 0, h[3]
          )
          nil
        end

        # The random streams, the points and position, and the inputs the
        # catch-up holds (for a graph that replaces this one; Session::Carry:
        # a drift in a sleeping voice that never rendered in the new graph
        # catches up at the old one's rate, carry-1).
        def plan_snapshot
          { rng: @rng.dup, state: @state.dup, held: @held_inputs.dup }
        end

        def plan_restore(snapshot)
          return unless snapshot
          @rng[0..] = snapshot[:rng]
          @state = snapshot[:state].dup
          @held_inputs.replace(snapshot[:held]) if snapshot[:held]
        end

        def sources
          s = rate_sources
          [@hold_lo, @hold_hi].uniq.each_with_index do |h, i|
            node = h.is_a?(Length::Source) ? (h.node? ? h.node : nil) : (h.respond_to?(:sample) ? h : nil)
            s[i == 0 ? :hold : :hold_max] = node if node
          end
          s[:jitter] = @jitter_node if @jitter_node
          s
        end

        def to_s
          w = @walk > 0 ? ", walk #{MB::M.sigfigs(@walk, 3)}" : ''
          h = @hold_kind ? ", hold #{@hold_text}" : ''
          j = @jitter_node ? ', jitter node' : (@jitter ? ", jitter #{MB::M.sigfigs(@jitter, 3)}" : '')
          "Drift #{rate_text}, #{@curve || @smooth}, #{MB::M.sigfigs(@range.begin, 3)}..#{MB::M.sigfigs(@range.end, 3)}#{w}#{h}#{j}"
        end

        private

        # Sets @mode, @smooth, @curve, and @table from +smooth+.
        def init_smooth(smooth)
          name = (smooth.is_a?(Symbol) || smooth.is_a?(String)) ? SMOOTH_ALIASES.fetch(smooth.to_sym, smooth.to_sym) : nil
          if name && SMOOTH.include?(name)
            @smooth = name
            @mode = SMOOTH[name]
            @curve = nil
            @table = nil
            return
          end

          begin
            @curve = MB::Sound::Curve.from(smooth)
          rescue ArgumentError => e
            raise ArgumentError, "Drift smooth must be one of #{(SMOOTH.keys + SMOOTH_ALIASES.keys).map(&:inspect).join(', ')} or a Curve " \
                                 "(a Curve, curve name, Proc, ...; #{e.message})"
          end
          raise ArgumentError, 'Drift smooth must not be nil' if @curve.nil?
          @smooth = :curve
          @mode = CURVE_MODE
          @table = @curve.value_table.to_a
        end

        # Sets @hold_kind (nil, :share, or :samples), @hold_lo and @hold_hi
        # (numbers, nodes, or Length::Sources), and @hold_text.
        def init_hold(hold)
          @hold_kind = nil
          @hold_lo = @hold_hi = nil
          return if hold.nil?

          @hold_text = hold.to_s
          lo, hi = hold.is_a?(Range) ? [hold.begin, hold.end] : [hold, hold]
          if [lo, hi].all? { |v| v.is_a?(Numeric) }
            unless [lo, hi].all? { |v| v.real? && v >= 0 && v <= 1 }
              raise ArgumentError, "Drift hold shares must be from 0 to 1 (got #{hold.inspect}; use a Length such as 80.ms for a time)"
            end
            @hold_kind = :share
            @hold_lo, @hold_hi = lo.to_f, hi.to_f
          elsif [lo, hi].all? { |v| v.is_a?(Length::Seconds) || v.is_a?(Length::Samples) || v.is_a?(Sequence::Duration) }
            @hold_kind = :samples
            @hold_lo = Length::Source.new(lo)
            @hold_hi = hold.is_a?(Range) ? Length::Source.new(hi) : @hold_lo
          elsif !hold.is_a?(Range) && hold.respond_to?(:get_sampler)
            @hold_kind = :share
            @hold_lo = @hold_hi = hold.get_sampler
          else
            raise ArgumentError, 'Drift hold must be a share of each step (0..1), a Length or Duration, a Range of either, ' \
                                 "or a node of shares (got #{hold.inspect})"
          end
        end

        # +count+ samples of the hold range as the kernel reads it: [lo, hi]
        # (numbers or NArrays; nil if a node ended), or [nil, nil] for no
        # hold.
        def hold_inputs(count)
          return [nil, nil] unless @hold_kind

          lo = hold_input(@hold_lo, count)
          hi = @hold_hi.equal?(@hold_lo) ? lo : hold_input(@hold_hi, count)
          [lo, hi]
        end

        def hold_input(h, count)
          case h
          when Numeric then h
          when Length::Source then h.samples(count, @sample_rate)
          else h.sample(count)
          end
        end

        # Sets @jitter (a number or nil) and @jitter_node from +jitter+.
        def init_jitter(jitter)
          @jitter = nil
          @jitter_node = nil
          case jitter
          when nil
          when Numeric
            raise ArgumentError, "Drift jitter must be from 0 to 1 (got #{jitter})" unless jitter.real? && jitter >= 0 && jitter <= 1
            @jitter = jitter.to_f if jitter > 0
          else
            raise ArgumentError, "Drift jitter must be a number from 0 to 1 or a node (got #{jitter.inspect})" unless jitter.respond_to?(:get_sampler)
            @jitter_node = jitter.get_sampler
          end
        end

        public

        # The next point (0...1) from the last point +last+ and a uniform
        # random +u+: +u+ itself without a walk, else a step of up to +walk+
        # reflected at 0 and 1 (as in the kernel).
        def self.next_point(last, u, walk)
          return u unless walk > 0

          v = last + walk * (2.0 * u - 1.0)
          if v < 0
            -v
          elsif v > 1.0
            2.0 - v
          else
            v
          end
        end

        # A step's share of a sample (+rate+ / +fs+), as the kernel's
        # texture_increment: 0 for zero, negative, or NaN rates, at most 1.
        def self.increment(rate, fs)
          inc = rate / fs
          return 0.0 unless inc > 0
          inc > 1.0 ? 1.0 : inc
        end

        # The kernel's drift_hold: a hold share from a uniform draw +u+.
        def self.hold_share(u, lo, hi, kind, inc)
          h = lo + (hi - lo) * u
          h *= inc if kind != 0
          return 0.0 unless h > 0
          h > 1.0 ? 1.0 : h
        end

        # The kernel's drift_speed: a step's speed from a uniform draw +u+
        # and jitter +j+.
        def self.step_speed(u, j)
          return 1.0 unless j > 0
          j = 1.0 if j > 1.0
          len = (1.0 - j) + j * -Math.log(1.0 - u)
          len = MIN_LENGTH if len < MIN_LENGTH
          1.0 / len
        end

        # Phases this close below 1 count as reaching it (DRIFT_EDGE).
        EDGE = 1e-9

        # The exact Ruby mirror of MB::Sound::FastTexture.drift (same
        # arguments and state; see ext/mb/sound/fast_texture/fast_texture.c).
        def self.process_ruby(out, rate, state, rng, sample_rate, lo, hi, mode, walk, table, hold_lo, hold_hi, hold_kind, jitter)
          fs = sample_rate.to_f
          raise ArgumentError, 'The sample rate must be positive' unless fs > 0
          raise ArgumentError, 'The mode must be 0 (step), 1 (linear), 2 (cosine), 3 (cubic), or 4 (curve)' unless (0..4).include?(mode)
          raise ArgumentError, 'The walk must be from 0 to 1' unless walk >= 0 && walk <= 1
          raise ArgumentError, 'A curve drift needs a curve table' if mode == CURVE_MODE && !(table.is_a?(Array) && table.length == 4)

          n = out.length
          rs = signal_values(rate, n)
          holds = !hold_lo.nil? || !hold_hi.nil?
          jitters = !jitter.nil?
          hls = signal_values(hold_lo, n)
          hhs = signal_values(hold_hi, n)
          js = signal_values(jitter, n)
          at = ->(v, i) { v.is_a?(Array) ? v[i] : v }
          seeds = [[rng[0].to_i], [rng[1].to_i], [rng[2].to_i]]
          lo = lo.to_f
          span = hi.to_f - lo
          walk = walk.to_f

          phase, p0, p1, p2, p3, hold, speed = state.to_a

          n.times do |i|
            inc = increment(at.(rs, i), fs)

            speed = jitters ? step_speed(Tone.noise_random(seeds[2]), at.(js, i)) : 1.0 if speed.nan?
            hold = holds ? hold_share(Tone.noise_random(seeds[1]), at.(hls, i), at.(hhs, i), hold_kind, inc * speed) : 0.0 if hold.nan?

            t = phase
            t = t < hold ? 0.0 : (t - hold) / (1.0 - hold) if hold > 0
            y = case mode
                when 0 then p1
                when 1 then p1 + (p2 - p1) * t
                when 2 then p1 + (p2 - p1) * ((1.0 - Math.cos(Math::PI * t)) * 0.5)
                when 4 then p1 + (p2 - p1) * MB::Sound::Curve.lookup_ruby(table, t)
                else
                  t2 = t * t
                  t3 = t2 * t
                  s = 1.0 - t
                  (s * s * s * p0 + (3.0 * t3 - 6.0 * t2 + 4.0) * p1 + (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) * p2 + t3 * p3) / 6.0
                end
            out[i] = lo + span * y

            d = inc * speed
            phase += d > 1.0 ? 1.0 : d
            next unless phase >= 1.0 - EDGE

            phase -= (phase + EDGE).floor
            phase = 0.0 if phase < 0

            u = Tone.noise_random(seeds[0])
            v = next_point(p3, u, walk)
            p0 = p1
            p1 = p2
            p2 = p3
            p3 = v

            speed = step_speed(Tone.noise_random(seeds[2]), at.(js, i)) if jitters
            hold = hold_share(Tone.noise_random(seeds[1]), at.(hls, i), at.(hhs, i), hold_kind, inc * speed) if holds
          end

          state[0] = phase
          state[1] = p0
          state[2] = p1
          state[3] = p2
          state[4] = p3
          state[5] = hold
          state[6] = speed
          3.times { |k| rng[k] = seeds[k][0] }
          out
        end

        # A signal input as the kernels read it: a Float, or an Array of
        # float32 values (real parts of complex inputs).
        def self.signal_values(value, n)
          case value
          when nil then 0.0
          when Numeric then value.to_f
          when Numo::NArray
            raise ArgumentError, 'array length does not match sample buffer length' unless value.length == n
            v = value.is_a?(Numo::SComplex) || value.is_a?(Numo::DComplex) ? value.real : value
            Numo::SFloat.cast(v).to_a
          else
            raise ArgumentError, "Expected a number or NArray (got #{value.class})"
          end
        end
      end

      Kernels.register :drift, c: FastTexture.method(:drift), ruby: Drift.method(:process_ruby)
    end
  end
end
