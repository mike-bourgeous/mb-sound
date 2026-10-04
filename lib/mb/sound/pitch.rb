module MB
  module Sound
    # A pitch: a frequency source that can become oscillators.  The source is
    # a constant in Hz (`440.hz`, also a wavelength like `2.meters.hz`), or a
    # node producing Hz: a Note's follows the session Tuning (see Note), and
    # a Sequence::Duration's follows the tempo (`1.beat.hz`, see
    # Sequence::TempoNode).
    #
    # Pitches are light values, so they can be passed around and stored
    # (e.g. in sequences) without creating oscillators.  Oscillator methods
    # make a new Tone at this pitch each time they're called: #tone (alias
    # #hz) for a sine, #sine/#triangle/#ramp/... for other waves, and #at,
    # #with_phase, #fm, #log_fm, #pm, #lfo, #noise as shortcuts on that tone;
    # #phasor makes a Phasor.  Filter helpers (#lowpass, #highpass, ...) use
    # the current frequency.
    #
    # A Pitch used directly as a signal (`play 440.hz`, `440.hz * env`) is a
    # full-scale sine (#signal).  Arithmetic works on that signal, so
    # `440.hz * 2` doubles the amplitude; use #transpose or `(f * 2).hz` for
    # frequency changes.
    #
    # Examples (bin/sound.rb):
    #     play 440.hz                       # a sine at 440 Hz
    #     play 220.hz.ramp.at(0.5)          # a sawtooth
    #     play C4.triangle.at(-6.db)        # a note in the session tuning
    #     filter(noise, 1000.hz.lowpass)    # a filter at the pitch's frequency
    class Pitch
      include GraphNode

      # Creates a Pitch from a frequency in Hz, a wavelength (e.g.
      # `2.meters`), or a node producing Hz.
      def self.[](frequency)
        new(frequency)
      end

      # The sample rate for oscillators made from this pitch.
      attr_reader :sample_rate

      # Creates a pitch at +frequency+ (see the class description).
      # Subclasses like Note pass nil and override #frequency and #freq.
      def initialize(frequency = nil, sample_rate: 48000)
        frequency = SPEED_OF_SOUND / frequency.meters if frequency.is_a?(NumericSoundMixins::Distance)

        unless frequency.nil? || frequency.is_a?(Numeric) || frequency.respond_to?(:sample)
          raise ArgumentError, "A Pitch needs a frequency in Hz or a node (got #{frequency.inspect})"
        end

        @source = frequency.is_a?(Numeric) ? frequency.to_f : frequency
        @sample_rate = sample_rate.to_f
        @signal = nil
      end

      # The current frequency in Hz.
      def frequency
        case
        when @source.is_a?(Numeric) then @source
        when @source.respond_to?(:value) then @source.value
        when @source.respond_to?(:constant) then @source.constant
        else raise ArgumentError, "Can't find the current frequency of #{@source}"
        end
      end

      # True if the frequency never changes (a constant in Hz).
      def constant?
        @source.is_a?(Numeric)
      end

      # A node producing the frequency in Hz.
      def freq
        constant? ? @source.constant(sample_rate: @sample_rate) : @source
      end

      # The frequency to give an oscillator: the constant itself (the fast
      # path) or #freq.
      def oscillator_frequency
        constant? ? @source : freq
      end

      # Returns a new full-scale Tone (sine unless +wave_type+ is given) at
      # this pitch.
      def tone(wave_type = :sine)
        Tone.new(frequency: oscillator_frequency, wave_type: wave_type, sample_rate: @sample_rate).tap { |t| follow(t) }
      end
      alias hz tone

      # Wave shapes: each returns a new Tone at this pitch.
      [
        :sine, :sin, :triangle, :square, :ramp, :saw, :sawtooth, :drumramp, :envramp, :gauss, :parabola,
        :atriangle, :asquare, :aramp, :asaw, :asawtooth,
        :complex_sine, :complex_square, :complex_triangle, :complex_ramp,
        :acomplex_square, :acomplex_triangle, :acomplex_ramp,
      ].each do |wave|
        define_method(wave) { tone.public_send(wave) }
      end

      # Shortcuts for a sine Tone at this pitch (see Tone#at, #with_phase,
      # #fm, #log_fm, #pm, #lfo, #pwm/#skew, #noise, #no_trigger), and a
      # pulse (Tone#pulse, #apulse).
      def at(amplitude) = tone.at(amplitude)
      def with_phase(phase) = tone.with_phase(phase)
      def fm(tone_or_node, index = nil) = tone.fm(tone_or_node, index)
      def log_fm(tone_or_node, index = nil) = tone.log_fm(tone_or_node, index)
      def pm(tone_or_node, index = nil) = tone.pm(tone_or_node, index)
      def lfo = tone.lfo
      def sync(master = nil, ratio: nil) = tone.sync(master, ratio: ratio)
      def softsync(master = nil, ratio: nil) = tone.softsync(master, ratio: ratio)
      def wraps = signal.wraps
      def increment = signal.increment
      def pwm(width, dc: false) = tone.pwm(width, dc: dc)
      def skew(width, dc: false) = tone.skew(width, dc: dc)
      def pulse(width = 0.5, dc: false) = tone.pulse(width, dc: dc)
      def apulse(width = 0.5, dc: false) = tone.apulse(width, dc: dc)
      def noise(blend = true) = tone.noise(blend)
      def no_trigger(trig = true) = tone.no_trigger(trig)

      # The Oscillator of #signal.
      def oscillator
        signal.oscillator
      end

      # For a tempo-synced pitch (Sequence::Duration#hz), lets the phases of
      # its oscillators run free of the timeline (see
      # Sequence::TempoNode#freewheel).
      def freewheel(free = true)
        raise ArgumentError, 'Only tempo-synced tones (e.g. 4.bars.lfo) can freewheel' unless @source.respond_to?(:freewheel)

        @source.freewheel(free)
        self
      end

      # Returns a Phasor (phase in cycles) at this pitch.
      def phasor(phase: 0.0)
        Phasor.new(frequency: oscillator_frequency, phase: phase, sample_rate: @sample_rate).tap { |p| follow(p) }
      end

      # The sine this pitch plays as when used directly as a signal (created
      # on first use).
      def signal
        @signal ||= tone
      end

      def sample(count)
        signal.sample(count)
      end

      def sources
        { signal: signal }
      end

      # Sets the sample rate for oscillators made from now on (and #signal).
      def sample_rate=(sample_rate)
        @sample_rate = sample_rate.to_f
        @signal&.at_rate(@sample_rate)
        self
      end
      alias at_rate sample_rate=

      # Returns a Pitch +semitones+ higher (lower if negative).
      def transpose(semitones)
        ratio = 2 ** (semitones / 12.0)
        Pitch.new(constant? ? @source * ratio : freq * ratio, sample_rate: @sample_rate)
      end

      # The period of one cycle in seconds and in samples.
      def period = 1.0 / frequency
      def period_samples = period * @sample_rate

      # The wavelength of this pitch in air (see SPEED_OF_SOUND).
      def wavelength
        (SPEED_OF_SOUND / frequency).meters
      end

      # Returns the nearest Note (with detuning) in the current tuning.
      def to_note
        Note.new(MB::Sound.tuning.number_of(frequency))
      end

      # Converts to a MIDI note-on message from the midi-message gem.
      def to_midi(velocity: 64, channel: -1)
        to_note.to_midi(velocity: velocity, channel: channel)
      end

      # A second-order low-pass filter at this frequency.
      #
      # Examples:
      #     1000.hz.lowpass
      #     1000.hz.at_rate(44100).lowpass
      def lowpass(quality: 1)
        MB::Sound::Filter::Cookbook.new(:lowpass, @sample_rate, frequency, quality: quality)
      end

      # A first-order low-pass filter at this frequency.
      #
      # Examples:
      #     50.hz.lowpass1p
      #     10.hz.at_rate(60).lowpass1p
      def lowpass1p
        MB::Sound::Filter::FirstOrder.new(:lowpass1p, @sample_rate, frequency)
      end

      # A second-order high-pass filter at this frequency.
      def highpass(quality: 1)
        MB::Sound::Filter::Cookbook.new(:highpass, @sample_rate, frequency, quality: quality)
      end

      # A peaking filter at this frequency with +gain+ (linear, default 1)
      # and a bandwidth of +octaves+.  `500.hz.at(3.db).peak` uses the
      # amplitude as the gain (see Tone#peak).
      def peak(octaves: 0.5, gain: 1.0)
        MB::Sound::Filter::Cookbook.new(:peak, @sample_rate, frequency, bandwidth_oct: octaves, db_gain: gain.to_db)
      end

      # A LinearFollower that follows full-scale changes no faster than this
      # frequency (see Tone#follower).
      def follower
        tone.follower
      end

      # Compares pitches by frequency (e.g. for Ranges of Notes).  Not
      # Comparable: == stays identity, since pitches are graph nodes too.
      def <=>(other)
        case other
        when Numeric then frequency <=> other
        when Pitch, Tone then frequency <=> other.frequency
        end
      end

      def to_s
        "#{MB::M.sigfigs(frequency, 6)} Hz" rescue "#{self.class.name} (variable)"
      end

      def inspect
        "#<#{self.class.name} #{self}>"
      end

      private

      # Lets a tempo source (Sequence::TempoNode) lock the phase of an
      # oscillator made from this pitch to the timeline.
      def follow(phase_holder)
        @source.add_follower(phase_holder) if @source.respond_to?(:add_follower)
      end
    end
  end
end
