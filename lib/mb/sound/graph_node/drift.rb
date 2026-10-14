module MB
  module Sound
    module GraphNode
      # Drift: a slow random line for detune, cutoffs, pans, and anything
      # that should wander: +rate+ new random points per second (a number,
      # Pitch, or node of Hz; or the time between points, e.g. `4.seconds`
      # or `1.bar`, which follows the tempo), joined by +smooth+:
      #
      # - :cubic (default): a cubic B-spline through the points' neighborhood,
      #   smooth in value, slope, and curvature; never leaves +range+, and
      #   wanders a little less far than the points themselves.
      # - :cosine: a half-cosine glide from point to point (no corners in
      #   value, a gentle stop at each point).
      # - :linear: straight lines between points.
      # - :step (aliases :hold, :sah): each point held for its step, the
      #   classic sample-and-hold random LFO.
      #
      # All four read the same points from the same seed, so switching
      # +smooth+ keeps the path.  +range+ (-1..1 by default, numbers) is
      # where the points lie; `.at(a..b)` maps the default range like any
      # node.  +walk+ (0..1, a share of the range) makes each new point a
      # step of up to that much from the last, reflected at the ends of the
      # range: a bounded random walk that strays slowly instead of jumping
      # anywhere (nil, the default, draws independent points).
      #
      # Random points come from a splitmix64 generator seeded with +seed+
      # (or a sub-seed drawn from MB::Sound's root generator when the node
      # is made), so renders repeat, at any buffer size.  Plays until its
      # rate node ends (forever for a fixed rate).
      #
      # C kernel MB::Sound::FastTexture.drift, exact Ruby mirror
      # Drift.process_ruby.
      #
      #     play 220.hz.transpose(drift(0.3, walk: 0.3).at(-0.1..0.1)).saw.lp4(1200).at(-20.db)  # (semitones)
      #     play noise.lp4(drift(0.5).at(300..3000)).at(-18.db)                     # wind
      #     play 110.hz.saw.pan(drift(2.seconds, smooth: :cosine)).at(-20.db)       # wandering pan
      class Drift
        include GraphNode
        include SampleRateHelper
        include TextureRate

        # Interpolation names and the kernel's mode numbers.
        SMOOTH = { step: 0, linear: 1, cosine: 2, cubic: 3 }.freeze

        # Other names for SMOOTH entries.
        SMOOTH_ALIASES = { hold: :step, sah: :step, sample_hold: :step, lerp: :linear, cos: :cosine, spline: :cubic }.freeze

        # The random seed.
        attr_reader :seed

        # Creates a drift (see the class description).
        def initialize(rate = 0.2, range: -1.0..1.0, smooth: :cubic, walk: nil, seed: nil, sample_rate: 48000)
          init_rate(rate, 'Drift')
          unless range.is_a?(Range) && range.begin.is_a?(Numeric) && range.end.is_a?(Numeric)
            raise ArgumentError, "Drift range must be a Range of numbers (got #{range.inspect}; use .at(a..b) for node ranges)"
          end
          @range = range.begin.to_f..range.end.to_f

          name = SMOOTH_ALIASES.fetch(smooth, smooth)
          unless SMOOTH.include?(name)
            raise ArgumentError, "Drift smooth must be one of #{(SMOOTH.keys + SMOOTH_ALIASES.keys).map(&:inspect).join(', ')} (got #{smooth.inspect})"
          end
          @smooth = name
          @mode = SMOOTH[name]

          unless walk.nil? || (walk.is_a?(Numeric) && walk.real? && walk > 0 && walk <= 1)
            raise ArgumentError, "Drift walk must be nil or a share of the range above 0, at most 1 (got #{walk.inspect})"
          end
          @walk = walk.to_f

          init_seed(seed)
          @sample_rate = sample_rate.to_f
          @buf = nil
          @node_type_name = 'Drift'
          reset
        end

        # Restarts from the seed: the first four points drawn again, at the
        # start of a step.
        def reset
          @rng = Numo::UInt64[@seed & Tone::MASK64]
          seed = [@rng[0].to_i]
          points = []
          4.times do
            u = Tone.noise_random(seed)
            points << (points.empty? ? u : self.class.next_point(points.last, u, @walk))
          end
          @rng[0] = seed[0]
          @state = Numo::DFloat[0.0, *points]
          self
        end

        def sample(count)
          r = rate_hz(count)
          return nil if r.nil? || (r.is_a?(Numo::NArray) && r.empty?)
          count = r.length if r.is_a?(Numo::NArray)

          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          MB::Sound::FastTexture.drift(@buf, r, @state, @rng, @sample_rate, @range.begin, @range.end, @mode, @walk)
        end

        def sources
          rate_sources
        end

        def to_s
          w = @walk > 0 ? ", walk #{MB::M.sigfigs(@walk, 3)}" : ''
          "Drift #{rate_text}, #{@smooth}, #{MB::M.sigfigs(@range.begin, 3)}..#{MB::M.sigfigs(@range.end, 3)}#{w}"
        end

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

        # Phases this close below 1 count as reaching it (DRIFT_EDGE).
        EDGE = 1e-9

        # The exact Ruby mirror of MB::Sound::FastTexture.drift (same
        # arguments and state; see ext/mb/sound/fast_texture/fast_texture.c).
        def self.process_ruby(out, rate, state, rng, sample_rate, lo, hi, mode, walk)
          fs = sample_rate.to_f
          raise ArgumentError, 'The sample rate must be positive' unless fs > 0
          raise ArgumentError, 'The mode must be 0 (step), 1 (linear), 2 (cosine), or 3 (cubic)' unless (0..3).include?(mode)
          raise ArgumentError, 'The walk must be from 0 to 1' unless walk >= 0 && walk <= 1

          n = out.length
          rs = signal_values(rate, n)
          seed = [rng[0].to_i]
          lo = lo.to_f
          span = hi.to_f - lo
          walk = walk.to_f

          phase, p0, p1, p2, p3 = state.to_a

          n.times do |i|
            t = phase
            y = case mode
                when 0 then p1
                when 1 then p1 + (p2 - p1) * t
                when 2 then p1 + (p2 - p1) * ((1.0 - Math.cos(Math::PI * t)) * 0.5)
                else
                  t2 = t * t
                  t3 = t2 * t
                  s = 1.0 - t
                  (s * s * s * p0 + (3.0 * t3 - 6.0 * t2 + 4.0) * p1 + (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) * p2 + t3 * p3) / 6.0
                end
            out[i] = lo + span * y

            phase += increment(rs.is_a?(Array) ? rs[i] : rs, fs)
            next unless phase >= 1.0 - EDGE

            phase -= (phase + EDGE).floor
            phase = 0.0 if phase < 0

            u = Tone.noise_random(seed)
            v = next_point(p3, u, walk)
            p0 = p1
            p1 = p2
            p2 = p3
            p3 = v
          end

          state[0] = phase
          state[1] = p0
          state[2] = p1
          state[3] = p2
          state[4] = p3
          rng[0] = seed[0]
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
    end
  end
end
