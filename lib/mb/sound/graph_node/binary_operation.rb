module MB
  module Sound
    module GraphNode
      # Divides its input by an operand (+operator+ '/') or raises it to the
      # operand's power ('**'); the operand is a number or a node.  Made by
      # GraphNode#/ and #** (ArithmeticMethods); a node type of its own
      # since omnibus18 (2026-10-30; a ProcNode block before, given these
      # facts as setters), so graphs show it as itself.  The plan layer
      # fuses it (Plan::Value#/ and #**; see #plan_unsupported_reason for
      # what stays unfused).
      #
      # The input's buffer is divided or raised in place (a frozen, shared
      # buffer is copied first; see FrozenCopy), with FastArithmetic.divide
      # and .power (allocation-free for real buffers, the same operations as
      # Numo's), else Numo.  With a Constant or Knob base (e.g. `10 ** (lfo
      # / 20)`) and MB::Sound.precision :fast, '**' raises with the plan
      # layer's fast 2^x (FastArithmetic.power_fast; see #fast_power_base).
      # A node operand ending ends the output; a shorter operand buffer
      # shortens the output buffer to match.
      class BinaryOperation
        include GraphNode
        include SampleRateHelper
        # (arithmetic on its inputs: no running state)
        node_traits memory: :none

        # The operators.
        OPERATORS = ['/', '**'].freeze

        # '/' or '**'.
        attr_reader :operator

        # True for a '**' node whose base is a Constant or Knob (a patch
        # constant): at MB::Sound.precision :fast it raises with the fast
        # 2^(b log2 a) (FastArithmetic.power_fast), as its plan op does
        # (Plan::Op::Pow#fast).
        attr_reader :fast_power_base

        # Creates a node computing +input+ +operator+ +operand+ (a number or
        # node).
        def initialize(input, operand, operator:, fast_power_base: false)
          raise ArgumentError, "Unknown operator #{operator.inspect} (#{OPERATORS.join(', ')})" unless OPERATORS.include?(operator)
          raise ArgumentError, 'Input must respond to #sample' unless input.respond_to?(:sample)

          @input = input.get_sampler
          @operand = operand.respond_to?(:sample) ? operand.get_sampler : operand
          @operator = operator
          @fast_power_base = !!fast_power_base
          @sample_rate = @input.sample_rate.to_f
          if @operand.respond_to?(:sample_rate) && @operand.sample_rate != @sample_rate
            raise "Operand #{@operand} sample rate #{@operand.sample_rate} does not match the input's #{@sample_rate}"
          end
          @copier = FrozenCopy.new
          @node_type_name = "BinaryOperation (#{operator})"
        end

        # The input and the operand (a number or node).
        def sources
          { input: @input, operand: @operand }
        end

        # The next +count+ samples of the input (op) the operand, or nil
        # once either ends.
        def sample(count)
          v = @input.sample(count)
          return nil if v.nil? || v.empty?

          if @operand.respond_to?(:sample)
            data = @operand.sample(v.length)
            return nil if data.nil? || data.empty?

            if data.length != v.length
              n = MB::M.min(data.length, v.length)
              data = data[0...n]
              v = v[0...n]
            end
          else
            data = @operand
          end

          # (the result, not v: a type promotion makes a new object)
          v = @copier.copy(v) if v.frozen?
          v.inplace!
          compute(v, data).not_inplace!
        end

        # +a+ (op) +b+, in place in +a+ where FastArithmetic can.
        def compute(a, b)
          if @operator == '/'
            MB::Sound::Kernels.divide(a, b) || a / b
          else
            (@fast_power_base && Precision.fast? && MB::Sound::Kernels.power_fast(a, b)) ||
              MB::Sound::Kernels.power(a, b) || a ** b
          end
        end

        # "a / b", "a ** b".
        def arithmetic_string(separator = ' ')
          "#{make_source_name(climb_tee_tree(@input))} #{@operator}#{separator}#{make_source_name(climb_tee_tree(@operand))}"
        end

        def to_s
          "#{super} -- #{arithmetic_string}"
        end

        def to_s_graphviz
          <<~EOF
          #{super}---------------
          #{arithmetic_string}
          EOF
        end

        # Plan layer (see MB::Sound::Plan): Value#/ and #**.
        include Plan::Describable

        def plan_describe(p)
          a = p[@input]
          b = p[@operand]
          @operator == '/' ? a / b : a ** b
        end

        def plan_inputs
          [@input, @operand].select { |s| s.respond_to?(:sample) }
        end

        def plan_unsupported_reason
          # (a Float exponent is filled into a register; see Plan::Builder#pow)
          return "a #{@operand.class} exponent (Numo multiplies)" if @operator == '**' && !@operand.respond_to?(:sample) && !@operand.is_a?(Float)
          return "a #{@operand.class} divisor" if @operator == '/' && @operand.is_a?(Numeric) && !@operand.is_a?(Float) && !@operand.is_a?(Integer)

          nil
        end
      end
    end
  end
end
