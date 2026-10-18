module MB
  module Sound
    module GraphNode
      # Applies a math function to every sample of its input: rounding
      # (+:floor+, +:ceil+, +:round+) or logarithms (+:ln+, +:log2+,
      # +:log10+).  Made by GraphNode#floor, #ceil, #round, #log, #log2, and
      # #log10 (ArithmeticMethods); a node type of its own (instead of a
      # ProcNode block), so graphs using these print back as Ruby and show
      # their function in graphviz.  A thin subclass of UnaryFunction; the
      # plan layer fuses it (Plan::Op::Unary) on real signals.
      #
      # Example (a stepped ramp: 4 steps per second, 0, 1/3, 2/3, 1):
      #     (1.hz.asaw.at(0..4) * 0.9999).floor / 3
      class MathFunction < UnaryFunction
        include SampleRateHelper

        # Display names of the functions.
        FUNCTIONS = {
          floor: 'floor',
          ceil: 'ceil',
          round: 'round',
          ln: 'ln',
          log2: 'log2',
          log10: 'log10',
        }.freeze

        # Creates a node applying +function+ (a key of FUNCTIONS) to each
        # sample of +input+.
        def initialize(input, function:, sample_rate: nil)
          super(input, function: function)
          @sample_rate = (sample_rate || @input.sample_rate).to_f
          @node_type_name = "MathFunction (#{FUNCTIONS[function]})"
        end

        # The function applied to +data+ (a new buffer; the input's buffer
        # is never modified).
        def apply(data)
          case @function
          when :floor then data.floor
          when :ceil then data.ceil
          when :round then data.round
          when :ln then MB::FastSound.narray_log(data)
          when :log2 then MB::FastSound.narray_log2(data)
          when :log10 then MB::FastSound.narray_log10(data)
          end
        end

        # Every function is a plan op on real signals (C's floor, ceil,
        # round in double as Numo computes them, and logf, log2f, log10f as
        # FastSound's).
        def plan_function(complex)
          complex ? nil : @function
        end
      end
    end
  end
end
