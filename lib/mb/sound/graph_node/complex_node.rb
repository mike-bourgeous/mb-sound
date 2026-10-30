require 'forwardable'

module MB
  module Sound
    module GraphNode
      # Coerces a signal to its real, imaginary, magnitude, or phase
      # component (GraphNode#real, #imag, #arg; the :abs mode is the complex
      # magnitude, not GraphNode#abs, the antialiased shaper).  A thin
      # subclass of UnaryFunction; the plan layer fuses every mode
      # (Plan::Op::Part for :real and :imag, Plan::Op::Unary for :abs and
      # :arg).
      class ComplexNode < UnaryFunction
        extend Forwardable

        VALID_MODES = [:real, :imag, :abs, :arg]

        MODE_NAMES = {
          real: 'Real',
          imag: 'Imaginary',
          abs: 'Absolute',
          arg: 'Argument',
        }

        # The modes as UnaryFunction functions (display names).
        FUNCTIONS = {
          real: 'real',
          imag: 'imag',
          abs: 'abs',
          arg: 'arg',
        }.freeze

        attr_reader :mode_name

        def_delegators :@input, :sample_rate, :sample_rate=

        # Creates a complex-to-component conversion node from the given +input+
        # node in the given +:mode+.  The +:mode+ may be :real, :imag, :abs, or
        # :arg.
        def initialize(input, mode:)
          raise ArgumentError, "Invalid Complex conversion mode: #{mode.inspect}" unless VALID_MODES.include?(mode)
          raise ArgumentError, "Input must respond to #sample" unless input.respond_to?(:sample)

          super(input, function: mode)
          @mode_name = MODE_NAMES[mode]
        end

        # The conversion mode (the UnaryFunction function).
        def mode
          @function
        end

        # Plan layer (see MB::Sound::Plan): the real or imaginary part (a
        # real input passes through; its imaginary part is zero), the
        # magnitude, or the phase.
        def plan_describe(p)
          x = p[@input]
          case @function
          when :real then x.real
          when :imag then x.complex? ? x.imag : p.fill(0)
          else super
          end
        end

        # See UnaryFunction#plan_function: Numo's complex magnitude
        # (float(hypot)) and phase (float(atan2)), and for real signals the
        # absolute value and the sign's phase (0 or pi).
        def plan_function(complex)
          case @function
          when :abs then complex ? :cabs : :abs
          when :arg then complex ? :carg : :sign_arg
          end
        end

        # Wraps upstream #at_rate to return self instead of upstream.
        def at_rate(new_rate)
          @input.at_rate(new_rate)
          self
        end

        # Converts +data+ (a buffer of the input) according to the mode given
        # to the constructor.
        def apply(data)
          count = data.length
          if data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex)
            case @function
            when :real
              part(data, false) || data.real

            when :imag
              part(data, true) || data.imag

            when :abs
              data.abs

            when :arg
              data.arg

            else
              raise "BUG: Unsupported mode #{@function}"
            end
          elsif data.is_a?(Numo::NArray)
            case @function
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
              raise "BUG: Unsupported mode #{@function}"
            end

          else
            raise "Unsupported datatype: #{data.class}"
          end
        end

        # The mode's name for #to_s and graphviz (e.g. "Real").
        def function_description
          @mode_name
        end

        private

        # The real (or +imag+inary) parts of complex +data+ in a reused
        # buffer (Kernels.complex_part), or nil to use Numo.
        def part(data, imag)
          cls = data.is_a?(Numo::SComplex) ? Numo::SFloat : Numo::DFloat
          @part_buf = cls.zeros(data.length) unless @part_buf && @part_buf.class == cls && @part_buf.length == data.length
          MB::Sound::Kernels.complex_part(@part_buf, data, imag)
        end
      end
    end
  end
end
