module MB
  module Sound
    # A signal generator (with a #sample method; see ArithmeticMixin and Tone)
    # that returns a constant numeric value.
    class Constant
      include ArithmeticMixin

      module NumericConstantMethods
        # Converts this numeric value into a MB::Sound::Constant constant-value
        # signal generator.
        def constant
          MB::Sound::Constant.new(self)
        end
      end
      Numeric.include(NumericConstantMethods)

      attr_accessor :constant

      # Initializes a constant-output signal generator.  If +:smooth+ is true,
      # then when the constant is changed, the output value will change
      # smoothly over the length of one buffer (TODO: use a constant-length FIR
      # filter?  consider using or merging with filter/smoothstep.rb?).
      def initialize(constant, smooth: true)
        raise 'The constant value must be a numeric' unless constant.is_a?(Numeric)
        @constant = constant
        @old_constant = constant
        @smooth = !!smooth
        @buf = nil
      end

      # Returns +count+ samples of the constant value.
      def sample(count)
        setup_buffer(count)

        if @constant != @old_constant && @smooth
          @buf.inplace!
          @buf = MB::FastSound.smoothstep_buf(@buf)
          @buf * (@constant - @old_constant)
          @buf + @old_constant
        else
          @buf.fill(@constant)
        end

        @old_constant = @constant

        @buf.not_inplace!
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
