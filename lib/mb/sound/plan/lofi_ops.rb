module MB
  module Sound
    module Plan
      module Op
        # A GraphNode::Decimator (sample-rate reduction): FastLofi.decimate's
        # kernel through mb_decimate.h (fast_plan's OP_DECIMATE,
        # plan_lofi.c) on the node's own state and random state, reading its
        # input, its hold rate (a Const for a numeric rate, else a Value in
        # Hz), and its mix (nil for a numeric mix of 1: no blend; a Const;
        # or a Value), then blending as GraphNode::Decimator.mix does.  Bit
        # for bit the node's samples and state.  The mirror is
        # Decimator.process_ruby and Decimator.mix.
        class Decimate < Base
          attr_reader :a, :rate, :mix, :decimator

          def initialize(dst, node, decimator, a, rate, mix)
            super(dst, node)
            raise Unsupported.new(node, 'a complex decimator input') if a.complex?
            raise Unsupported.new(node, 'a complex decimator rate or mix') if rate.complex? || mix&.complex?
            raise ArgumentError, 'A decimator input must be a Value' unless a.is_a?(Value)

            @decimator = decimator
            @a = a
            @rate = rate
            @mix = mix
          end

          def operands
            [@a, @rate, @mix].grep(Value)
          end

          def expression
            "decimate(#{@a}, rate: #{@rate}#{@mix ? ", mix: #{@mix}" : ''}) [#{@decimator}]"
          end

          def opcode = :decimate

          def run_ruby(env, count)
            at = ->(v) {
              next v.value.to_f if v.is_a?(Const)
              buf = env.fetch(v)
              buf.length > count ? buf[0...count] : buf
            }
            d = @decimator
            x = at.(@a)
            out = GraphNode::Decimator.process_ruby(Numo::SFloat.zeros(count), x, at.(@rate),
              d.instance_variable_get(:@state), d.instance_variable_get(:@rng),
              d.instance_variable_get(:@sample_rate), d.jitter, d.instance_variable_get(:@mode))
            out = GraphNode::Decimator.mix(out, x, at.(@mix)) if @mix
            env[@dst] = out
          end
        end
      end

      class Builder
        # +decimator+ (a GraphNode::Decimator) on +a+ at hold rate +rate+
        # (Hz) blended by +mix+ (nil: no blend); see Op::Decimate.
        def decimate(decimator, a, rate, mix)
          emit(Op::Decimate.new(value(:real), node, decimator, self[a], self[rate], mix && self[mix]))
        end
      end
    end
  end
end
