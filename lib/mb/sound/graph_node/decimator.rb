module MB
  module Sound
    module GraphNode
      # A sample-rate reducer ("decimator", "rate crusher"): holds one input
      # sample every 1 / +rate+ seconds, with no lowpass before or after, so
      # everything above half the hold rate folds back down on purpose (the
      # lo-fi sampler and "Redux" sound).  Bit depth is #quantize's job
      # (`sig.decimate(6000).aquantize(4.bits)` for both).
      #
      # The hold clock is a phase accumulator, so the rate needn't divide the
      # sample rate and may move every sample: a node of Hz (an LFO sweep, an
      # envelope, or a note's frequency for key tracking).  With the rate a
      # whole multiple of a note's frequency the folded partials land on the
      # note's harmonics (a harmonic, comb-like timbre); in between they
      # don't (inharmonic, "yoyo" vocal peaks moving as the rate moves).
      #
      # +jitter+ (0..0.95, default 0) varies each hold period by up to that
      # fraction at random (seeded: +seed+ or a sub-seed drawn from
      # MB::Sound's generator when jitter is on), for a looser, dirtier
      # clock.
      #
      # +interpolation+ :hold (default) is the zero-order hold, the stepped
      # sampler sound; :linear (a first-order hold) draws straight lines
      # between the held samples instead, one hold period late: the same
      # folding (grunge) with its high images falling much faster (sinc^2
      # instead of sinc), so less of the metallic ringing far above the
      # rate (textures-3, 2026-10-15; the maintainer: "linear interpolation
      # decimation to get some grunge with less ringing").
      #
      # +mix+ is the crushed share of the output (default 1, all crushed; 0
      # the input unchanged), a number or a node read every sample:
      # crushed * mix + input * (1 - mix).  TODO: consolidate with the
      # universal wet/dry mix for nodes and subgraphs once it exists
      # (maintainer, 2026-10-12: "Yes, with a note to consolidate whenever
      # we do universal wet/dry mix for nodes and subgraphs").
      #
      # The kernel is MB::Sound::FastLofi.decimate (exact Ruby mirror
      # .process_ruby); the output is the same at any buffer size.  Ends
      # when the input or the rate node ends.
      #
      # Examples (bin/sound.rb):
      #     play 110.hz.saw.lp4(1200, resonance: 0.7).decimate(3000)
      #     play 110.hz.saw.decimate(0.3.hz.lfo.at(800..8000))               # a swept crush
      #     midi.synth { |v| v.hz.saw.decimate(v.freq * 5.5).at(v.amp_env) }  # key-tracked
      class Decimator
        include GraphNode
        include SampleRateHelper
        # (a jittered decimator draws per held step: #node_traits)
        node_traits memory: :short, random: false

        # The largest jitter (each period may shrink or grow by this
        # fraction).
        MAX_JITTER = 0.95

        # Interpolation names and the kernel's mode numbers.
        INTERPOLATION = { hold: 0, linear: 1 }.freeze

        # Other names for INTERPOLATION entries.
        INTERPOLATION_ALIASES = { zoh: :hold, step: :hold, none: :hold, foh: :linear, lerp: :linear }.freeze

        # Phases this close below a whole cycle count as reaching it (as in
        # the kernel), so rates dividing the sample rate hold every N samples.
        EDGE = 1e-9

        # The input node (a sampler branch).
        attr_reader :input

        # The hold rate in Hz: a Float or a node (a sampler branch).
        attr_reader :rate

        # The hold period's random variation (0..0.95).
        attr_reader :jitter

        # The jitter's random seed (nil without jitter).
        attr_reader :seed

        # The crushed share of the output: a Float or a node (a sampler
        # branch).
        attr_reader :mix

        # Between held samples: :hold or :linear.
        attr_reader :interpolation

        # Creates a decimator on +input+ holding +rate+ samples per second (a
        # number, a node of Hz, or a Pitch for its frequency); see the class
        # description for +jitter+, +seed+, and +mix+.
        def initialize(input, rate:, jitter: 0, seed: nil, mix: 1, interpolation: :hold, sample_rate: nil)
          raise ArgumentError, "Decimator input must be a graph node (got #{input.inspect})" unless input.respond_to?(:sample)

          rate = rate.oscillator_frequency if rate.is_a?(MB::Sound::Pitch)
          unless rate.is_a?(Numeric) || rate.respond_to?(:sample)
            raise ArgumentError, "Decimator rate must be a number of Hz, a node, or a Pitch (got #{rate.inspect})"
          end
          raise ArgumentError, "Decimator rate must be a real number (got #{rate})" if rate.is_a?(Complex)
          unless jitter.is_a?(Numeric) && jitter >= 0 && jitter <= MAX_JITTER
            raise ArgumentError, "Decimator jitter must be a number from 0 to #{MAX_JITTER} (got #{jitter.inspect})"
          end

          unless (mix.is_a?(Numeric) && mix.real? && mix.finite?) || mix.respond_to?(:sample)
            raise ArgumentError, "Decimator mix must be a real number or a node (got #{mix.inspect})"
          end

          interp = INTERPOLATION_ALIASES.fetch(interpolation, interpolation)
          unless INTERPOLATION.include?(interp)
            raise ArgumentError, "Decimator interpolation must be one of #{(INTERPOLATION.keys + INTERPOLATION_ALIASES.keys).map(&:inspect).join(', ')} (got #{interpolation.inspect})"
          end
          @interpolation = interp
          @mode = INTERPOLATION[interp]

          @input = input.get_sampler
          @mix = mix.is_a?(Numeric) ? mix.to_f : mix.get_sampler
          @rate = rate.is_a?(Numeric) ? rate.to_f : rate.get_sampler
          @jitter = jitter.to_f
          @seed = @jitter > 0 ? (seed.nil? ? MB::Sound.next_seed : Integer(seed)) : nil
          @sample_rate = (sample_rate || input.sample_rate).to_f
          @buf = nil
          @node_type_name = 'Decimator'
          reset
        end

        # Restarts the hold clock (the next sample is held) and the jitter's
        # random sequence.
        def reset
          @state = Numo::DFloat[1.0, 0.0, 1.0, 0.0]
          @rng = Numo::UInt64[(@seed || 0) & Tone::MASK64]
          self
        end

        def sample(count)
          x = @input.sample(count)
          return nil if x.nil? || x.empty?

          r = @rate
          if r.respond_to?(:sample)
            r = r.sample(x.length)
            return nil if r.nil? || r.empty?
            x = x[0...r.length] if r.length < x.length
          end

          m = @mix
          if m.respond_to?(:sample)
            m = m.sample(x.length)
            return nil if m.nil? || m.empty?
            if m.length < x.length
              x = x[0...m.length]
              r = r[0...m.length] if r.respond_to?(:length)
            end
          end

          n = x.length
          @buf = Numo::SFloat.zeros(n) if @buf.nil? || @buf.length != n
          out = Kernels.decimate(@buf, x, r, @state, @rng, @sample_rate, @jitter, @mode)
          m == 1.0 ? out : self.class.mix(out, x, m)
        end

        # Blends crushed +out+ (modified in place) with the +input+ by
        # +mix+ (a number or an array): out * mix + input * (1 - mix), in
        # float32 like the rest of the node.
        def self.mix(out, input, mix)
          m = mix.is_a?(Numeric) ? mix.to_f : Numo::SFloat.cast(mix)
          dry = Numo::SFloat.cast(input.is_a?(Numo::SComplex) || input.is_a?(Numo::DComplex) ? input.real : input)
          out.inplace * m
          out.inplace + dry * (1.0 - m)
          out
        end

        def sources
          s = @rate.is_a?(Numeric) ? { input: @input } : { input: @input, rate: @rate }
          s[:mix] = @mix unless @mix.is_a?(Numeric)
          s
        end

        def to_s
          r = @rate.is_a?(Numeric) ? "#{MB::M.sigfigs(@rate, 4)} Hz" : 'node Hz'
          j = @jitter > 0 ? ", jitter #{MB::M.sigfigs(@jitter, 3)}" : ''
          j += ', linear' if @mode == 1
          j += @mix.is_a?(Numeric) ? (@mix == 1 ? '' : ", mix #{MB::M.sigfigs(@mix, 3)}") : ', mix node'
          "Decimator #{r}#{j}"
        end

        # NodeTraits for this decimator: with +jitter:+ it draws a random
        # period at each held step, whose times and held values follow its
        # input and rate, which a sleeping voice can't know without
        # rendering, so it keeps sleepers awake (+random: :blocks+;
        # delay-sleep-1).  Without jitter it draws nothing.
        def node_traits
          @jitter > 0 ? NodeTraits.variant(self.class, random: :blocks) : self.class.node_traits
        end

        # Plan layer (see MB::Sound::Plan and Plan::Op::Decimate): the hold
        # and the blend in C on this node's state, so a decimator inside a
        # voice no longer splits it into two regions (plan-fusion-2).
        include Plan::Describable

        def plan_describe(p)
          mix = @mix.is_a?(Numeric) ? (@mix == 1.0 ? nil : @mix) : @mix
          p.decimate(self, p[@input], @rate, mix)
        end

        def plan_snapshot
          [@state.to_a, @rng[0]]
        end

        def plan_restore(snapshot)
          @state[0..] = snapshot[0]
          @rng[0] = snapshot[1]
        end

        # The exact Ruby mirror of MB::Sound::FastLofi.decimate (same
        # arguments and state; see ext/mb/sound/fast_lofi/fast_lofi.c): the
        # same double operations in the same order, inputs read as float32
        # values, so specs compare the two for equality.
        def self.process_ruby(out, input, rate, state, rng, sample_rate, jitter, mode = 0)
          fs = sample_rate.to_f
          raise ArgumentError, 'The sample rate must be positive' unless fs > 0
          raise ArgumentError, 'The jitter must be from 0 to 0.95' unless jitter >= 0 && jitter <= MAX_JITTER
          raise ArgumentError, 'The mode must be 0 (hold) or 1 (linear)' unless mode == 0 || mode == 1

          n = out.length
          xs = signal_values(input, n)
          rs = signal_values(rate, n)
          seed = [rng[0].to_i]

          phase = state[0]
          held = Numo::SFloat[state[1]][0]
          factor = state[2]
          prev = Numo::SFloat[state[3]][0]

          n.times do |i|
            if phase >= 1.0 - EDGE
              phase -= (phase + EDGE).floor
              prev = held
              held = xs.is_a?(Array) ? xs[i] : Numo::SFloat[xs][0]
              if jitter > 0
                u = Tone.noise_random(seed)
                spread = jitter * (2.0 * u - 1.0)
                factor = 1.0 + spread
              end
            end
            if mode == 1
              t = phase < 1.0 ? phase : 1.0
              out[i] = prev + (held - prev) * t
            else
              out[i] = held
            end

            inc = (rs.is_a?(Array) ? rs[i] : rs) / fs
            if !(inc > 0)
              inc = 0.0
            elsif inc > 1.0
              inc = 1.0
            end
            phase += inc * factor
          end

          state[0] = phase
          state[1] = held
          state[2] = factor
          state[3] = prev
          rng[0] = seed[0]
          out
        end

        # A signal input as the kernel reads it: a Float, or an Array of
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
        private_class_method :signal_values
      end

      Kernels.register :decimate, c: FastLofi.method(:decimate), ruby: Decimator.method(:process_ruby)
    end
  end
end
