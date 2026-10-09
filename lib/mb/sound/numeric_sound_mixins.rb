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


      # Returns a length of this many samples (Length::Samples), counted at
      # the sample rate where it's used: `sig.delay(5.samples)`.
      def samples
        Length::Samples.new(self)
      end

      # Returns a length of this many seconds (Length::Seconds):
      # `sig.delay(0.25.seconds)`.  Plain numbers are seconds where a method
      # counts in seconds, but this also works where plain numbers mean bars
      # (e.g. `fade: 2.seconds`).  Also available as #second.
      def seconds
        Length::Seconds.new(self)
      end
      alias second seconds

      # Returns a length of this many milliseconds (as Length::Seconds):
      # `sig.delay(250.ms)`.  Also available as #milliseconds and
      # #millisecond.
      def ms
        Length::Seconds.new(self / 1000.0)
      end
      alias milliseconds ms
      alias millisecond ms

      # Returns a pitch Interval of this many octaves: `filter_env(depth:
      # 3.oct)`.  Also available as #octave and #oct.
      def octaves
        Interval.new(self * 12, unit: :octaves)
      end
      alias octave octaves
      alias oct octaves

      # Returns a pitch Interval of this many semitones: `C4.transpose(7.st)`.
      # Also available as #semitone, #st, and #semi.
      def semitones
        Interval.new(self, unit: :semitones)
      end
      alias semitone semitones
      alias st semitones
      alias semi semitones

      # Returns a pitch Interval of this many cents (hundredths of a
      # semitone): `detune: 12.cents`.  Whole numbers stay exact.  Also
      # available as #cent.
      def cents
        Interval.new(is_a?(Integer) ? Rational(self, 100) : self / 100.0, unit: :cents)
      end
      alias cent cents

      # Returns an oscillator Phase of this many cycles (1 cycle = 360
      # degrees = 2 pi radians): `440.hz.with_phase(0.25.cycles)`,
      # `pm(mod, 0.4.cycles)`.  Also available as #cycle and #cyc.
      def cycles
        Phase.new(self)
      end
      alias cycle cycles
      alias cyc cycles

      # Returns a Pitch at this frequency in Hz, which makes oscillators
      # (`100.hz.sine.at(-12.db)`) and plays as a sine when used as a signal.
      # If this is a Meters or Feet object, then the frequency is calculated
      # using the distance represented as the wavelength.
      #
      # Example:
      #     MB::Sound.play(100.hz.sine.at(-12.db))
      #     343.meters.hz # => 1.0 Hz pitch
      def hz
        Pitch.new(self)
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
