module MB
  module Sound
    module GraphNode
      # The shared base of nodes that apply one function to every sample of
      # one input: ComplexNode (a complex signal's real or imaginary part,
      # magnitude, or phase) and MathFunction (rounding and logarithms).
      # Subclasses stay thin: they list their functions in a FUNCTIONS Hash
      # (function Symbol => display name) and define #apply (the function
      # applied to one input buffer, returning a new buffer or nil to end).
      # The base keeps the input, the function, #sources, the descriptions,
      # and the plan layer's description (Plan::Op::Unary for the functions
      # in UnaryFunction::PLAN_FUNCTIONS of the subclass; see
      # #plan_function).
      #
      # The DSL names are the subclasses' (GraphNode#real, #imag, #arg,
      # #floor, #ceil, #round, #log, #log2, #log10; ComplexNode's :abs is the
      # complex magnitude, not GraphNode#abs, the antialiased shaper).
      class UnaryFunction
        include GraphNode

        # The function (a key of the subclass's FUNCTIONS).
        attr_reader :function

        # Creates a node applying +function+ (a key of the subclass's
        # FUNCTIONS) to each sample of +input+.
        def initialize(input, function:)
          functions = self.class::FUNCTIONS
          raise ArgumentError, "Unknown #{self.class.name.rpartition('::').last} function #{function.inspect} (#{functions.keys.join(', ')})" unless functions.include?(function)
          raise ArgumentError, 'Input must respond to #sample' unless input.respond_to?(:sample)

          @input = input.get_sampler
          @function = function
        end

        # The input given to the constructor.
        def sources
          { input: @input }
        end

        # The function applied to the next +count+ samples of the input (see
        # the subclass's #apply), or nil once the input ends.
        def sample(count)
          data = @input.sample(count)
          return nil if data.nil?

          apply(data)
        end

        # The input's sample rate (subclasses may keep their own).
        def sample_rate
          @input.sample_rate
        end

        # The display name of the function.
        def function_name
          self.class::FUNCTIONS[@function]
        end

        # The function and input, e.g. "floor(ramp)".
        def arithmetic_string(_separator = ' ')
          "#{function_name}(#{make_source_name(climb_tee_tree(@input))})"
        end

        # The description shown by #to_s and graphviz (the
        # #arithmetic_string unless a subclass says otherwise).
        def function_description
          arithmetic_string
        end

        def to_s
          "#{super} -- #{function_description}"
        end

        def to_s_graphviz
          <<~EOF
          #{super}---------------
          #{function_description}
          EOF
        end

        # Plan layer (see MB::Sound::Plan): one Op::Unary on the input's
        # Value (see #plan_function).
        include Plan::Describable

        def plan_describe(p)
          x = p[@input]
          fn = plan_function(x.complex?)
          raise Plan::Unsupported.new(self, "#{function_name} of a #{x.complex? ? 'complex' : 'real'} signal") unless fn

          fn == :copy ? x : p.unary(fn, x)
        end

        # The Plan::Op::Unary function computing this node on a real (or,
        # with +complex+, a complex) input Value, :copy to pass the input
        # through, or nil if the plan can't run it (the node stays
        # unfused).  Subclasses override.
        def plan_function(complex)
          nil
        end
      end
    end
  end
end
