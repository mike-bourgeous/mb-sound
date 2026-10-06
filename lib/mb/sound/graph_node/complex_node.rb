require 'forwardable'

module MB
  module Sound
    module GraphNode
      # Coerces a signal to its real, imaginary, magnitude, or phase component.
      class ComplexNode
        extend Forwardable

        include GraphNode

        VALID_MODES = [:real, :imag, :abs, :arg]

        MODE_NAMES = {
          real: 'Real',
          imag: 'Imaginary',
          abs: 'Absolute',
          arg: 'Argument',
        }

        attr_reader :mode, :mode_name

        def_delegators :@input, :sample_rate, :sample_rate=

        # Creates a complex-to-component conversion node from the given +input+
        # node in the given +:mode+.  The +:mode+ may be :real, :imag, :abs, or
        # :arg.
        def initialize(input, mode:)
          raise ArgumentError, "Invalid Complex conversion mode: #{mode.inspect}" unless VALID_MODES.include?(mode)
          raise ArgumentError, "Input must respond to #sample" unless input.respond_to?(:sample)

          @input = input.get_sampler
          @mode = mode
          @mode_name = MODE_NAMES[mode]
        end

        # Returns a source list containing the original input given to the
        # constructor.
        def sources
          { input: @input }
        end

        # Wraps upstream #at_rate to return self instead of upstream.
        def at_rate(new_rate)
          @input.at_rate(new_rate)
          self
        end

        # Converts the next +count+ samples from the original input according
        # to the mode given to the constructor.
        def sample(count)
          data = @input.sample(count)

          if data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex)
            case @mode
            when :real
              part(data, false) || data.real

            when :imag
              part(data, true) || data.imag

            when :abs
              data.abs

            when :arg
              data.arg

            else
              raise "BUG: Unsupported mode #{@mode}"
            end
          elsif data.is_a?(Numo::NArray)
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

          elsif data.nil?
            nil

          else
            raise "Unsupported datatype: #{data.class}"
          end
        end

        # Single-line description.
        def to_s
          "#{super} -- #{@mode_name}"
        end

        # Multiline description for GraphViz.
        def to_s_graphviz
          <<~EOF
          #{super}---------------
          #{@mode_name}
          EOF
        end

        private

        # The real (or +imag+inary) parts of complex +data+ in a reused
        # buffer (FastArithmetic.complex_part), or nil to use Numo.
        def part(data, imag)
          cls = data.is_a?(Numo::SComplex) ? Numo::SFloat : Numo::DFloat
          @part_buf = cls.zeros(data.length) unless @part_buf && @part_buf.class == cls && @part_buf.length == data.length
          MB::Sound::FastArithmetic.complex_part(@part_buf, data, imag)
        end
      end
    end
  end
end
