module MB
  module Sound
    module GraphNode
      # Coerces a signal to its real, imaginary, magnitude, or phase component.
      class ComplexNode
        VALID_MODES = [:real, :imag, :abs, :arg]

        # Creates a complex-to-component conversion node from the given +input+
        # node in the given +:mode+.  The +:mode+ may be :real, :imag, :abs, or
        # :arg.
        def initialize(input, mode:)
          raise ArgumentError, "Invalid Complex conversion mode: #{mode.inspect}" unless VALID_MODES.include?(mode)
          raise ArgumentError, "Input must respond to #sample" unless input.respond_to?(:sample)

          @input = input
          @mode = mode
        end

        # Returns a source list containing the original input given to the
        # constructor.
        def sources
          [@inout]
        end

        # Converts the next +count+ samples from the original input according
        # to the mode given to the constructor.
        def sample(count)
          data = @input.sample(count)

          if data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex)
            case @mode
            when :real
              data.real

            when :imag
              data.imag

            when :abs
              data.abs

            when :arg
              data.arg

            else
              raise "BUG: Unsupported mode #{@mode}"
            end
          else
            case @mode
            when :real
              data

            when :imag
              data.class.zeros(count)

            when :abs
              data.abs

            when :arg
              data.class.zeros(count)

            else
              raise "BUG: Unsupported mode #{@mode}"
            end
          end
        end
      end
    end
  end
end
