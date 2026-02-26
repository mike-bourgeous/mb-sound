module MB
  module Sound
    # Representation of a tone to generate or play.  Uses MB::Sound::Oscillator
    # for tone generation.
    class Tone
      include GraphNode
      include GraphNode::SampleRateHelper

      attr_reader :wave_type, :frequency, :amplitude, :range, :duration, :wavelength, :phase
      attr_reader :period, :period_samples
      attr_reader :duration_set, :amplitude_set

      # Shortcut for creating a new tone with the given frequency source, for
      # building more complex FM signal graphs.
      def self.[](frequency)
        MB::Sound::Tone.new(frequency: frequency)
      end

      # Initializes a representation of a simple generated waveform.
      #
      # +wave_type+ - One of the waveform types supported by MB::Sound::Oscillator (e.g. :sine).
      # +frequency+ - The frequency of the tone, in Hz at the given
      #               +:sample_rate+ (or a wavelength as Meters or Feet).
      # +amplitude+ - The linear peak amplitude of the tone, or a Range.
      # +phase+ - The starting phase, in radians relative to a sine wave (0
      #           radians phase starts at 0 and rises).
      # +duration+ - How long the tone should play in seconds (default is 5s).
      # +sample_rate+ - The sample rate to use to calculate the frequency.
      def initialize(wave_type: :sine, frequency: 440, amplitude: 0.1, phase: 0, duration: 5, sample_rate: 48000)
        @wave_type = wave_type
        @oscillator = nil
        @noise = 0
        @amplitude_set = false
        @duration_set = false
        @phase_mod = nil
        @no_trigger = false
        self.or_at(amplitude).or_for(duration).at_rate(sample_rate).with_phase(phase)
        set_frequency(fixup_source(frequency))
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
      alias saw ramp
      alias sawtooth ramp

      # Changes the waveform type to ramp, with phase set so the oscillator
      # starts at the bottom instead of the middle of its ramp.  This allows
      # using #drumramp oscillators to play beats in time with each other.
      def drumramp
        ramp.with_phase(-Math::PI)
      end
      alias envramp drumramp

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
      # 2*pi, or if +blend+ is used, to values between those and the original
      # values.
      #
      # The +blend+ parameter may be used to give a value between 0 and 1 to
      # interpolate between the original tone and pure noise.  Useful values
      # are around 0.000001 to 0.0001.
      #
      # Example:
      #     1.hz.gauss.noise
      #
      # Also see the MB::Sound::Noise class for another way to synthesize
      # noise.
      def noise(blend = true)
        case blend
        when true
          @noise = 1.0

        when false
          @noise = 0.0

        else
          @noise = blend.to_f
        end

        self
      end

      # Sets the duration to the given number of seconds, starting from now (in
      # sample time).
      def for(duration, recursive: true)
        super(duration, recursive: recursive)

        @duration_set = true
        @duration = duration&.to_f

        self
      end

      # Sets the default duration in seconds, if #for and #forever have not
      # been called.  Pass nil to default to playing forever.
      def or_for(duration, recursive: :ignored)
        unless @duration_set
          @duration = duration&.to_f
        end

        self
      end

      # Sets the tone to play forever, as well as any tones in its frequency or
      # phase sources.
      def forever(recursive: true)
        super(recursive: recursive)
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

      # Returns the sample rate of the tone (or its underlying oscillator if it
      # has been created).
      def sample_rate
        @sample_rate
      end

      # Changes the target sample rate of the tone.
      def sample_rate=(sample_rate)
        super
        @period_samples = @period * @sample_rate if @period
        @oscillator&.at_rate(sample_rate)
        self
      end
      alias at_rate sample_rate=

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
      def fm(tone, index = nil)
        tone = tone.hz if tone.is_a?(Numeric)
        tone = tone.at(1) if index && tone.is_a?(Tone)
        tone = fixup_source(tone)
        index = fixup_source(index)
        @frequency = MB::Sound::GraphNode::Mixer.new([@frequency, [tone, index || 1]], sample_rate: @sample_rate)
        self
      end

      # Like #fm, but the modulation index is in semitones instead of Hz.  This
      # mirrors classical analog exponential or "volt per octave" frequency
      # modulation.
      #
      # If the current tone's frequency is already derived from a signal graph,
      # then this new +tone+ will be multiplied by the existing graph output.
      #
      # Examples:
      #     100.hz.log_fm(200.hz.at(2))
      def log_fm(tone, index = nil)
        tone = tone.hz if tone.is_a?(Numeric)
        tone = tone.at(1) if index && tone.is_a?(Tone)

        tone = fixup_source(tone)
        index = fixup_source(index)

        tone = 2 ** (tone / 12)
        tone = tone * index if index
        @frequency = @frequency * tone

        self
      end

      # Adds the given other +tone+ or signal graph as a phase modulation
      # source for this tone.  Like #fm, but added to the phase given to the
      # oscillator, rather than to the frequency itself.
      def pm(tone, index = nil)
        tone = tone.hz if tone.is_a?(Numeric)
        if tone.is_a?(Tone)
          if index
            tone.at(1)
          else
            tone.or_at(1)
          end
        end

        tone = fixup_source(tone)
        index = fixup_source(index)

        tone = tone * index if index
        @phase_mod = tone

        self
      end

      # Marks the Tone as being used for modulation rather than tone
      # generation, so that MB::Sound::MIDI::GraphVoice won't retrigger it when
      # a note is played.
      def no_trigger(trig = true)
        @no_trigger = trig
        self
      end
      alias lfo no_trigger

      # Returns true if this Tone is not intended to be retriggered when a note
      # is played.
      def no_trigger?
        @no_trigger
      end
      alias lfo? no_trigger?

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
        count ||= @duration ? @duration * @sample_rate : @sample_rate
        oscillator.sample(count.round)
      end

      # Generates +count+ samples of the tone, decrementing the Tone's
      # #duration.  The tone parameters cannot be changed directly after this
      # method is called; instead Oscillator parameters must be changed (TODO:
      # fix this; maybe combine the two classes or delegate post-creation
      # updates).
      #
      # This will return nil if the tone has a specified duration and that
      # duration has elapsed.
      def sample(count)
        if @duration
          return nil if @duration <= 0

          # TODO: use a separate elapsed time counter to allow resetting
          # duration to the beginning
          remaining = (@duration * @sample_rate).round
          count = remaining if count > remaining

          @duration -= count.to_f / @sample_rate

          @duration = 0 if remaining == 0 # deal with fraction of a sample
        end

        return nil if count <= 0

        oscillator.sample(count.round)
      end

      # See GraphNode#sources.  Returns the frequency and phase modulation
      # source of the tone, which will either be a number or a signal
      # generator.
      def sources
        {
          frequency: @frequency,
          phase: @phase,
          phase_mod: @phase_mod,
        }.compact
      end

      # Returns an Oscillator that will generate a wave with the wave type,
      # frequency, etc. from this tone.  If this tone's frequency is changed
      # (e.g. by the Note subclass), the Oscillator will change frequency as
      # well, but other parameters likely won't be changed by changing the
      # Tone.
      def oscillator
        rand_adv = MB::M.interp(0, Math::PI * 2.0, @noise)

        @oscillator ||= MB::Sound::Oscillator.new(
          @wave_type,
          frequency: @frequency,
          phase: @phase,
          advance: Math::PI * 2.0 / @sample_rate - 0.5 * rand_adv,
          random_advance: rand_adv,
          range: @range,
          phase_mod: @phase_mod,
          no_trigger: @no_trigger
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
        MB::Sound::Filter::Cookbook.new(:lowpass, @sample_rate, @frequency, quality: quality)
      end

      # Returns a first-order single-pole low-pass filter with this Tone's
      # frequency as its cutoff.  Only the tone's frequency and sample rate
      # parameters are used.
      #
      # Examples:
      #     50.hz.lowpass1p
      #     10.hz.at_rate(60).lowpass1p
      def lowpass1p
        MB::Sound::Filter::FirstOrder.new(:lowpass1p, @sample_rate, @frequency)
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
        MB::Sound::Filter::Cookbook.new(:highpass, @sample_rate, @frequency, quality: quality)
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
        MB::Sound::Filter::Cookbook.new(:peak, @sample_rate, @frequency, bandwidth_oct: octaves, db_gain: gain.to_db)
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
          sample_rate: @sample_rate,
          max_rise: 4 * @frequency * @amplitude,
          max_fall: 4 * @frequency * @amplitude,
          absolute: false
        )
      end

      def to_s
        "#{super} -- #{@wave_type} freq=#{make_source_name(@frequency)} range=#{@range}"
      end

      def to_s_graphviz
        <<~EOF
        #{super}---------------
        #{@wave_type}
        freq=#{make_source_name(@frequency)}
        range=#{@range}
        EOF
      end

      # Allow comparison of tones by frequency for use in Range.
      def <=>(other)
        f1 = @frequency

        case other
        when Numeric
          f2 = other

        when Tone
          f2 = other.frequency

        else
          raise TypeError, "Cannot convert #{other.class} to Tone or Numeric"
        end

        raise "Cannot compare dynamic frequencies" unless f1.is_a?(Numeric) && f2.is_a?(Numeric)

        f1 <=> f2
      end

      private

      # Allows subclasses (e.g. Note) to change the frequency after construction.
      def set_frequency(freq)
        if freq.is_a?(MB::Sound::NumericSoundMixins::Distance)
          freq = MB::Sound::SPEED_OF_SOUND / freq.meters
        end

        if freq.is_a?(Numeric)
          freq = freq.to_f if freq.is_a?(Numeric)
          @period = 1.0 / freq
          @period_samples = @period * @sample_rate
        else
          @period = nil
          @period_samples = nil
        end

        @frequency = freq
        @wavelength = (SPEED_OF_SOUND / @frequency).meters if @frequency.is_a?(Numeric)
        @oscillator&.frequency = @frequency
      end

      # Configures the source given as the frequency, FM amount, PM amount,
      # etc. for indefinite playback and for this node's sample rate.  Returns
      # a tee'd sampler from the source if it responds to :get_sampler, or the
      # source itself.
      #
      # Returns nil if the source is nil.
      def fixup_source(src)
        return nil if src.nil?

        src = src.or_at(1) if src.is_a?(Tone)
        src = src.or_for(nil) if src.respond_to?(:or_for)
        src = src.at_rate(@sample_rate) if src.respond_to?(:at_rate) && src.sample_rate != @sample_rate
        src = src.get_sampler if src.respond_to?(:get_sampler)
        src
      end
    end
  end
end
