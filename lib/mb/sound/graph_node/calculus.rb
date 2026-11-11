module MB
  module Sound
    module GraphNode
      # Settings shared by Derivative and Integral: the time unit (per second
      # or per sample) and the sample rate change that rescales it.
      module CalculusUnits
        # The time units a slope or sum is counted in.
        UNITS = %i[second sample].freeze

        # The time unit (:second or :sample).
        attr_reader :unit

        # Changes the sample rate (the slope or sum stays per second).
        def sample_rate=(rate)
          super
          update_settings
          self
        end

        private

        def check_unit(per)
          return per if UNITS.include?(per)

          raise ArgumentError, "per: is :second (slopes and sums per second, the default) or :sample (got #{per.inspect})"
        end

        def real_input(data, what)
          return data if data.is_a?(Numo::SFloat) && data.contiguous?
          raise ArgumentError, "#{what} takes real signals (take .real, .imag, or .abs first)" if data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex)

          Numo::SFloat.cast(data)
        end
      end

      # The slope of a signal (GraphNode#derivative, aliases #slope and
      # #differentiate): how fast it changes, per second by default (a ramp
      # rising 1 per second gives 1; a full-scale sine at f Hz peaks at
      # 2 pi f), or per sample with `per: :sample` (the plain difference of
      # neighbouring samples, a 6 dB per octave tilt rising to 2 at the
      # Nyquist frequency).
      #
      # The default backward difference (x[n] - x[n - 1]) is causal: the
      # slope between the last two samples, half a sample late.  `mode:
      # :central` gives (x[n] - x[n - 2]) / 2, the slope at the sample before,
      # one sample late, with no response at the Nyquist frequency (smoother
      # on noisy input).  The first sample's slope is 0 (the samples before
      # the input read as its first sample, so a signal starting away from
      # zero gives no jump).
      #
      # The previous inputs carry across buffers in double precision, so
      # the output is the same at any buffer size.  Kernel
      # FastControl.derivative, mirror .process_ruby; planned as
      # Plan::Op::Derivative.
      #
      #     play 110.hz.saw.at(0.3) * (1 + 0.5.hz.lfo.derivative.aclip(0, 4) * 0.2)  # louder while the LFO rises
      #     play noise.derivative(per: :sample).at(0.2)                                 # brighter noise (6 dB/octave)
      class Derivative
        include GraphNode
        include SampleRateHelper
        include CalculusUnits
        # (the previous samples move to a rebuilt node through the plan
        # snapshot: no jump at a swap)
        node_traits memory: :short, carry: :snapshot

        # The difference kinds.
        MODES = %i[backward central].freeze

        # The difference (:backward or :central).
        attr_reader :difference

        # The slope of +source+ (see the class description): +mode+
        # :backward or :central, +per+ :second or :sample.
        def initialize(source, mode: :backward, per: :second)
          raise ArgumentError, "derivative takes a graph node (got #{source.inspect})" unless source.respond_to?(:sample)
          raise ArgumentError, "derivative modes are :backward (the default) and :central (got #{mode.inspect})" unless MODES.include?(mode)

          @source = source.get_sampler
          @sample_rate = source.sample_rate.to_f
          @difference = mode
          @unit = check_unit(per)
          @state = Numo::DFloat.zeros(Derivative::STATE_LENGTH)
          @settings = Numo::DFloat.zeros(2)
          @out = nil
          @node_type_name = 'derivative'
          update_settings
        end

        # Values in the state (see mb_calculus.h).
        STATE_LENGTH = 3

        def sources
          { input: @source }
        end

        def sample(count)
          data = @source.sample(count)
          return nil if data.nil? || data.empty?

          data = real_input(data, 'derivative')
          n = data.length
          @out = Numo::SFloat.zeros(n) if @out.nil? || @out.length != n
          Kernels.derivative(data, @out, @state, @settings)
        end

        def to_s
          "#{super} -- derivative#{' (central)' if @difference == :central} per #{@unit}"
        end

        # Plan layer (see MB::Sound::Plan and Plan::Op::Derivative): the
        # difference in C on this node's state and settings.
        include Plan::Describable

        def plan_describe(p)
          p.derivative(self, p[@source])
        end

        def plan_inputs
          [@source]
        end

        def plan_snapshot
          @state.to_a
        end

        def plan_restore(snapshot)
          @state[0..] = snapshot
        end

        # The exact Ruby mirror of MB::Sound::FastControl.derivative (same
        # arguments, the same double operations; see mb_calculus.h).
        def self.process_ruby(x, out, state, settings)
          n = x.length
          raise ArgumentError, 'The output must have as many values as the input' if out.length != n
          raise ArgumentError, 'The state must have 3 values' if state.length != STATE_LENGTH

          central = settings[0] != 0
          scale = settings[1]
          x1, x2, primed = state.to_a
          primed = primed != 0
          ys = x.to_a.map { |xn|
            unless primed
              x1 = xn
              x2 = xn
              primed = true
            end
            back = central ? x2 : x1
            v = (xn - back) * scale
            x2 = x1
            x1 = xn
            v
          }
          state[0] = x1
          state[1] = x2
          state[2] = primed ? 1.0 : 0.0
          out[0..] = Numo::SFloat.cast(ys) if n > 0
          out
        end

        private

        def update_settings
          scale = @unit == :second ? @sample_rate : 1.0
          scale *= 0.5 if @difference == :central
          @settings[0] = @difference == :central ? 1.0 : 0.0
          @settings[1] = scale
        end
      end

      # The running sum of a signal (GraphNode#integral, aliases #integrate
      # and #accumulate): its area so far, per second by default (a constant
      # 1 climbs 1 per second, so a frequency in Hz integrates to a phase in
      # cycles), or per sample with `per: :sample` (the plain sum of the
      # samples).
      #
      # Without +leak+ the sum is true accumulation: it holds forever once
      # the input stops, and a signal with DC climbs without end (for control
      # signals: a drifting pitch, a position from a speed).  +leak+ (a time
      # constant: seconds or a Length) lets the sum fall back toward zero by
      # 63% over that time, a one-pole lowpass whose gain is +leak+ seconds at
      # DC, so audio with DC stays bounded.  +reset+ (a node of triggers)
      # restarts the sum at zero on each rising edge (a sample > 0 after one
      # <= 0, like SampleHold), and +range+ clamps it (and the state, so it
      # never winds up), e.g. `0..1` for a ramp that stops at the top.
      #
      # Each step is y = y * leak + x * dt (rectangle rule), so with no leak
      # `x.derivative.integral` gives x back, less its first sample.  The sum
      # runs in double precision and carries across buffers, so the output is
      # the same at any buffer size.  Ends when the input or reset ends.
      # Kernel FastControl.integral, mirror .process_ruby; planned as
      # Plan::Op::Integral.
      #
      #     play 220.hz.sine.fm(0.3.hz.lfo.integral(leak: 2) * 300)            # wandering vibrato
      #     play (100 + 0.2.hz.lfo.at(-50..50).integral * 20).hz.saw.at(0.3)   # drifting pitch, true sum
      #     play 110.hz.saw.lp4(200 + 1.constant.integral(reset: 2.hz.lfo.square, range: 0..1) * 3000)  # repeating sweep
      class Integral
        include GraphNode
        include SampleRateHelper
        include CalculusUnits
        # (the sum moves to a rebuilt node through the plan snapshot: a drift
        # continues across a swap)
        node_traits memory: :short, carry: :snapshot

        # The leak time constant as given (seconds or a Length), or nil.
        attr_reader :leak

        # The clamping range, or nil.
        attr_reader :range

        # The reset trigger (a sampler branch), or nil.
        attr_reader :reset

        # The running sum of +source+ (see the class description).
        def initialize(source, leak: nil, reset: nil, range: nil, per: :second)
          raise ArgumentError, "integral takes a graph node (got #{source.inspect})" unless source.respond_to?(:sample)
          raise ArgumentError, "Integral reset must be a graph node of triggers (got #{reset.inspect})" unless reset.nil? || reset.respond_to?(:sample)

          # (a document's param is its number while the graph builds: GraphIO::NumberOnly's sweep)
          leak = GraphNode.build_setting(leak)
          leak = nil if leak == false
          unless leak.nil?
            raise ArgumentError, "The leak is a fixed time constant: seconds or a Length (got #{leak.inspect})" if leak.respond_to?(:sample) || !(leak.is_a?(Numeric) || leak.is_a?(Length))

            Length.check_time(leak, 'An integral leak')
            raise ArgumentError, "The leak time constant must be longer than zero (got #{leak.inspect}; nil or false for none)" unless Length.seconds(leak) > 0
          end
          unless range.nil?
            ok = range.is_a?(Range) && [range.begin, range.end].all? { |v| v.nil? || (v.is_a?(Numeric) && v.real?) } &&
              (range.begin.nil? || range.end.nil? || range.begin <= range.end)
            raise ArgumentError, "The integral range is a Range of numbers, low to high, e.g. 0..1 or 0.. (got #{range.inspect})" unless ok
          end

          @source = source.get_sampler
          @reset = reset&.get_sampler
          @sample_rate = source.sample_rate.to_f
          @leak = leak
          @range = range
          @unit = check_unit(per)
          @state = Numo::DFloat.zeros(2)
          @settings = Numo::DFloat.zeros(5)
          @out = nil
          @node_type_name = 'integral'
          update_settings
        end

        def sources
          @reset ? { input: @source, reset: @reset } : { input: @source }
        end

        def sample(count)
          data = @source.sample(count)
          return nil if data.nil? || data.empty?

          data = real_input(data, 'integral')
          trig = nil
          if @reset
            trig = @reset.sample(data.length)
            return nil if trig.nil? || trig.empty?

            trig = real_input(trig, 'An integral reset')
            data = data[0...trig.length].dup if trig.length < data.length
          end
          n = data.length
          @out = Numo::SFloat.zeros(n) if @out.nil? || @out.length != n
          Kernels.integral(data, @out, trig, @state, @settings)
        end

        def to_s
          extra = [("leak #{MB::Sound::RubyValue.to_ruby(@leak)}" if @leak), ("range #{@range}" if @range), ('reset' if @reset)].compact
          "#{super} -- integral per #{@unit}#{extra.empty? ? '' : " (#{extra.join(', ')})"}"
        end

        # Plan layer (see MB::Sound::Plan and Plan::Op::Integral): the sum
        # in C on this node's state and settings.
        include Plan::Describable

        def plan_describe(p)
          p.integral(self, p[@source], @reset && p[@reset])
        end

        def plan_inputs
          [@source, @reset].compact
        end

        def plan_snapshot
          @state.to_a
        end

        def plan_restore(snapshot)
          @state[0..] = snapshot
        end

        # The exact Ruby mirror of MB::Sound::FastControl.integral (same
        # arguments, the same double operations; see mb_calculus.h).
        def self.process_ruby(x, out, reset, state, settings)
          n = x.length
          raise ArgumentError, 'The output must have as many values as the input' if out.length != n
          raise ArgumentError, 'The reset must have as many values as the input' if reset && reset.length != n

          scale, leak, clamp, lo, hi = settings.to_a
          clamp = clamp != 0
          leaking = leak != 1.0
          y, prev = state.to_a
          rs = reset&.to_a
          xs = x.to_a
          ys = Array.new(n)
          n.times do |i|
            if rs
              t = rs[i]
              y = 0.0 if t > 0 && !(prev > 0)
              prev = t
            end
            scaled = xs[i] * scale
            y *= leak
            y += scaled
            if clamp
              if y < lo
                y = lo
              elsif y > hi
                y = hi
              end
            end
            y = 0.0 if leaking && y.abs < FLUSH
            ys[i] = y
          end
          state[0] = y
          state[1] = prev
          out[0..] = Numo::SFloat.cast(ys) if n > 0
          out
        end

        # A leaking sum smaller than this is flushed to zero (see
        # mb_calculus.h).
        FLUSH = 1e-30

        private

        def update_settings
          @settings[0] = @unit == :second ? 1.0 / @sample_rate : 1.0
          @settings[1] = @leak ? Math.exp(-1.0 / Length.samples(@leak, sample_rate: @sample_rate).to_f) : 1.0
          @settings[2] = @range ? 1.0 : 0.0
          @settings[3] = @range&.begin ? @range.begin.to_f : -Float::INFINITY
          @settings[4] = @range&.end ? @range.end.to_f : Float::INFINITY
        end
      end

      Kernels.register :derivative, c: FastControl.method(:derivative), ruby: Derivative.method(:process_ruby),
        about: 'the slope of a signal (GraphNode::Derivative)'
      Kernels.register :integral, c: FastControl.method(:integral), ruby: Integral.method(:process_ruby),
        about: 'the running sum of a signal (GraphNode::Integral)'
    end
  end
end
