module MB
  module Sound
    # Representation of a tone to generate or play.  Uses MB::Sound::Oscillator
    # for tone generation.
    class Tone
      # Methods to be included in Numeric.
      module NumericToneMethods
        # Returns the number of seconds at the given sample rate (default
        # 48kHz).
        def samples(rate = 48000)
          self / rate
        end

        # Creates a Tone object with this frequency.
        #
        # Example:
        #     MB::Sound.play(100.hz.sine.at(-12.db).forever)
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
      end
      ::Numeric.include NumericToneMethods

      attr_reader :wave_type, :frequency, :amplitude, :duration, :rate

      # Initializes a representation of a simple generated waveform.
      #
      # +wave_type+ - One of the waveform types supported by MB::Sound::Oscillator (e.g. :sine).
      # +frequency+ - The frequency of the tone, in Hz at the given +:rate+.
      # +amplitude+ - The linear peak amplitude of the tone.
      # +duration+ - How long the tone should play in seconds (default is 5s).
      # +rate+ - The sample rate to use to calculate the frequency.
      def initialize(wave_type: :sine, frequency: 440, amplitude: 0.1, duration: 5, rate: 48000)
        @wave_type = wave_type
        @frequency = frequency.to_f
        @amplitude = amplitude.to_f
        @duration = duration&.to_f
        @rate = rate
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

      # Changes the linear gain of the tone.
      def at(amplitude)
        @amplitude = amplitude.to_f
        self
      end

      # Changes the target sample rate of the tone.
      def at_rate(rate)
        @rate = rate
        self
      end

      # Converts this Tone to the nearest Note based on its frequency.
      def to_note
        MB::Sound::Note.new(self)
      end

      # Generates +count+ samples of the tone, defaulting to the duration of
      # the tone, or 48000 samples if duration is infinite.  The tone
      # parameters cannot be changed after this method is called.
      def generate(count = nil)
        count ||= @duration ? @duration * @rate : 48000
        @oscillator ||= MB::Sound::Oscillator.new(
          @wave_type,
          frequency: @frequency,
          advance: Math::PI * 2.0 / @rate
        )

        @oscillator.sample(count) * @amplitude
      end

      # Writes the tone's full duration to the +output+ stream.  The tone will
      # be written into every channel of the output stream (TODO: support
      # different channels) at the output stream's sample rate.
      #
      # The tone parameters cannot be changed after this method is called.
      def write(output)
        # TODO: Fade in and out at the start and end

        @rate = output.rate
        samples_left = @duration * @rate if @duration

        loop do
          current_samples = [samples_left || 960, 960].min
          d = [ generate(current_samples) ]
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
    end
  end
end
