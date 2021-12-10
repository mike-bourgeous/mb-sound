module MB
  module Sound
    # Representation of a tone to generate or play.  Uses MB::Sound::Oscillator
    # for tone generation.
    class Tone
      include ArithmeticMixin

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
      end
      ::Numeric.include NumericToneMethods

      attr_reader :wave_type, :frequency, :amplitude, :range, :duration, :rate, :wavelength, :phase
      attr_reader :duration_set, :amplitude_set

      # Shortcut for creating a new tone with the given frequency source, for
      # building more complex FM signal graphs.
      def self.[](frequency)
        MB::Sound::Tone.new(frequency: frequency)
      end

      # Initializes a representation of a simple generated waveform.
      #
      # +wave_type+ - One of the waveform types supported by MB::Sound::Oscillator (e.g. :sine).
      # +frequency+ - The frequency of the tone, in Hz at the given +:rate+ (or
      #               a wavelength as Meters or Feet).
      # +amplitude+ - The linear peak amplitude of the tone, or a Range.
      # +phase+ - The starting phase, in radians relative to a sine wave (0
      #           radians phase starts at 0 and rises).
      # +duration+ - How long the tone should play in seconds (default is 5s).
      # +rate+ - The sample rate to use to calculate the frequency.
      def initialize(wave_type: :sine, frequency: 440, amplitude: 0.1, phase: 0, duration: 5, rate: 48000)
        @wave_type = wave_type
        @oscillator = nil
        @noise = false
        @amplitude_set = false
        @duration_set = false
        self.or_at(amplitude).or_for(duration).at_rate(rate).with_phase(phase)
        set_frequency(frequency)
      end

      # Changes the waveform type to sine.
      def sine
        @wave_type = :sine
        self
      end
      alias sin sine

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

      # Changes the waveform type to inverse Gaussian.  The histogram of this
      # waveform shows a truncated, roughly Gaussian distribution.  The peaks
      # of this wave type are higher, to match the RMS of the ramp wave.
      def gauss
        @wave_type = :gauss
        self
      end

      # Changes the waveform type to parabolic.
      def parabola
        @wave_type = :parabola
        self
      end

      # Changes the waveform to complex sine.  The real part is equal to the
      # sine waveform, and the complex part is such that the combined waveform
      # spirals counterclockwise.
      def complex_sine
        @wave_type = :complex_sine
        self
      end

      # Changes the waveform to complex square.  The real part is approximately
      # equal to the square waveform, and the complex part is the integral of
      # the cosecant, such that the resulting waveform matches the analytic
      # signal form of the square wave and spirals counterclockwise.
      def complex_square
        @wave_type = :complex_square
        self
      end

      # Changes the waveform to complex triangle.  The real part is a triangle
      # waveform, and the imaginary part is the second integral of the
      # cosecant, such that the resulting waveform matches the analytic signal
      # form of the triangle wave and spirals counterclockwise.
      def complex_triangle
        @wave_type = :complex_triangle
        self
      end

      # Changes the waveform to complex ramp.  The real part matches the
      # standard ramp waveform, and the imaginary part is an integral of a
      # modified cotangent function, such that the resulting waveform matches
      # the analytic signal of a ramp wave, spiraling counterclockwise.
      def complex_ramp
        @wave_type = :complex_ramp
        self
      end

      # Changes the oscillator to generate white noise using the distribution
      # of the current waveform.  For uniform noise, use the ramp wave type.
      # For approximately Gaussian noise, use the gauss wave type.  The
      # frequency should probably be 1Hz, but definitely needs to be nonzero.
      #
      # This sets the oscillator's +advance+ to 0, and +random_advance+ to
      # 2*pi.
      #
      # Example:
      #     1.hz.gauss.noise
      #
      # Also see the MB::Sound::Noise class for another way to synthesize
      # noise.
      def noise
        @noise = true
        self
      end

      # Sets the duration to the given number of seconds.
      def for(duration)
        @duration_set = true
        @duration = duration&.to_f
        self
      end

      # Sets the default duration in seconds, if #for and #forever have not
      # been called.  Pass nil to default to playing forever.
      def or_for(duration)
        unless @duration_set
          @duration = duration&.to_f
        end

        self
      end

      # Sets the tone to play forever.
      def forever
        @duration = nil
        self
      end

      # Changes the linear gain of the tone.  This may be negative to invert
      # the phase of the tone, or may be a Range to add a DC offset.
      def at(amplitude)
        if amplitude.is_a?(Range)
          @range = amplitude.begin.to_f..amplitude.end.to_f
          @amplitude = (@range.end - @range.begin) / 2
        else
          @amplitude = amplitude.to_f
          @range = -@amplitude..@amplitude
        end

        @amplitude_set = true

        self
      end

      # Sets the default linear +amplitude+ of the tone, which may be a Numeric
      # or a Range, if #at has not yet been called.
      def or_at(amplitude)
        unless @amplitude_set
          at(amplitude)
          @amplitude_set = false
        end

        self
      end

      # Changes the target sample rate of the tone.
      def at_rate(rate)
        @rate = rate
        @single_sample = 1.0 / @rate
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

      # Adds the given other +tone+ as a frequency modulator for this tone,
      # using the given modulation +index+ (good values range from 100 to
      # 10000, and the modulation index can also be applied to the other Tone
      # using #at).  This is true linear frequency modulation -- the rate of
      # phase is modulated -- as opposed to linear phase modulation, or
      # exponential frequency modulation (see #log_fm).
      #
      # If the current tone's frequency is already derived from a signal graph,
      # then this new +tone+ will be added to the existing graph output.
      #
      # Example:
      #     # Simple FM
      #     200.hz.fm(600.hz, 1000)
      #     # or
      #     200.hz.fm(600.hz.at(1000))
      #
      #     # Stacking is the same as adding
      #     200.hz.fm(600.hz.at(1000)).fm(300.hz.at(1000))
      #     # or
      #     200.hz.fm(600.hz.at(1000) + 300.hz.at(1000))
      #
      # TODO: Consider implementing phase modulation to create DX7-like sounds.
      # Would need to update both the Ruby and C oscillator code.
      def fm(tone, index = nil)
        tone = tone.hz if tone.is_a?(Numeric)
        tone = tone.at(1) if index && tone.is_a?(Tone)
        tone = tone.oscillator if tone.is_a?(Tone)
        @frequency = MB::Sound::Mixer.new([@frequency, [tone, index || 1]])
        self
      end

      # Like #fm, but the modulation index is in semitones instead of Hz.  This
      # mirrors classical analog exponential or "volt per octave" frequency
      # modulation.
      #
      # Examples:
      #     100.hz.log_fm(200.hz.at(2))
      def log_fm(tone, index = nil)
        raise 'This tone already has an FM modulator' if @frequency.respond_to?(:sample)
        tone = tone.hz if tone.is_a?(Numeric)
        tone = tone.at(1) if index
        tone = tone.oscillator if tone.is_a?(Tone)
        tone = 2 ** (tone / 12)
        tone = tone * index if index
        @frequency = @frequency * tone
        self
      end

      # Converts this Tone to the nearest Note based on its frequency.
      def to_note
        MB::Sound::Note.new(self)
      end

      # Converts this Tone to a MIDI note-on message from the midi-message gem.
      def to_midi(velocity: 64, channel: -1)
        to_note.to_midi(velocity: velocity, channel: channel)
      end

      # Generates +count+ samples of the tone, defaulting to the duration of
      # the tone, or one second of samples if duration is infinite.  The tone
      # parameters cannot be changed after this method is called.
      def generate(count = nil)
        count ||= @duration ? @duration * @rate : @rate
        oscillator.sample(count.round)
      end

      # Generates +count+ samples of the tone, decrementing the Tone's
      # #duration.  The tone parameters cannot be changed directly after this
      # method is called; instead Oscillator parameters must be changed.
      #
      # This will return nil if the tone has a specified duration and that
      # duration has elapsed.
      def sample(count)
        if @duration
          return nil if @duration <= 0

          @duration -= count.to_f / @rate

          if @duration < 0.5 * @single_sample # deal with rounding error
            @duration = 0
          end
        end

        oscillator.sample(count.round)
      end

      # See ArithmeticMixin#sources.  Returns the frequency source of the tone,
      # which will either be a number or a signal generator.
      def sources
        [@frequency]
      end

      # Returns an Oscillator that will generate a wave with the wave type,
      # frequency, etc. from this tone.  If this tone's frequency is changed
      # (e.g. by the Note subclass), the Oscillator will change frequency as
      # well, but other parameters likely won't be changed by changing the
      # Tone.
      def oscillator
        @oscillator ||= MB::Sound::Oscillator.new(
          @wave_type,
          frequency: @frequency,
          phase: @phase,
          advance: @noise ? 0 : Math::PI * 2.0 / @rate,
          random_advance: @noise ? Math::PI * 2.0 : 0,
          range: @range
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

      # Returns a first-order single-pole low-pass filter with this Tone's
      # frequency as its cutoff.  Only the tone's frequency and sample rate
      # parameters are used.
      #
      # Examples:
      #     50.hz.lowpass1p
      #     10.hz.at_rate(60).lowpass1p
      def lowpass1p
        MB::Sound::Filter::FirstOrder.new(:lowpass1p, @rate, @frequency)
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

      # Returns a LinearFollower with its max_rise and max_fall set to allow
      # variations back and forth between the max amplitude set by #at no
      # faster than this Tone's frequency.  This is a nonlinear filter with an
      # amplitude- and waveform-dependent effect.  It acts sort of like a
      # lowpass filter whose cutoff frequency decreases (and harmonic
      # distortion increases) as the signal amplitude increases.
      #
      # LinearFollowers are most useful for smoothing control inputs from e.g.
      # MIDI or analog sources.
      def follower
        # Multiple of 4 below:
        #   2 for the fact that a full cycle requires both a rise and fall, so
        #   must be twice frequency
        #
        #   2 for the fact that amplitude is one-sided, but the cycle must rise
        #   from -amplitude to +amplitude (so it travels a total of
        #   2*amplitude)
        MB::Sound::Filter::LinearFollower.new(
          rate: @rate,
          max_rise: 4 * @frequency * @amplitude,
          max_fall: 4 * @frequency * @amplitude,
          absolute: false
        )
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
        @single_sample = 1.0 / @rate
        buffer_size = output.buffer_size
        samples_left = @duration * @rate if @duration

        loop do
          current_samples = [samples_left || buffer_size, buffer_size].min
          d = [ MB::M.zpad(generate(current_samples), buffer_size) ]
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
        freq = freq.to_f if freq.is_a?(Numeric)
        @frequency = freq
        @wavelength = (SPEED_OF_SOUND / @frequency).meters if @frequency.is_a?(Numeric)
        @oscillator&.frequency = @frequency
      end
    end
  end
end
