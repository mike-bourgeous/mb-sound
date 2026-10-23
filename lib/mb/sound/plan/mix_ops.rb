module MB
  module Sound
    module Plan
      module Op
        # A weighted sum of real Values, as MB::FastSound.matrix_mix computes
        # one output row of a GraphNode::ChannelMixer with real number gains:
        # starting from 0, each term adds weight * term in float32 (the
        # weight cast to float), in order; a weight of exactly 0 skips its
        # term, 1 adds the term, and -1 subtracts it.  The weights are
        # scalars, so regions differing only in gains (a Synth's unison
        # lanes, with their own random detunes and pan slots) have the same
        # shape (see LaneGroup).
        class Mix < Base
          # The Values summed.
          attr_reader :terms

          # The weights (Floats), one per term.
          attr_reader :weights

          def initialize(dst, node, terms, weights)
            super(dst, node)
            raise ArgumentError, 'A mix needs one weight per term' unless terms.length == weights.length
            raise ArgumentError, 'A mix needs at least one term' if terms.empty?
            raise ArgumentError, 'Mix terms must be real Values' unless terms.all? { |t| t.is_a?(Value) && t.real? }
            raise ArgumentError, 'Mix weights must be real numbers' unless weights.all? { |w| w.is_a?(Numeric) && w.real? }

            @terms = terms.freeze
            @weights = weights.map(&:to_f).freeze
          end

          def operands = @terms

          def expression
            parts = @terms.each_with_index.map { |t, k| "#{MB::M.sigfigs(@weights[k], 4)} * #{t}" }
            "mix(#{parts.join(' + ')})"
          end

          def opcode = :mix

          # Numo: a zero buffer, then each term added in place (the weight
          # times the term as Numo multiplies an SFloat by a Float: in
          # float32, the weight cast first).
          def run_ruby(env, count)
            out = Numo::SFloat.zeros(count).inplace!
            @terms.each_with_index do |t, k|
              w = @weights[k]
              next if w == 0

              x = env.fetch(t)
              x = x[0...count] if x.length > count
              if w == 1
                out + x
              elsif w == -1
                out - x
              else
                out + x * w
              end
            end
            env[@dst] = out.not_inplace!
          end
        end

        # One side's gain of a pan law (GraphNode::ChannelMixer::PanLaws)
        # for a moving position, as FastArithmetic.pan and Numo compute it
        # on float32 buffers (fast_plan's OP_PAN_GAIN): the position
        # (optionally scaled first: (float)scale * position, a unison slot
        # times its spread) clipped to -1..1, then :equal_power cos or sin of
        # (p + 1) * (float)(pi / 4), :linear (1 - p) * 0.5 or (p + 1) * 0.5,
        # :minus_4_5db those to the (float)0.75 power, or :balance
        # (PanLaws.balance) cos or sin of the angle times (float)sqrt(2),
        # clipped to 0..1.  +side+ is 0 (left) or 1 (right).  Moving pans,
        # balances, and unison spreads multiply their inputs by these
        # (plan-fusion-2).  The mirror is PanLaws itself.
        class PanGain < Base
          # Law numbers (FastArithmetic.pan's, plus :balance).
          LAWS = { equal_power: 0, linear: 1, minus_4_5db: 2, balance: 3 }.freeze

          attr_reader :a, :law, :side, :scale

          def initialize(dst, node, a, law, side, scale: nil)
            super(dst, node)
            raise Unsupported.new(node, 'a complex pan position') if a.complex?
            raise Unsupported.new(node, 'a constant pan position') unless a.is_a?(Value)
            raise ArgumentError, "Unknown pan law #{law.inspect}" unless LAWS.include?(law)
            raise ArgumentError, 'The pan side must be 0 or 1' unless side == 0 || side == 1
            raise ArgumentError, 'The pan scale must be a real number' unless scale.nil? || (scale.is_a?(Numeric) && scale.real?)

            @a = a
            @law = law
            @side = side
            @scale = scale
          end

          def law_id = LAWS.fetch(@law)

          def operands = [@a]

          def expression
            pos = @scale ? "#{MB::M.sigfigs(@scale, 4)} * #{@a}" : @a.to_s
            "pan_#{@side == 0 ? 'left' : 'right'}_#{@law}(#{pos})"
          end

          def opcode = :pan_gain

          def run_ruby(env, count)
            pos = env.fetch(@a)
            pos = pos[0...count] if pos.length > count
            pos = @scale * pos if @scale
            laws = GraphNode::ChannelMixer::PanLaws
            gains = @law == :balance ? laws.balance(pos) : laws.gains(@law, pos)
            env[@dst] = Numo::SFloat.cast(gains[@side])
          end
        end

        # Output +index+ (1 and up) of a multi-output region (see
        # MultiDescribable): copies +a+ into a buffer the region hands out
        # with the program's own output (Region#sample_outputs).  Two buffers
        # alternate, one block each (#reserve), as GraphNode::ChannelMixer
        # alternates its own outputs, so a frame a Tee still shares stays
        # intact while the next one is computed.
        class Output < Tap
          # The output's index.
          attr_reader :index

          def initialize(dst, node, a, index)
            super(dst, node, a, node)
            @index = index
            @buffers = [nil, nil]
            @view_sets = [{}, {}]
            @which = 1
            @views = @view_sets[1]
          end

          def expression = "output #{@index} = #{@a}"

          # Switches to the other buffer, making it hold at least +n+
          # samples (called once per block before the program runs).
          def reserve(n)
            @which = 1 - @which
            buf = @buffers[@which]
            if buf.nil? || buf.length < n
              buf = @buffers[@which] = (@a.complex? ? Numo::SComplex : Numo::SFloat).zeros([n, 1].max)
              @view_sets[@which] = {}
            end
            @holder[0] = buf
            @views = @view_sets[@which]
          end

          # The output's last block of +n+ samples (a view reused while +n+
          # stays the same).
          def view(n)
            @views[n] ||= @holder[0][0...n]
          end

          # (No spies: the outputs are read through the region.)
          def deliver(n)
          end

          def run_ruby(env, count)
            reserve(count) if @holder[0].nil? || @holder[0].length < count
            buf = env.fetch(@a)
            @holder[0][0...count] = buf.length > count ? buf[0...count] : buf
            env[@dst] = nil
          end
        end
      end

      class Builder
        # One side's gain (+side+ 0 left, 1 right) of pan law +law+ for the
        # position +a+ (times +scale+ if given); see Op::PanGain.
        def pan_gain(a, law, side, scale: nil)
          emit(Op::PanGain.new(value(:real), node, self[a], law, side, scale: scale))
        end
      end
    end
  end
end
