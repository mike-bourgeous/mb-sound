module MB
  module Sound
    module Plan
      # The DSL a node's #plan_describe uses to describe its per-sample work
      # (the +p+ in the examples): look up inputs with #[] and combine the
      # resulting Values with Ruby operators, or with the node ops
      # (#tone, #param).  The node returns the Value of its output.
      #
      #     # GraphNode::Multiplier
      #     def plan_describe(p)
      #       @multiplicands.keys.reduce(p.const(@constant, complex: complex_buffer?)) { |product, m| product * p[m] }
      #     end
      #
      #     # GraphNode::Mixer
      #     def plan_describe(p)
      #       @gains.reduce(p.const(@constant, complex: ...)) { |sum, (m, gain)|
      #         sum + (gain == 1 ? p[m] : p[m] * gain)
      #       }
      #     end
      #
      #     # GraphNode::ComplexNode (:real and :imag)
      #     def plan_describe(p) = @mode == :real ? p[@input].real : p[@input].imag
      #
      # p[handle] describes the node behind +handle+ (a Tee branch) inside
      # the same plan when the region owns it, and otherwise reads it as a
      # boundary input; a number gives a Const.  Each node is described once
      # per plan, so fan-out costs nothing.
      class Builder
        # The ops emitted so far, in order.
        attr_reader :ops

        # The boundary inputs (Op::Input) and Constant params (Op::Param).
        attr_reader :inputs, :params

        # The node being described (innermost first).
        attr_reader :node_stack

        # +resolver+ is called with (builder, handle, consumer) for each
        # input handle and returns a Value (see Region#compile); nil makes a
        # standalone builder for specs, where #[] only takes Values, Consts,
        # and numbers.
        def initialize(resolver = nil)
          @resolver = resolver
          @ops = []
          @inputs = []
          @params = []
          @node_stack = []
          @next_id = 0
        end

        # The node whose #plan_describe is running.
        def node
          @node_stack.last
        end

        # Runs +node+'s #plan_describe with this builder, returning its
        # output Value.
        def describe(node)
          @node_stack.push(node)
          v = node.plan_describe(self)
          v = const(v) if v.is_a?(Numeric)
          v = fill(v) if v.is_a?(Const)
          raise Unsupported.new(node, "#plan_describe returned #{v.inspect} instead of a Plan::Value") unless v.is_a?(Value)

          v
        ensure
          @node_stack.pop
        end

        # The Value (or Const) for +input+: a node handle (a Tee branch,
        # resolved by the region: described inside the plan or read as a
        # boundary input), a number (a Const), or a Value/Const (returned
        # as is).
        def [](input)
          case input
          when Value, Const
            input
          when Numeric
            const(input)
          else
            raise ArgumentError, "No plan resolver for #{input.inspect}" unless @resolver
            @resolver.call(self, input, node, false)
          end
        end

        # Like #[], but always reads +handle+ as a boundary input, never
        # described inside the plan.  +optional: true+ for inputs that may
        # end without ending the node (the Value is then missing for the
        # rest of the block and the plan; see Region).
        def boundary(handle, optional: false)
          raise ArgumentError, "No plan resolver for #{handle.inspect}" unless @resolver

          @resolver.call(self, handle, node, true, optional)
        end

        # A Const for +value+ (forced complex with +complex: true+, as a
        # node whose buffer has been promoted to complex computes).
        def const(value, complex: false)
          Const.new(self, value, complex: complex)
        end

        # A new Value of +type+ (:real or :complex) computed by the op the
        # caller emits next (see #emit).
        def value(type)
          @next_id += 1
          Value.new(self, type, @next_id)
        end

        # Appends +op+ (whose dst is a new Value), returning its dst.
        def emit(op)
          op.dst.op = op
          @ops << op
          op.dst
        end

        # A boundary input op (for Region and specs): +handles+ are read
        # every block (the first gives the data).
        def input(type, source:, handles:, reason:, optional: false)
          op = Op::Input.new(value(type), node, source: source, handles: handles, reason: reason, index: @inputs.length, optional: optional)
          @inputs << op
          emit(op)
        end

        # A Constant node's value, read live every block (see Op::Param).
        def param(constant, complex: constant.constant.is_a?(Complex))
          op = Op::Param.new(value(complex ? :complex : :real), node, constant: constant, index: @params.length)
          @params << op
          emit(op)
        end

        # A Const filled into a register.
        def fill(c)
          c = const(c) unless c.is_a?(Const)
          emit(Op::Fill.new(value(c.type), node, c))
        end

        # a * b (see Op::Mul).
        def mul(a, b)
          binary(Op::Mul, a, b)
        end

        # a + b (see Op::Add).
        def add(a, b)
          binary(Op::Add, a, b)
        end

        # a / b (see Op::Div); real only.
        def div(a, b)
          a, b = operands(a, b)
          raise Unsupported.new(node, 'complex division') if a.complex? || b.complex?
          raise Unsupported.new(node, 'a constant numerator') if a.is_a?(Const)

          emit(Op::Div.new(value(:real), node, a, b))
        end

        # a ** b (see Op::Pow); real Values only.
        def pow(a, b)
          a, b = operands(a, b)
          raise Unsupported.new(node, 'complex power') if a.complex? || b.complex?
          raise Unsupported.new(node, 'a constant exponent') unless b.is_a?(Value)
          raise Unsupported.new(node, 'a constant base') unless a.is_a?(Value)

          emit(Op::Pow.new(value(:real), node, a, b))
        end

        # A copy of +a+ in a new register.
        def copy(a)
          emit(Op::Copy.new(value(a.type), node, a))
        end

        # The real or imaginary part of a complex Value.
        def part(a, which)
          emit(Op::Part.new(value(:real), node, a, which))
        end

        # An oscillator (see Op::Tone): +tone+ (a Tone) with its inputs as
        # Values or Consts (+reset+ and +target+ boundary inputs or nil).
        def tone(tone, frequency:, phase_mod:, width: nil, reset: nil, target: nil, gain: nil)
          complex = Tone::BUFFER_CLASS[tone.wave_type] == Numo::SComplex
          emit(Op::Tone.new(
            value(complex ? :complex : :real), node, tone,
            frequency: self[frequency], phase_mod: self[phase_mod], width: width && self[width],
            reset: reset, target: target, gain: gain && self[gain]
          ))
        end

        private

        def operands(a, b)
          a = self[a] unless a.is_a?(Value) || a.is_a?(Const)
          b = self[b] unless b.is_a?(Value) || b.is_a?(Const)
          [a, b]
        end

        def binary(klass, a, b)
          a, b = operands(a, b)
          type = a.complex? || b.complex? ? :complex : :real
          emit(klass.new(value(type), node, a, b))
        end
      end
    end
  end
end
