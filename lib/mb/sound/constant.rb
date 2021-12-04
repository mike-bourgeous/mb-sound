module MB
  module Sound
    # A signal generator (with a #sample method; see ArithmeticMixin and Tone)
    # that returns a constant numeric value.
    class Constant
      include ArithmeticMixin

      attr_accessor :constant

      # Initializes a constant-output signal generator.
      def initialize(constant)
        raise 'The constant value must be a numeric' unless constant.is_a?(Numeric)
        @constant = constant
        @buf = nil
      end

      # Returns +count+ samples of the constant value.
      def sample(count)
        setup_buffer(count)
        @buf.fill(@constant)
      end

      def sources
        [@constant]
      end

      private

      def setup_buffer(length)
        @complex = @constant.is_a?(Complex)
        @bufclass = @complex ? Numo::SComplex : Numo::SFloat

        if @buf.nil? || @buf.length != length || @bufclass != @buf.class
          @buf = @bufclass.zeros(length)
        end
      end
    end
  end
end
