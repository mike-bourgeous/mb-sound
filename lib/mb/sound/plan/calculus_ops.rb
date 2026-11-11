module MB
  module Sound
    module Plan
      module Op
        # A GraphNode::Derivative (the slope of a signal): mb_calculus.h's
        # mb_derivative (fast_plan's OP_DERIVATIVE) on the node's own state
        # and settings, bit for bit the node's samples and state.  The
        # mirror is Derivative.process_ruby.
        class Derivative < Base
          attr_reader :a, :derivative

          def initialize(dst, node, derivative, a)
            super(dst, node)
            raise Unsupported.new(node, 'a complex derivative input') if a.complex?
            raise Unsupported.new(node, 'a constant derivative input') unless a.is_a?(Value)

            @derivative = derivative
            @a = a
          end

          def operands
            [@a]
          end

          def expression
            "derivative(#{@a}) [#{@derivative}]"
          end

          def opcode = :derivative

          def run_ruby(env, count)
            x = env.fetch(@a)
            x = x[0...count] if x.length > count
            d = @derivative
            env[@dst] = GraphNode::Derivative.process_ruby(x, Numo::SFloat.zeros(count),
              d.instance_variable_get(:@state), d.instance_variable_get(:@settings))
          end
        end

        # A GraphNode::Integral (the running sum of a signal): mb_calculus.h's
        # mb_integral (fast_plan's OP_INTEGRAL) on the node's own state and
        # settings, reading its input and its reset triggers (nil for none),
        # bit for bit the node's samples and state.  The mirror is
        # Integral.process_ruby.
        class Integral < Base
          attr_reader :a, :reset, :integral

          def initialize(dst, node, integral, a, reset)
            super(dst, node)
            raise Unsupported.new(node, 'a complex integral input or reset') if a.complex? || reset&.complex?
            raise Unsupported.new(node, 'a constant integral input') unless a.is_a?(Value)
            raise Unsupported.new(node, 'a constant integral reset') if reset && !reset.is_a?(Value)

            @integral = integral
            @a = a
            @reset = reset
          end

          def operands
            [@a, @reset].compact
          end

          def expression
            "integral(#{@a}#{", reset: #{@reset}" if @reset}) [#{@integral}]"
          end

          def opcode = :integral

          def run_ruby(env, count)
            x = env.fetch(@a)
            x = x[0...count] if x.length > count
            r = @reset && env.fetch(@reset)
            r = r[0...count] if r && r.length > count
            i = @integral
            env[@dst] = GraphNode::Integral.process_ruby(x, Numo::SFloat.zeros(count), r,
              i.instance_variable_get(:@state), i.instance_variable_get(:@settings))
          end
        end
      end

      class Builder
        # +derivative+ (a GraphNode::Derivative) of +a+; see Op::Derivative.
        def derivative(derivative, a)
          emit(Op::Derivative.new(value(:real), node, derivative, self[a]))
        end

        # +integral+ (a GraphNode::Integral) of +a+, restarting at rising
        # edges of +reset+ (nil for none); see Op::Integral.
        def integral(integral, a, reset)
          emit(Op::Integral.new(value(:real), node, integral, self[a], reset && self[reset]))
        end
      end
    end
  end
end
