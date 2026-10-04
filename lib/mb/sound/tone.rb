require 'forwardable'

module MB
  module Sound
    # Representation of a tone to generate or play.  Uses MB::Sound::Oscillator
    # for tone generation.
    class Tone
      extend Forwardable

      include GraphNode
      include GraphNode::SampleRateHelper

      attr_reader :wave_type, :frequency, :amplitude, :range, :wavelength, :phase
      attr_reader :period, :period_samples
      attr_reader :amplitude_set

      # Shortcut for creating a new tone with the given frequency source, for
      # building more complex FM signal graphs.
      def self.[](frequency)
        MB::Sound::Tone.new(frequency: frequency)
      end

      # Initializes an oscillator node with a simple generated waveform,
      # which plays forever (see Session and PlaybackMethods for ending
      # playback, or use a finite source such as an envelope or a file).
      #
      # +wave_type+ - One of the waveform types supported by MB::Sound::Oscillator (e.g. :sine).
      # +frequency+ - The frequency of the tone, in Hz at the given
      #               +:sample_rate+ (or a wavelength as Meters or Feet).
      # +amplitude+ - The linear peak amplitude of the tone, or a Range
      #               (default 1: full scale, -1..1; the master bus is
      #               -10 dB by default, see Session#master_gain).
      # +phase+ - The starting phase, in radians relative to a sine wave (0
      #           radians phase starts at 0 and rises).
      # +sample_rate+ - The sample rate to use to calculate the frequency.
      def initialize(wave_type: :sine, frequency: 440, amplitude: 1.0, phase: 0, sample_rate: 48000)
        @wave_type = wave_type
        @oscillator = nil
        @band_limit = true
        @lfo = false
        @width = nil
        @keep_dc = false
        @sync = nil
        @soft_sync = false
        @noise = 0
        @amplitude_set = false
        @phase_mod = nil
        @no_trigger = false

        @frequency = nil
        @phase = nil
        @period = nil

        self.or_at(amplitude).at_rate(sample_rate).with_phase(phase)
        set_frequency(fixup_source(frequency))
      end

      # Changes the waveform type to sine.
      def sine
        @wave_type = :sine
        self
      end
      alias sin sine

      # Changes the waveform type to a band-limited triangle (see BandLimit;
      # #atriangle is the naive, aliased version).
      def triangle
        set_wave(:triangle, true)
      end

      # Changes the waveform type to a naive (aliased) triangle, whose
      # corners alias a little; see #triangle.
      def atriangle
        set_wave(:triangle, false)
      end

      # Changes the waveform type to a band-limited square (see BandLimit;
      # #asquare is the naive, aliased version).
      def square
        set_wave(:square, true)
      end

      # Changes the waveform type to a naive (aliased) square, whose jumps
      # alias audibly at high pitches; see #square.
      def asquare
        set_wave(:square, false)
      end

      # Changes the waveform type to a band-limited ramp (sawtooth; see
      # BandLimit; #aramp is the naive, aliased version).
      def ramp
        set_wave(:ramp, true)
      end
      alias saw ramp
      alias sawtooth ramp

      # Changes the waveform type to a naive (aliased) ramp, whose jump
      # aliases audibly at high pitches (the classic digital grit); see
      # #ramp.
      def aramp
        set_wave(:ramp, false)
      end
      alias asaw aramp
      alias asawtooth aramp

      # True if this tone's ramp, square, or triangle waveform is
      # band-limited (see #ramp, #aramp).
      def band_limited?
        @band_limit
      end

      # Warps the phase so the first half of the waveform plays over +width+
      # of each cycle and the second half over the rest: pulse width
      # modulation for every shape.  A square becomes a pulse (see #pulse), a
      # triangle a skewed triangle (towards a saw near 0 or 1), a ramp a saw
      # with a kink, and a sine an asymmetric sine (like Casio's phase
      # distortion).  +width+ is a number from 0 to 1 (0.5 is no change) or a
      # graph node, read every sample.  Band-limited shapes stay band-limited
      # (including the corners the warp adds to sines and parabolas).
      #
      # A warped waveform's DC offset (e.g. 2 * width - 1 for a pulse) is
      # removed, like the AC-coupled output of an analog synth, so sweeping
      # the width doesn't thump; pass dc: true to keep it.  Also available as
      # #skew.
      #
      # Examples (bin/sound.rb):
      #     play 110.hz.pwm(0.5.hz.lfo.at(0.1..0.9)).square.at(-12.db)   # classic PWM
      #     play 110.hz.triangle.skew(0.1).at(-12.db)                    # nearly a saw
      #     play C2.sine.pwm(adsr(0.01, 0.3, 0.2, 0.3).at(0.5..0.05))   # CZ-style sweep
      def pwm(width, dc: false)
        @width = fixup_source(width)
        @keep_dc = !!dc
        if @oscillator
          @oscillator.width = @width
          @oscillator.remove_dc = !@keep_dc
        end
        self
      end
      alias skew pwm

      # The phase warp width (see #pwm), or nil.
      attr_reader :width

      # Hard sync: restarts this tone's waveform at every cycle of a master,
      # the classic sweepable lead sound.  With +ratio:+ the master is this
      # tone's own pitch (hidden, not heard) and this tone plays at that
      # pitch times +ratio+ (a number or a graph node), so the note sets the
      # pitch and the ratio sweeps the timbre:
      #
      #     play C2.saw.sync(ratio: adsr(0.01, 0.4, 0.3, 0.3).at(1..6))
      #
      # Or give a +master+: a Pitch or Note (a hidden phasor at that pitch),
      # a Tone or Phasor (its #wraps port, so it can be heard too), or any
      # graph node of sync pulses or triggers (e.g. clip.trigger; a value v
      # resets the phase 1 - v samples before its sample, so 1 is exactly on
      # it):
      #
      #     play C3.saw.sync(C2)
      #
      # Synced tones are band-limited with minBLEP (BandLimit, FastSynth.
      # oscillate_sync), clean even at high ratios; aramp etc. give naive
      # sync.  A synced tone can't also have phase modulation.  See
      # #softsync.
      def sync(master = nil, ratio: nil)
        set_sync(master, ratio, false)
      end

      # Soft sync: like #sync, but each master cycle reverses the direction
      # of this tone's phase instead of restarting it (a gentler, more
      # metallic sound).
      #
      #     play C2.triangle.softsync(ratio: 1.5.hz.lfo.at(1.5..3))
      def softsync(master = nil, ratio: nil)
        set_sync(master, ratio, true)
      end

      # The sync pulse source (see #sync), or nil.
      attr_reader :sync_source

      # Sync pulses from this tone's phase (a GraphNode::Ports port; see
      # Phasor.sync_pulses and #sync).
      def wraps
        oscillator.wraps
      end

      # This tone's phase increment per sample, in cycles (a port).
      def increment
        oscillator.increment
      end

      # The ports of this tone's oscillator in use (see GraphNode::Ports).
      def ports
        oscillator.ports
      end

      # Every port this tone has, with descriptions (see GraphNode::Ports).
      def port_info
        oscillator.port_info
      end

      # Changes the waveform to a band-limited pulse that is high for +width+
      # (0 to 1, or a graph node) of each cycle: #square with #pwm.  See #pwm
      # for +dc+; #apulse is the naive (aliased) version.
      #
      # Example (bin/sound.rb):
      #     play 220.hz.pulse(0.25).at(-12.db)
      def pulse(width = 0.5, dc: false)
        square.pwm(width, dc: dc)
      end

      # The naive (aliased) version of #pulse.
      def apulse(width = 0.5, dc: false)
        asquare.pwm(width, dc: dc)
      end

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
        set_wave(:complex_square, true)
      end

      # The naive (aliased) version of #complex_square, which also has energy at
      # negative frequencies; see BandLimit.blit_ruby.
      def acomplex_square
        set_wave(:complex_square, false)
      end

      # Changes the waveform to complex triangle.  The real part is a triangle
      # waveform, and the imaginary part is the second integral of the
      # cosecant, such that the resulting waveform matches the analytic signal
      # form of the triangle wave and spirals counterclockwise.
      def complex_triangle
        set_wave(:complex_triangle, true)
      end

      # The naive (aliased) version of #complex_triangle, which also has energy at
      # negative frequencies; see BandLimit.blit_ruby.
      def acomplex_triangle
        set_wave(:complex_triangle, false)
      end

      # Changes the waveform to complex ramp.  The real part matches the
      # standard ramp waveform, and the imaginary part is an integral of a
      # modified cotangent function, such that the resulting waveform matches
      # the analytic signal of a ramp wave, spiraling counterclockwise.
      #
      # Complex ramp, square, and triangle are band-limited (closed-form
      # band-limited impulse trains, integrated; see BandLimit.blit_ruby):
      # no aliasing and no negative frequencies, with the top octave lifted
      # slightly (+2.6 dB at 20 kHz).  With phase modulation they fall back to
      # the naive versions (acomplex_ramp, ...), which alias and clip their
      # imaginary parts.
      def complex_ramp
        set_wave(:complex_ramp, true)
      end

      # The naive (aliased) version of #complex_ramp, which also has energy at
      # negative frequencies; see BandLimit.blit_ruby.
      def acomplex_ramp
        set_wave(:complex_ramp, false)
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

      # Changes the linear gain of the tone.  This may be negative to invert
      # the phase of the tone, or may be a Range to add a DC offset.
      #
      # A Range of Sequence::Durations (e.g. `3.n16..5.n16`) makes the tone
      # output a musical length in whole notes (see #musical_time?), which
      # delay methods convert to seconds at the current tempo:
      #
      #     sig.delay(2.bars.lfo.square.at(3.n16..5.n16))   # alternates each bar
      def at(amplitude)
        durations = amplitude.is_a?(Range) ? [amplitude.begin, amplitude.end].count { |v| v.is_a?(Sequence::Duration) } : 0
        raise ArgumentError, 'Use a Range of Durations (e.g. 3.n16..5.n16), not a single Duration' if amplitude.is_a?(Sequence::Duration)
        raise ArgumentError, 'Both ends of a Range must be Durations, or neither' if durations == 1
        @musical_time = durations == 2

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

      # True if #at was given a Range of Durations, so this tone outputs a
      # musical length in whole notes rather than a plain number.
      def musical_time?
        !!@musical_time
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

      # Makes this Tone a low-frequency oscillator for modulation: it won't
      # be retriggered by MIDI voices (see #no_trigger) and swings over the
      # full -1..1 range unless #at was called.  Call #at afterward to set the
      # range.
      #
      # Band-limited waveforms (ramp, square, triangle) fade their
      # band-limiting in between 15 and 30 Hz (BandLimit::LFO_FADE), so a slow
      # LFO keeps exact jumps and corners (e.g. a delay time that should jump)
      # while an LFO pushed to audio rates is band-limited.
      #
      # Durations have their own #lfo for tempo-synced LFOs (see
      # Sequence::Duration#lfo).
      #
      # Example:
      #     play 220.hz.ramp.at(1).filter(:lowpass, cutoff: 0.25.hz.triangle.lfo.at(200..2000), quality: 4)
      def lfo
        @lfo = true
        @oscillator&.band_limit = oscillator_band_limit
        no_trigger
        or_at(1)
      end

      # Sets this Tone's current phase to +cycles+ past its phase offset (see
      # #with_phase).  Used by Sequence::TempoNode to lock tempo-synced tones
      # to the timeline.
      def sync_cycles(cycles)
        oscillator.phasor.sync(cycles)
        self
      end

      # For a Tone whose frequency follows the tempo (see
      # Sequence::Duration#hz), lets its phase run free of the timeline and
      # keeps it running while the timeline is paused.  Its frequency still
      # follows the tempo.  See Sequence::TempoNode#freewheel.
      def freewheel(free = true)
        node = graph.find { |n| n.is_a?(Sequence::TempoNode) && n.follows?(self) }
        raise ArgumentError, 'Only tempo-synced tones (e.g. 4.bars.lfo) can freewheel' if node.nil?

        node.freewheel(free)
        self
      end

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

      # The last frequency value used by the oscillator for synthesis.
      def last_freq
        oscillator.last_freq
      end

      # Generates +count+ samples of the tone.  The tone parameters cannot be
      # changed directly after this method is called; instead Oscillator
      # parameters must be changed (TODO: fix this; maybe combine the two
      # classes or delegate post-creation updates).
      #
      # Returns nil only if a frequency or phase modulation source ends.
      def sample(count)
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
          width: @width,
          sync: @sync,
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
          no_trigger: @no_trigger,
          band_limit: oscillator_band_limit,
          width: @width,
          remove_dc: !@keep_dc,
          sync: @sync,
          soft_sync: @soft_sync
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
        "#{super} -- #{wave_name} freq=#{make_source_name(@frequency)} range=#{@range}#{" pwm=#{make_source_name(@width)}" if @width}#{" #{@soft_sync ? 'softsync' : 'sync'}" if @sync}"
      end

      def to_s_graphviz
        <<~EOF
        #{super}---------------
        #{wave_name}
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

      # See #sync and #softsync.
      def set_sync(master, ratio, soft)
        raise ArgumentError, 'Give a master or a ratio:, not both' if master && ratio
        raise ArgumentError, 'Give a master (e.g. C2) or ratio: (e.g. ratio: 2.5)' if master.nil? && ratio.nil?

        if master.nil?
          # A hidden master at this tone's pitch; this tone plays ratio times higher
          hidden = Phasor.new(frequency: @frequency, sample_rate: @sample_rate)
          ratio = fixup_source(ratio)
          set_frequency(@frequency.is_a?(Numeric) && ratio.is_a?(Numeric) ? @frequency * ratio : fixup_source(ratio.is_a?(Numeric) ? @frequency * ratio : ratio * @frequency))
          pulses = hidden.wraps
        else
          pulses = case master
                   when Pitch then master.phasor.wraps
                   when Tone, Phasor, Oscillator then master.wraps
                   else
                     raise ArgumentError, "Sync master must be a Pitch, Tone, Phasor, or a graph node (got #{master.inspect})" unless master.respond_to?(:sample)
                     master
                   end
        end

        @sync = pulses.respond_to?(:get_sampler) ? pulses.get_sampler : pulses
        @soft_sync = soft
        if @oscillator
          @oscillator.sync = @sync
          @oscillator.soft_sync = soft
        end
        self
      end

      # Sets the wave type and whether it's band-limited (see #ramp, #aramp).
      def set_wave(wave_type, band_limit)
        @wave_type = wave_type
        @band_limit = band_limit
        if @oscillator
          @oscillator.wave_type = wave_type
          @oscillator.band_limit = oscillator_band_limit
        end
        self
      end

      # The band_limit setting for the Oscillator (see Oscillator#band_limit).
      def oscillator_band_limit
        return false unless @band_limit
        @lfo ? BandLimit::LFO_FADE : true
      end

      # The wave type as written in the DSL (e.g. :aramp for a naive ramp).
      def wave_name
        !@band_limit && (BandLimit::WAVES + BandLimit::COMPLEX_WAVES).include?(@wave_type) ? :"a#{@wave_type}" : @wave_type
      end

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

        if src.respond_to?(:sources)
          # O(n^2)ish if building a complex network of modulation?
          if src == self || src.graph(include_tees: true).include?(self) || self.graph(include_tees: true).include?(src)
            raise 'Cyclic modulation detected'
          end
        end

        src = src.or_at(1) if src.is_a?(Tone)
        src = src.at_rate(@sample_rate) if src.respond_to?(:at_rate) && src.sample_rate != @sample_rate
        src = src.get_sampler if src.respond_to?(:get_sampler)
        src
      end
    end
  end
end
