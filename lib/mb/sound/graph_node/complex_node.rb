module MB
  module Sound
    module GraphNode
      # Coerces a signal to its real, imaginary, magnitude, or phase component.
      class ComplexNode
        include GraphNode

        VALID_MODES = [:real, :imag, :abs, :arg]

        attr_reader :mode

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
          [@input]
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
              # signbit returns Numo::Bit, multiplying by Math::PI first
              # returns DFloat.  Benchmarks show that casting the bit array
              # then multiplying is faster than multiplying directly, then
              # casting.
              (data.class.cast(data.signbit).inplace * Math::PI).not_inplace!

            else
              raise "BUG: Unsupported mode #{@mode}"
            end
          end
        end
      end
    end
  end
end
