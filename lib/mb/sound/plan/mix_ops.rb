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
    end
  end
end
