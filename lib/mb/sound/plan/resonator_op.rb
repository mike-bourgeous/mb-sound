module MB
  module Sound
    module Plan
      module Op
        # A GraphNode::Resonator (#ping) or GraphNode::ModalResonator
        # (#resonate): FastResonator.ping's or .modes' kernel through
        # mb_resonator.h (fast_plan's OP_RESONATOR, plan_resonator.c) on the
        # node's own state, reading its input, its frequency in Hz (a Const
        # for a numeric frequency, else a Value), and its decay in samples
        # to -60 dB (a Const for a fixed length, else a Value already scaled
        # to samples).  Bit for bit the node's samples and state.  The
        # mirror is Resonator.process_ruby / ModalResonator.process_ruby.
        class Resonator < Base
          attr_reader :a, :freq, :decay, :resonator

          def initialize(dst, node, resonator, a, freq, decay)
            super(dst, node)
            raise Unsupported.new(node, 'a complex resonator input') if a.complex?
            raise Unsupported.new(node, 'a complex resonator frequency or decay') if freq.complex? || decay.complex?
            raise ArgumentError, 'A resonator input must be a Value' unless a.is_a?(Value)

            @resonator = resonator
            @a = a
            @freq = freq
            @decay = decay
          end

          # True for a ModalResonator (a bank of modes).
          def modal?
            @resonator.is_a?(GraphNode::ModalResonator)
          end

          def operands
            [@a, @freq, @decay].grep(Value)
          end

          def expression
            "#{modal? ? 'modes' : 'ping'}(#{@a}, freq: #{@freq}, decay: #{@decay}) [#{@resonator}]"
          end

          def opcode = :resonator

          def run_ruby(env, count)
            at = ->(v) {
              next v.value.to_f if v.is_a?(Const)
              buf = env.fetch(v)
              buf.length > count ? buf[0...count] : buf
            }
            r = @resonator
            out = Numo::SFloat.zeros(count)
            state = r.instance_variable_get(:@state)
            rate = r.instance_variable_get(:@sample_rate)
            if modal?
              GraphNode::ModalResonator.process_ruby(out, at.(@a), at.(@freq), at.(@decay), r.instance_variable_get(:@table), state, rate)
            else
              GraphNode::Resonator.process_ruby(out, at.(@a), at.(@freq), at.(@decay), state, rate,
                r.instance_variable_get(:@cos_phase), r.instance_variable_get(:@sin_phase))
            end
            env[@dst] = out
          end
        end
      end

      class Builder
        # +resonator+ (a GraphNode::Resonator or ModalResonator) pinged by
        # +a+ at +freq+ Hz with +decay+ samples to -60 dB (Values, Consts, or
        # numbers; see Op::Resonator).
        def resonator(resonator, a, freq, decay)
          emit(Op::Resonator.new(value(:real), node, resonator, self[a], self[freq], self[decay]))
        end
      end
    end
  end
end
