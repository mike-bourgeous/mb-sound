module MB
  module Sound
    # Representation of a tone to generate or play.  Uses MB::Sound::Oscillator
    # for tone generation.
    class Tone
      # Speed of sound for wavelength calculations, in meters per second.
      SPEED_OF_SOUND = 343.0

      # Represents a distance in meters.  A simple trick inspired by the Scalar
      # class in ActiveSupport::Duration.
      #
      # Some operations produce nonsensical results, e.g. squaring a Meters
      # value doesn't change the result to square meters.  This is not a proper
      # units system, though one could imagine building a units system as a
      # Ruby DSL.
      class Meters < Numeric
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
      class Feet < Numeric
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

      # Methods to be included in Numeric.
      module NumericToneMethods
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

        # Returns the number itself (radians are the default).
        def radians
          self
        end

        # Converts degrees to radians.
        def degrees
          self * Math::PI / 180.0
        end
      end
      ::Numeric.include NumericToneMethods

      attr_reader :wave_type, :frequency, :amplitude, :duration, :rate, :wavelength, :phase

      # Initializes a representation of a simple generated waveform.
      #
      # +wave_type+ - One of the waveform types supported by MB::Sound::Oscillator (e.g. :sine).
      # +frequency+ - The frequency of the tone, in Hz at the given +:rate+ (or
      #               a wavelength as Meters or Feet).
      # +amplitude+ - The linear peak amplitude of the tone.
      # +phase+ - The starting phase, in radians relative to a sine wave (0
      #           radians phase starts at 0 and rises).
      # +duration+ - How long the tone should play in seconds (default is 5s).
      # +rate+ - The sample rate to use to calculate the frequency.
      def initialize(wave_type: :sine, frequency: 440, amplitude: 0.1, phase: 0, duration: 5, rate: 48000)
        @wave_type = wave_type
        @amplitude = amplitude.to_f
        @duration = duration&.to_f
        @rate = rate
        @phase = 0
        @oscillator = nil
        set_frequency(frequency)
      end

      # Changes the waveform type to sine.
      def sine
        @wave_type = :sine
        self
      end

      # Changes the waveform type to triangle.
      def triangle
        @wave_type = :triangle
        self
      end

      # Changes the waveform type to square.
      def square
        @wave_type = :square
        self
      end

      # Changes the waveform type to ramp.
      def ramp
        @wave_type = :ramp
        self
      end

      # Sets the duration to the given number of seconds.
      def for(duration)
        @duration = duration.to_f
        self
      end

      # Sets the tone to play forever.
      def forever
        @duration = nil
        self
      end

      # Changes the linear gain of the tone.  This may be negative.
      def at(amplitude)
        @amplitude = amplitude.to_f
        self
      end

      # Changes the target sample rate of the tone.
      def at_rate(rate)
        @rate = rate
        self
      end

      # Changes the initial phase of the tone, in radians relative to a sine
      # wave.  0 phase starts oscillators at 0 and rising (or at the top half
      # of the cycle for a square wave).
      #
      # Example: 123.hz.with_phase(90.degrees)
      def with_phase(phase)
        @phase = phase
        self
      end

      # Converts this Tone to the nearest Note based on its frequency.
      def to_note
        MB::Sound::Note.new(self)
      end

      # Generates +count+ samples of the tone, defaulting to the duration of
      # the tone, or one second of samples if duration is infinite.  The tone
      # parameters cannot be changed after this method is called.
      def generate(count = nil)
        count ||= @duration ? @duration * @rate : @rate
        oscillator.sample(count.round)
      end

      # Returns an Oscillator that will generate a wave with the wave type,
      # frequency, etc. from this tone.  If this tone's frequency is changed
      # (e.g. by the Note subclass), the Oscillator will change frequency as
      # well, but other parameters cannot be changed.
      def oscillator
        @oscillator ||= MB::Sound::Oscillator.new(
          @wave_type,
          frequency: @frequency,
          phase: @phase,
          advance: Math::PI * 2.0 / @rate,
          range: -@amplitude..@amplitude
        )
      end

      # Returns a second-order low-pass Filter with this Tone's frequency as its
      # cutoff.  Only the tone's frequency and sample rate parameters are used.
      #
      # Examples:
      #
      #     1000.hz.lowpass
      #     1000.hz.at_rate(44100).lowpass
      def lowpass(quality: 1)
        MB::Sound::Filter::Cookbook.new(:lowpass, @rate, @frequency, quality: quality)
      end

      # Returns a second-order high-pass Filter with this Tone's frequency as
      # its cutoff.  Only the tone's frequency and sample rate parameters are
      # used.
      #
      # Examples:
      #
      #     120.hz.highpass
      #     120.hz.at_rate(96000).highpass
      def highpass(quality: 1)
        MB::Sound::Filter::Cookbook.new(:highpass, @rate, @frequency, quality: quality)
      end

      # Returns a peaking Filter with this Tone's frequency as its center, the
      # tone's amplitude as its gain factor (unless +:gain+ is specified), and
      # the given bandwidth in +:octaves+).
      #
      # Examples:
      #
      #     500.hz.at(3.db).peak
      #     500.hz.peak(octaves: 2, gain: -3.db)
      def peak(octaves: 0.5, gain: nil)
        gain ||= @amplitude
        MB::Sound::Filter::Cookbook.new(:peak, @rate, @frequency, bandwidth_oct: octaves, db_gain: gain.to_db)
      end

      # Writes the tone's full duration to the +output+ stream.  The tone will
      # be written into every channel of the output stream (TODO: support
      # different channels) at the output stream's sample rate.
      #
      # The tone parameters cannot be changed after this method is called.
      def write(output)
        # TODO: Fade in and out at the start and end
        # TODO: Maybe change this to act like an input instead, with a read
        # method and a frames method?
        # TODO: Maybe eventually have a way to detect outputs with strict
        # buffer size requirements, and only pad them, while leaving e.g.
        # ffmpegoutput unpadded.

        @rate = output.rate
        buffer_size = output.buffer_size
        samples_left = @duration * @rate if @duration

        loop do
          current_samples = [samples_left || buffer_size, buffer_size].min
          d = [ MB::Sound::A.zpad(generate(current_samples), buffer_size) ]
          output.write(d * output.channels)

          if samples_left
            samples_left -= current_samples
            break if samples_left <= 0
          end
        end
      end

      def to_s
        inspect
      end

      private

      # Allows subclasses (e.g. Note) to change the frequency after construction.
      def set_frequency(freq)
        freq = SPEED_OF_SOUND / freq.meters if freq.is_a?(Feet) || freq.is_a?(Meters)
        @frequency = freq.to_f
        @wavelength = (SPEED_OF_SOUND / @frequency).meters
        @oscillator&.frequency = @frequency
      end
    end
  end
end
