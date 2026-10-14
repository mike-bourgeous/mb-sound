module MB
  module Sound
    module GraphNode
      # Shared by Dust and Drift: a rate given as Hz (a number, a Pitch, or a
      # node of Hz that may move every sample) or as the time between events
      # (a Length such as `2.seconds` or `480.samples`, or a Duration such as
      # `1.beat`, which follows the tempo).
      module TextureRate
        private

        def init_rate(rate, what)
          @rate = rate
          @rate_value = nil
          @rate_node = nil
          @rate_period = nil

          case rate
          when MB::Sound::Pitch
            f = rate.oscillator_frequency
            f.is_a?(Numeric) ? (@rate_value = f.to_f) : (@rate_node = f.get_sampler)
          when Length::Seconds, Length::Samples, Sequence::Duration
            @rate_period = Length::Source.new(rate)
          when Numeric
            raise ArgumentError, "#{what} rate must be a real number (got #{rate})" unless rate.real?
            @rate_value = rate.to_f
          else
            unless rate.respond_to?(:sample)
              raise ArgumentError, "#{what} rate must be Hz (a number, Pitch, or node) or a length between events (e.g. 2.seconds, 1.beat; got #{rate.inspect})"
            end
            @rate_node = rate.get_sampler
          end
        end

        # +count+ samples of the rate in Hz (a Float or an NArray), or nil
        # once a rate node has ended.
        def rate_hz(count)
          return @rate_value if @rate_value
          return @rate_node.sample(count) if @rate_node

          period = @rate_period.samples(count, @sample_rate)
          return nil if period.nil?
          period.is_a?(Numeric) ? @sample_rate / period.to_f : @sample_rate / Numo::DFloat.cast(period)
        end

        def rate_sources
          return { rate: @rate_node } if @rate_node
          return { rate: @rate_period.node } if @rate_period&.node?
          {}
        end

        def rate_text
          return "#{MB::M.sigfigs(@rate_value, 4)} Hz" if @rate_value
          return 'every ' + @rate.to_s if @rate_period
          'node Hz'
        end

        def init_seed(seed)
          @seed = seed.nil? ? MB::Sound.next_seed : Integer(seed)
        end
      end

      # Dust: sparse random single-sample impulses, about +rate+ per second
      # at random times (Poisson-like; SuperCollider's Dust and Dust2), each
      # with a random height spread evenly over +range+ (0..1 by default,
      # -1..1 with +bipolar+).  As triggers they strike resonators and
      # envelopes at random velocities (`dust(3).ping(880, decay: 0.4)`,
      # `adsr(..., trigger: dust(2))`); through a filter they are crackle and
      # rain.
      #
      # Every sample draws one number from a splitmix64 generator seeded with
      # +seed+ (or a sub-seed drawn from MB::Sound's root generator when the
      # node is made; see MB::Sound.seed), so renders repeat and the impulses
      # land on the same samples at any buffer size.  The rate may be a
      # number, a Pitch, a node of Hz moving every sample (a swell of
      # density), or a length between impulses on average (`1.beat`).  Plays
      # until its rate node ends (forever for a fixed rate).
      #
      # C kernel MB::Sound::FastTexture.dust, exact Ruby mirror
      # Dust.process_ruby.
      #
      #     play dust(8).ping(2000, decay: 0.05).at(-6.db)                     # sparse ticks
      #     play dust(400, bipolar: true).filter(:highpass, cutoff: 1500).at(-18.db)  # vinyl crackle
      class Dust
        include GraphNode
        include SampleRateHelper
        include TextureRate

        # The random seed.
        attr_reader :seed

        # The range of impulse heights.
        attr_reader :range

        # Creates a dust source (see the class description).  +range+ (a
        # Range of numbers) overrides the heights' range; +bipolar+ makes
        # the default -1..1 instead of 0..1.
        def initialize(rate, bipolar: false, range: nil, seed: nil, sample_rate: 48000)
          init_rate(rate, 'Dust')
          range ||= bipolar ? -1.0..1.0 : 0.0..1.0
          unless range.is_a?(Range) && range.begin.is_a?(Numeric) && range.end.is_a?(Numeric)
            raise ArgumentError, "Dust range must be a Range of numbers (got #{range.inspect})"
          end
          @range = range.begin.to_f..range.end.to_f
          init_seed(seed)
          @sample_rate = sample_rate.to_f
          @buf = nil
          @node_type_name = 'Dust'
          reset
        end

        # Restarts the random sequence from the seed.
        def reset
          @rng = Numo::UInt64[@seed & Tone::MASK64]
          self
        end

        def sample(count)
          r = rate_hz(count)
          return nil if r.nil? || (r.is_a?(Numo::NArray) && r.empty?)
          count = r.length if r.is_a?(Numo::NArray)

          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          MB::Sound::FastTexture.dust(@buf, r, @rng, @sample_rate, @range.begin, @range.end)
        end

        def sources
          rate_sources
        end

        def to_s
          "Dust #{rate_text}, #{MB::M.sigfigs(@range.begin, 3)}..#{MB::M.sigfigs(@range.end, 3)}"
        end

        # The exact Ruby mirror of MB::Sound::FastTexture.dust (same arguments;
        # see ext/mb/sound/fast_texture/fast_texture.c).
        def self.process_ruby(out, rate, rng, sample_rate, lo, hi)
          fs = sample_rate.to_f
          raise ArgumentError, 'The sample rate must be positive' unless fs > 0

          n = out.length
          rs = Drift.signal_values(rate, n)
          seed = [rng[0].to_i]
          lo = lo.to_f
          span = hi.to_f - lo

          n.times do |i|
            p = Drift.increment(rs.is_a?(Array) ? rs[i] : rs, fs)
            u = Tone.noise_random(seed)
            out[i] = u < p ? lo + span * (u / p) : 0.0
          end

          rng[0] = seed[0]
          out
        end
      end
    end
  end
end
