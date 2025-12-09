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
      include GraphNode

      RAND = Random.new
      TWOPI = Math::PI * 2.0

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
      #
      # This can be applied to a Numeric or to a GraphNode.
      def self.calc_freq(note_number, detune_cents = 0)
        tune_freq * 2 ** ((note_number + detune_cents / 100.0 - tune_note) / 12.0)
      end

      # Calculates a fractional MIDI note number for the given frequency,
      # assuming equal temperament.
      #
      # This can be applied to a Numeric or to a GraphNode.
      def self.calc_number(frequency_hz)
        # FIXME: add .real to complex-valued upstream nodes if needed (e.g. a complex_sine oscillator)
        frequency_hz = frequency_hz.real if frequency_hz.is_a?(Complex)
        frequency_hz = 0 if frequency_hz.is_a?(Numeric) && frequency_hz < 0

        if frequency_hz.respond_to?(:sample)
          12.0 * (frequency_hz / tune_freq).log2 + tune_note
        else
          12.0 * Math.log2(frequency_hz / tune_freq) + tune_note
        end
      end

      attr_accessor :wave_type, :pre_power, :post_power, :range, :advance, :random_advance
      attr_reader :phi, :phase, :frequency, :phase_mod

      # An informational marker for classes like MB::Sound::MIDI::GraphVoice
      # indicating that the oscillator should not be reset when a note is
      # played.  Has no effect within the oscillator itself.
      attr_accessor :no_trigger

      # TODO: maybe use a clock provider instead of +advance+?  The challenge is
      # that floating point accuracy goes down as a shared clock advances, and
      # every oscillator needs its own internal phase if the phase is to be kept
      # within 0..2pi.  Maybe also separate the oscillator from the phase
      # counter?
      # TODO: maybe pass sample rate instead and have the oscillator calculate
      # its own phase advance value

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
      #
      # TODO: it probably makes sense to move pre_power/post_power elsewhere if
      # possible, e.g. a new waveshaper node or something
      def initialize(wave_type, frequency: 1.0, phase: 0.0, phase_mod: nil, range: nil, pre_power: 1.0, post_power: 1.0, advance: Math::PI / 24000.0, random_advance: 0.0, no_trigger: false)
        unless WAVE_TYPES.include?(wave_type)
          raise "Invalid wave type #{wave_type.inspect}; only #{WAVE_TYPES.map(&:inspect).join(', ')} are supported"
        end
        @wave_type = wave_type

        self.frequency = frequency
        self.phase_mod = phase_mod

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

        @no_trigger = !!no_trigger

        @osc_buf = nil
        @truncated = false
      end

      # The sample rate of the oscillator (calculated from the phase advance
      # value given to the constructor).
      def sample_rate
        (2.0 * Math::PI / @advance).round(6)
      end

      # Changes the phase advance per sample to match the given +sample_rate+
      # (see the advance parameter to the constructor).
      def sample_rate=(sample_rate)
        @advance = 2 * Math::PI / sample_rate
        self
      end
      alias at_rate sample_rate=

      def sources
        {
          frequency: @frequency,
          phase: @phase,
          phase_mod: @phase_mod,
        }.compact
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

      # Changes the oscillator's frequency source to the given Numeric value or
      # signal graph (responding to :sample).
      def frequency=(frequency)
        raise "Invalid frequency #{frequency.inspect}" unless frequency.is_a?(Numeric) || frequency.respond_to?(:sample) || frequency.respond_to?(:get_sampler)

        frequency = frequency.get_sampler if frequency.respond_to?(:get_sampler)

        @frequency = frequency
        @note_number = frequency.respond_to?(:sample) ? nil : Oscillator.calc_number(frequency)
      end

      # Sets a phase modulation source.  Frequency modulation is added to the
      # frequency before calculating phase-per-sample, while phase modulation
      # is added directly to the phase value passed into #oscillator.
      def phase_mod=(pm)
        unless pm.nil? || pm.is_a?(Numeric) || pm.respond_to?(:sample) || pm.respond_to?(:get_sampler)
          raise "Phase modulation source must be nil, a Numeric, or respond to :sample"
        end

        pm = pm.get_sampler if pm.respond_to?(:get_sampler)

        @phase_mod = pm
      end

      # Returns an approximate MIDI note number for the oscillators frequency,
      # assuming equal temperament.  This value may be fractional, and may be
      # outside of the MIDI range of 0..127.
      def number
        raise 'Cannot calculate a note number for a variable oscillator' if @frequency.respond_to?(:sample)
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
      def value_at_ruby(phi)
        case @wave_type
        when :sine
          s = Math.sin(phi)

        when :complex_sine
          s = CMath.exp(1i * (phi - Math::PI / 2))

        when :triangle
          phi %= TWOPI

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
          phi %= TWOPI

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
          phi %= TWOPI

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
          phi %= TWOPI

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
          phi %= TWOPI

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

      # Returns the instantaneous value of the oscillator at the given phase
      # value +phi+ (C implementation).
      def value_at_c(phi)
        return MB::FastSound.osc(@wave_type, phi)
      end

      # Returns the instantaneous value of the oscillator at the given phase
      # value +phi+.
      def value_at(phi)
        value_at_c(phi)
      end

      # Returns the next value (or +count+ values in an NArray, if specified)
      # of the oscillator and advances the internal phase.
      #
      # Note that future calls to this method may overwrite the buffer returned
      # by previous calls.
      def sample(count = nil)
        sample_c(count)
      end

      # Oscillator implementation in C.
      def sample_c(count = nil)
        return sample_c(1)[0] if count.nil?

        count, freq, phase = get_upstream_inputs(count)
        return nil if freq.nil? || phase.nil?

        build_buffer(count)

        if @range && @pre_power == 1.0
          gain = (@range.last - @range.first) / 2.0
          offset = (@range.first + @range.last) / 2.0
        else
          gain = 1
          offset = 0
        end

        state = [@phi]

        buf = MB::FastSound.synthesize(
          @osc_buf[0...count].inplace!,
          wave_type,
          freq,
          phase,
          advance,
          random_advance,
          gain,
          offset,
          state
        ).inplace!

        @phi = state[0]

        buf = add_waveshape_and_range(buf)

        buf.not_inplace!
      end

      # Oscillator implementation in Ruby.
      def sample_ruby(count = nil)
        return sample_ruby(1)[0] if count.nil?

        count, freq_table, phase_table = get_upstream_inputs(count)
        return nil if freq_table.nil? || phase_table.nil?

        build_buffer(count)

        if @range && @pre_power == 1.0
          gain = (@range.last - @range.first) / 2.0
          offset = (@range.first + @range.last) / 2.0
        else
          gain = 1
          offset = 0
        end

        count.times do |idx|
          freq = freq_table.is_a?(Numeric) ? freq_table : freq_table[idx]
          phase = phase_table.is_a?(Numeric) ? phase_table : phase_table[idx]

          advance = @advance
          advance += RAND.rand(@random_advance.to_f) if @random_advance != 0
          delta = freq * advance

          # Compensate for sampling offset of some wave types
          # TODO: Find a way to move this wavetype-specific code out of this
          # function, e.g into #value_at*
          case @wave_type
          when :complex_square, :complex_ramp
            result = value_at_ruby(@phi + delta / 2) * gain + offset

          else
            result = value_at_ruby(@phi) * gain + offset
          end

          @phi = (@phi + delta) % (Math::PI * 2)

          result = result.real unless @osc_buf[0].is_a?(Complex)
          @osc_buf[idx] = result
        end

        buf = @osc_buf[0...count].inplace!
        buf = add_waveshape_and_range(buf)
        buf
      end

      private

      # TODO: use BufferHelper?
      def build_buffer(count)
        buf_class = BUFFER_CLASS[@wave_type] || Numo::SFloat
        if @osc_buf.nil? || @osc_buf.class != buf_class || @osc_buf.length != count
          old_length = @osc_buf&.length || 0
          @osc_buf = buf_class.zeros(MB::M.max(count, old_length))
        end
      end

      # This retrieves the upstream frequency and phase modulation buffers,
      # finds whichever is shortest, truncates to that length, and returns the
      # new count and buffers.
      #
      # Used by #sample
      #
      # Raises an error if truncation happens more than once.
      #
      # TODO: a lot of classes need this input truncation; it might make sense
      # to build a shared API around the concept of multiple inputs.  There is
      # similar code in MB::Sound::GraphNode::ArithmeticNodeHelper.
      def get_upstream_inputs(count)
        min_length = count

        freq = @frequency
        if freq.respond_to?(:sample)
          freq = freq.sample(count)
          freq = nil if freq&.empty?
          min_length = freq.length if freq && freq.length < min_length
        end

        phase = @phase_mod || 0
        if phase.respond_to?(:sample)
          phase = phase.sample(count)
          phase = nil if phase&.empty?
          min_length = phase.length if phase && phase.length < min_length
        end

        if min_length != count
          # TODO: this double truncation might be impossible now that we use get_sampler
          raise "Truncation happened more than once on oscillator #{self} (try adding .with_buffer to upstreams)" if @truncated
          @truncated = true
          freq = freq[0...min_length] if freq&.is_a?(Numo::NArray)
          phase = phase[0...min_length] if phase&.is_a?(Numo::NArray)
        end

        return min_length, freq, phase
      end

      # Applies pre- and post-power waveshaping to the buffer.
      def add_waveshape_and_range(buf)
        # TODO: Move all waveshaping into a separate class
        if @pre_power != 1.0
          buf = MB::M.safe_power(buf, @pre_power)
          buf = MB::M.clamp(buf * NEGATIVE_POWER_SCALE[@wave_type], -1.0, 1.0) if @pre_power < 0
          buf = MB::M.scale(buf, -1.0..1.0, @range) if @range
        end

        buf = MB::M.safe_power(buf, @post_power) if @post_power != 1.0

        buf
      end
    end
  end
end
