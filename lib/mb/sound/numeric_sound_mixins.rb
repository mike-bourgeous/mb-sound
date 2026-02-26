module MB
  module Sound
    # Audio-related methods like #hz and #db to mix into the Numeric core
    # class.
    module NumericSoundMixins
      # Superclass of Meters and Feet for detecting their presence.
      class Distance < Numeric
      end

      # Represents a distance in meters.  A simple trick inspired by the Scalar
      # class in ActiveSupport::Duration.
      #
      # Some operations produce nonsensical results, e.g. squaring a Meters
      # value doesn't change the result to square meters.  This is not a proper
      # units system, though one could imagine building a units system as a
      # Ruby DSL.
      class Meters < Distance
        # Initializes a Meters distance object with the given Numeric value.
        def initialize(f)
          if f.is_a?(Meters)
            @f = f.instance_variable_get(:@f)
          elsif f.is_a?(Feet)
            @f = f.meters.instance_variable_get(:@f)
          elsif !f.is_a?(Numeric)
            raise 'Meters must be Numeric'
          else
            @f = f
          end
        end

        # Passes arithmetic operations to the raw numeric value.
        def method_missing(*a)
          a.map! { |v|
            v.is_a?(Feet) ? v.meters : v
          }
          result = @f.public_send(*a)
          (!a[0].to_s.start_with?('to_') && result.is_a?(Numeric) && !result.is_a?(Meters)) ? Meters.new(result) : result
        end

        # Returns a Feet object with this distance converted to feet.
        def feet
          Feet.new(@f / 0.0254 / 12.0)
        end

        def to_s
          @f.abs == 1 ? "#{@f} meter" : "#{@f} meters"
        end
        alias inspect to_s

        undef ==
          undef <
        undef >
        undef <=>
      end

      # Represents a distance in feet.  A simple trick inspired by the Scalar
      # class in ActiveSupport::Duration.  See the Meters class.
      class Feet < Distance
        # Initializes a Feet distance object with the given Numeric value.
        def initialize(f)
          if f.is_a?(Feet)
            @f = f.instance_variable_get(:@f)
          elsif f.is_a?(Meters)
            @f = f.feet.instance_variable_get(:@f)
          elsif !f.is_a?(Numeric)
            raise 'Feet must be Numeric'
          else
            @f = f
          end
        end

        # Passes arithmetic operations to the raw numeric value.
        def method_missing(*a)
          a.map! { |v|
            v.is_a?(Meters) ? v.feet : v
          }
          result = @f.public_send(*a)
          (!a[0].to_s.start_with?('to_') && result.is_a?(Numeric) && !result.is_a?(Feet)) ? Feet.new(result) : result
        end

        # Returns a Meters object with this distance converted to meters.
        def meters
          Meters.new(@f * 12.0 * 0.0254)
        end

        def to_s
          @f.abs == 1 ? "#{@f} foot" : "#{@f} feet"
        end
        alias inspect to_s

        undef ==
          undef <
        undef >
        undef <=>
      end


      # Returns the number of seconds at the given sample rate (default
      # 48kHz).
      def samples(rate = 48000)
        self.to_f / rate
      end

      # Creates a Tone object with this frequency.  If this is a Meters or
      # Feet object, then the frequency is calculated using the distance
      # represented as the wavelength.
      #
      # Example:
      #     MB::Sound.play(100.hz.sine.at(-12.db).forever)
      #     343.meters.hz # => 1.0 Hz tone
      def hz
        Tone.new(frequency: self)
      end

      # Converts this number as a decibel value to a linear gain value.
      def db
        10.0 ** (self / 20.0)
      end
      alias dB db

      # Converts this number from a linear gain value to a decibel value.
      # Since decibels represent magnitude only without a sign, negative and
      # positive values of equal magnitude will both have the same decibel
      # value.
      def to_db
        20.0 * Math.log10(self.abs)
      end

      # Converts this number to the quantization increment of a signed
      # integer sample with this number of bits.  E.g. 8.bits returns 1.0 /
      # 128.0.  This works with fractional values as well for e.g. smoothly
      # varying quantization levels.  It also works with Complex values, but
      # that's kind of nonsensical.
      def bits
        0.5 ** (self - 1)
      end
      alias bit bits

      # Creates a Feet object with this numeric value.
      def feet
        Feet.new(self)
      end
      alias foot feet

      # Creates a Feet object with this numeric value converted from inches.
      def inches
        Feet.new(self / 12.0)
      end
      alias inch inches

      # Creates a Meters distance object with this numeric value.
      def meters
        Meters.new(self)
      end
      alias meter meters
    end

    ::Numeric.include(NumericSoundMixins)
  end
end
