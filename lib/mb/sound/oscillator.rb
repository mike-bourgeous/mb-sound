require 'midi-message'
require 'nibbler'

require 'mb/fast_sound'

module MB
  module Sound
    # An oscillator that can generate different wave types.  This can be used
    # to generate sound, or as an LFO (low-frequency oscillator).  It can also
    # generate noise with various statistical distributions by setting advance
    # to 0 and random_advance to 2*pi.  All oscillators should start at 0
    # (except for e.g. square, which doesn't have a zero), and rise first
    # before falling, unless a phase offset is specified.
    #
    # An exponential distortion can be applied to the output before or after
    # values are scaled to the desired output range.
    class Oscillator
      RAND = Random.new
      WAVE_TYPES = [
        :sine,
        :complex_sine,
        :square,
        :complex_square,
        :triangle,
        :complex_triangle,
        :ramp,
        :complex_ramp,
        :gauss,
        :parabola,
      ]

      # Buffer type to use for each oscillator.  Anything not included here
      # uses Numo::SFloat.
      BUFFER_CLASS = {
        complex_sine: Numo::SComplex,
        complex_square: Numo::SComplex,
        complex_triangle: Numo::SComplex,
        complex_ramp: Numo::SComplex,
      }

      # See #initialize; this is used to make negative powers more useful.
      NEGATIVE_POWER_SCALE = {
        sine: 0.01,
        triangle: 0.01,
        ramp: 0.01,
        square: 1.0,
        gauss: 0.01,
        parabola: 0.01,
      }

      # Default note that is used as tuning reference
      DEFAULT_TUNE_NOTE = 69 # A4

      # Default frequency that the tuning reference should be
      DEFAULT_TUNE_FREQ = 440

      # Sets the MIDI note number to use as tuning reference.  C4 (middle C) is
      # note 60, A4 is note 69.  This only affects future frequency changes;
      # existing Tones, Notes, or Oscillators will not be modified.  The
      # default is DEFAULT_TUNE_NOTE (A4, note number 69).
      def self.tune_note=(note_number)
        @tune_note = note_number
      end

      # Returns the MIDI note number used as tuning reference.  This note will
      # be tuned to the tune_freq.  See also the calc_freq method.  The default
      # is DEFAULT_TUNE_NOTE (note 69, A4).
      def self.tune_note
        @tune_note ||= DEFAULT_TUNE_NOTE
      end

      # Sets the frequency in Hz of the tune_note.  This only affects future
      # frequency changes.  Existing Tones, Notes, or Oscillators will not be
      # changed.  The default is DEFAULT_TUNE_FREQ (440Hz).  Set to nil to
      # restore the default.
      def self.tune_freq=(freq_hz)
        @tune_freq = freq_hz
      end

      # Returns the frequency in Hz that the tune_note should be.  The default
      # is DEFAULT_TUNE_FREQ (440Hz).
      def self.tune_freq
        @tune_freq ||= DEFAULT_TUNE_FREQ
      end

      # Calculates a frequency in Hz for the given MIDI note number and
      # detuning in cents, based on the tuning parameters set by the tune_freq=
      # and tune_note= class methods and using 12 tone equal temperament
      # (defaults to 440Hz A4).
      def self.calc_freq(note_number, detune_cents = 0)
        tune_freq * 2 ** ((note_number + detune_cents / 100.0 - tune_note) / 12.0)
      end

      # Calculates a fractional MIDI note number for the given frequency,
      # assuming equal temperament.
      def self.calc_number(frequency_hz)
        12.0 * Math.log2(frequency_hz / tune_freq) + tune_note
      end

      attr_accessor :advance, :wave_type, :pre_power, :post_power, :range, :advance, :random_advance
      attr_reader :phi, :phase, :frequency

      # TODO: maybe use a clock provider instead of +advance+?  The challenge is
      # that floating point accuracy goes down as a shared clock advances, and
      # every oscillator needs its own internal phase if the phase is to be kept
      # within 0..2pi.  Maybe also separate the oscillator from the phase
      # counter?

      # Initializes a low frequency oscillator with the given +wave_type+,
      # +frequency+, and +range+.  The +advance+ parameter makes it easier to
      # control the speed of a large number of oscillators.
      #
      # To avoid complex results for non-integer +pre_power+ and +post_power+
      # values, the absolute value of the oscillator is taken, the power applied,
      # and then the original sign restored.  For negative powers, values are
      # scaled down by the value from NEGATIVE_POWER_SCALE and clamped to -1..1
      # after pre_power is applied.  See the .safe_power function.
      #
      # +wave_type+ - One of the symbols from WAVE_TYPES.
      # +frequency+ - The number of cycles for every 2*pi/+advance+ calls to
      #               #sample.  Pass (2 * Math::PI / sample_rate) to +:advance+
      #               for this +frequency+ to be in Hz.
      # +phase+ - The initial offset of the oscillator (typically 0 to 2*pi).
      # +range+ - The output range of the oscillator (defaults to -1..1).
      # +pre_power+ - The oscillator output will be raised to this power before scaling to +range+.
      # +post_power+ - The oscillator output will be raised to this power after scaling to +range+.
      # +advance+ - The base amount to increment the internal phase for each call
      #             to #sample.  This should be (2 * Math::PI / sample_rate)
      #             for audio oscillators.
      # +random_advance+ - The internal phase is incremented by a random value up to this amount on top of +advance+.
      def initialize(wave_type, frequency: 1.0, phase: 0.0, range: nil, pre_power: 1.0, post_power: 1.0, advance: Math::PI / 24000.0, random_advance: 0.0)
        unless WAVE_TYPES.include?(wave_type)
          raise "Invalid wave type #{wave_type.inspect}; only #{WAVE_TYPES.map(&:inspect).join(', ')} are supported"
        end
        @wave_type = wave_type

        self.frequency = frequency

        raise "Invalid phase #{phase.inspect}" unless phase.is_a?(Numeric)
        @phase = phase % (2.0 * Math::PI)
        @phi = @phase

        raise "Invalid range #{range.inspect}" unless range.nil? || range.first.is_a?(Numeric)
        @range = range

        raise "Invalid pre_power #{pre_power.inspect}" unless pre_power.is_a?(Numeric)
        @pre_power = pre_power.to_f

        raise "Invalid post_power #{post_power.inspect}" unless post_power.is_a?(Numeric)
        @post_power = post_power.to_f

        raise "Invalid advance #{advance.inspect}" unless advance.is_a?(Numeric)
        @advance = advance.to_f

        raise "Invalid random advance #{random_advance.inspect}" unless random_advance.is_a?(Numeric)
        @random_advance = random_advance

        @osc_buf = nil
      end

      # Changes the starting phase offset for this oscillator, shifting the
      # oscillator's current phase accordingly.
      def phase=(phase)
        @phi = (@phi + phase - @phase) % (Math::PI * 2)
        @phase = phase % (Math::PI * 2)
      end

      # Directly sets the current phase offset for this oscillator.
      def phi=(phi)
        @phi = phi % (Math::PI * 2)
      end

      # Resets the oscillator phase to its starting phase (see #phase).
      def reset
        @phi = @phase
      end

      def frequency=(frequency)
        raise "Invalid frequency #{frequency.inspect}" unless frequency.is_a?(Numeric) || frequency.respond_to?(:sample)

        @frequency = frequency
        f0 = frequency.respond_to?(:sample) ? f0.sample(1)[0] : f0.to_f
        @note_number = Oscillator.calc_number(f0)
      end

      # Returns an approximate MIDI note number for the oscillators frequency,
      # assuming equal temperament.  This value may be fractional, and may be
      # outside of the MIDI range of 0..127.
      def number
        @note_number
      end

      # Sets the oscillator's frequency to the given MIDI note number, using
      # equal temperament.
      def number=(note_number)
        self.frequency = Oscillator.calc_freq(note_number)
        @note_number = note_number
      end

      # Restarts the oscillator at the given note number and velocity.
      def trigger(note_number, velocity)
        reset
        self.number = note_number
        amplitude = MB::M.scale(velocity, 0..127, -30..-6).db
        self.range = -amplitude..amplitude
      end

      # Stops the oscillator at the given release velocity (which may be
      # ignored), if its note number matches the given note number.
      def release(note_number, velocity)
        if note_number == @note_number || (note_number.round == @note_number.round rescue nil)
          self.range = 0..0
        end
      end

      # Returns the value of the oscillator for a given phase between 0 and
      # 2pi.  The output value ranges from -1 to 1.  The power, range, and
      # other modifiers to the oscillator are not applied by this method (see
      # #sample).
      def oscillator_ruby(phi)
        case @wave_type
        when :sine
          s = Math.sin(phi)

        when :complex_sine
          s = CMath.exp(1i * (phi - Math::PI / 2))

        when :triangle
          if phi < 0.5 * Math::PI
            # Initial rise from 0..1 in 0..pi/2
            s = phi * 2.0 / Math::PI
          elsif phi < 1.5 * Math::PI
            # Fall from 1..-1 in pi/2..3pi/2
            s = 2.0 - phi * 2.0 / Math::PI
          else
            # Final rise from -1..0 in 3pi/2..2pi
            s = phi * 2.0 / Math::PI - 4.0
          end

        when :complex_triangle
          # The constant factor scales the triangle portion to a range of -1..1.
          # In Sage:
          #     f = integrate(-2*atanh(e^(i*x)), x)
          #     limit(f, x = 0)
          #     # -pi*log(2) + I*dilog(2)
          #
          # The -pi*log(2) cancels the real part of dilog(2) leaving:
          #     (-pi*log(2) + I*dilog(2)).n()
          #     # 2.46740110027234*I
          s = MB::M.csc_int_int(phi + Math::PI / 2) * 1i / 2.46740110027234

        when :square
          if phi < Math::PI
            s = 1.0
          else
            s = -1.0
          end

        when :complex_square
          # Note: to draw a rectangle in the polar view, the phase needs to be
          # shifted by one half sample.  This is done in #sample.
          s = 2.0 * MB::M.csc_int(phi).conj * 1i / Math::PI + 1.0
          unless s.finite?
            s = 2.0 * MB::M.csc_int(phi + 0.0000001).conj * 1i / Math::PI + 1.0
          end

          # Experimentally obtained clipping values to preserve approximate timbre
          s = Complex(s.real, -3.8) if s.imag < -3.8
          s = Complex(s.real, 3.8) if s.imag > 3.8

        when :ramp
          if phi < Math::PI
            # Initial rise from 0..1 in 0..pi
            s = phi / Math::PI
          else
            # Final rise from -1..0 in pi..2pi
            s = phi / Math::PI - 2.0
          end

        when :complex_ramp
          s = MB::M.cot_int(phi + Math::PI / 2) * 1i

          # Experimentally obtained clipping values to preserve approximate timbre
          s = Complex(s.real, -3.5) if s.imag < -3.5
          s = Complex(s.real, 3.5) if s.imag > 3.5

        when :gauss
          # Sideways Gaussian attempt 2
          # This has an approximately Gaussian distribution, but the crest
          # factor when generating noise is 16dB instead of the expected 14dB,
          # and the min and max do not go to infinity.
          #
          # TODO: see if there's a better way to calculate this same function
          x = phi / Math::PI
          if x < 1.0
            # 1.6487212707 is ~Math.sqrt(Math::E)
            s = (Math.sqrt(2 * Math.log(1.6487212707 / (1.0 - x))) - 1) * 0.7071067811865476
          else
            s = (-Math.sqrt(2 * Math.log(1.6487212707 / (x - 1.0))) + 1) * 0.7071067811865476
          end

          # Clamp range to prevent periodic clicks when we get infinity at phi=pi
          s = -3 if s < -3
          s = 3 if s > 3

        when :parabola
          if phi < Math::PI
            s = 1.0 - (1.0 - phi * 2.0 / Math::PI) ** 2
          else
            s = (phi * 2.0 / Math::PI - 3.0) ** 2 - 1.0
          end

        else
          raise "Invalid wave type #{@wave_type.inspect}"
        end

        s
      end

      def oscillator(phi)
        return MB::FastSound.osc(@wave_type, phi)
      end

      # Returns the next value (or +count+ values in an NArray, if specified)
      # of the oscillator and advances the internal phase.
      #
      # Note that future calls to this method may overwrite the buffer returned
      # by previous calls.
      def sample(count = nil)
        buf = sample_c(count)

        # TODO: Move all waveshaping into a separate class
        if @pre_power != 1.0
          buf = MB::M.safe_power(buf, @pre_power)
          buf = MB::M.clamp(buf * NEGATIVE_POWER_SCALE[@wave_type], -1.0, 1.0) if @pre_power < 0
          buf = MB::M.scale(buf, -1.0..1.0, @range) if @range
        end

        buf = MB::M.safe_power(buf, @post_power) if @post_power != 1.0

        buf
      end

      def sample_c(count = nil)
        return sample_c(1)[0] if count.nil?

        build_buffer(count)

        freq = @frequency
        freq = freq.sample(count) if freq.respond_to?(:sample)

        if @range && @pre_power == 1.0
          gain = (@range.last - @range.first) / 2.0
          offset = (@range.first + @range.last) / 2.0
        else
          gain = 1
          offset = 0
        end

        state = [@phi]

        buf = MB::FastSound.synthesize(
          @osc_buf.inplace!,
          wave_type,
          freq,
          advance,
          random_advance,
          gain,
          offset,
          state
        )

        @phi = state[0]

        buf.not_inplace!
      end

      def sample_ruby(count = nil)
        return sample_ruby(1)[0] if count.nil?

        build_buffer(count)

        count.times do |idx|
          # TODO: this doesn't modulate strongly enough
          # FM attempt:
          # fm = Oscillator.new(
          #   :sine,
          #   frequency: Oscillator.new(:sine, frequency: 220, range: -970..370, advance: Math::PI / 24000),
          #   advance: Math::PI / 24000
          # )
          freq = @frequency
          freq = freq.sample if freq.respond_to?(:sample)

          advance = @advance
          advance += RAND.rand(@random_advance.to_f) if @random_advance != 0
          delta = freq * advance

          # Compensate for sampling offset of some wave types
          # TODO: Find a way to move this wavetype-specific code out of this function
          case @wave_type
          when :complex_square, :complex_ramp
            result = oscillator(@phi + delta / 2)

          else
            result = oscillator(@phi)
          end

          @phi = (@phi + delta) % (Math::PI * 2)

          result = result.real unless @osc_buf[0].is_a?(Complex)
          @osc_buf[idx] = result
        end

        buf = @osc_buf
        buf = MB::M.scale(buf, -1.0..1.0, @range) if @range && @pre_power == 1.0
        buf
      end

      private

      def build_buffer(count)
        buf_class = BUFFER_CLASS[@wave_type] || Numo::SFloat
        if @osc_buf.nil? || @osc_buf.class != buf_class || @osc_buf.length != count
          @osc_buf = buf_class.zeros(count)
        end
      end
    end
  end
end
