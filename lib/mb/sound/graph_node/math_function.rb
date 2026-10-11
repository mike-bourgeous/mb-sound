module MB
  module Sound
    module GraphNode
      # Applies a math function to every sample of its input: rounding
      # (+:floor+, +:ceil+, +:round+) or logarithms (+:ln+, +:log2+,
      # +:log10+).  Made by GraphNode#floor, #ceil, #round, #log, #log2, and
      # #log10 (ArithmeticMethods); a node type of its own (instead of a
      # ProcNode block), so graphs using these print back as Ruby and show
      # their function in graphviz.
      #
      # Example (a stepped ramp: 4 steps per second, 0, 1/3, 2/3, 1):
      #     (1.hz.aramp.at(0..4) * 0.9999).floor / 3
      class MathFunction
        include GraphNode
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

        # The function (a key of FUNCTIONS).
        attr_reader :function

        # Creates a node applying +function+ (a key of FUNCTIONS) to each
        # sample of +input+.
        def initialize(input, function:, sample_rate: nil)
          raise ArgumentError, "Unknown math function #{function.inspect} (#{FUNCTIONS.keys.join(', ')})" unless FUNCTIONS.include?(function)
          raise ArgumentError, 'Input must respond to #sample' unless input.respond_to?(:sample)

          @input = input.get_sampler
          @function = function
          @sample_rate = (sample_rate || @input.sample_rate).to_f
          @node_type_name = "MathFunction (#{FUNCTIONS[function]})"
        end

        def sources
          { input: @input }
        end

        # The function applied to the next +count+ samples of the input (a
        # new buffer; the input's buffer is never modified).
        def sample(count)
          data = @input.sample(count)
          return nil if data.nil?

          case @function
          when :floor then data.floor
          when :ceil then data.ceil
          when :round then data.round
          when :ln then MB::FastSound.narray_log(data)
          when :log2 then MB::FastSound.narray_log2(data)
          when :log10 then MB::FastSound.narray_log10(data)
          end
        end

        # The function and input, e.g. "floor(ramp)".
        def arithmetic_string(_separator = ' ')
          "#{FUNCTIONS[@function]}(#{make_source_name(climb_tee_tree(@input))})"
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
      end
    end
  end
end
