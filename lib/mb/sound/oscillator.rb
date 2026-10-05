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
      include GraphNode::Ports

      port :wraps, Phasor.port_specs[:wraps]
      port :increment, Phasor.port_specs[:increment]

      RAND = ENV['RANDOM_SEED'] ? Random.new(Integer(ENV['RANDOM_SEED'])) : Random.new
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

      attr_accessor :pre_power, :post_power, :range
      attr_reader :wave_type

      # Changes the wave type (see WAVE_TYPES).
      def wave_type=(wave_type)
        @wave_type = wave_type
        @kernel = nil
      end
      attr_reader :frequency, :phase_mod

      # The Phasor that holds this oscillator's phase (in cycles).  The
      # oscillator samples its own frequency and phase modulation inputs and
      # runs the phasor and waveform in one C loop (#sample_c).
      attr_reader :phasor

      # The most recent true frequency on an FM-modulated (not PM-modulated)
      # oscillator.  Starts at zero before #sample is called
      attr_reader :last_freq

      # Whether ramp, square, and triangle waves are band-limited (see
      # BandLimit): true, false for the naive (aliased) waveforms, or a Range
      # of frequencies in Hz over which band-limiting fades in (see
      # BandLimit::LFO_FADE).  Other wave types are unaffected.
      attr_reader :band_limit

      # The phase warp width (see #width=), or nil for none.
      attr_reader :width

      # Whether a warped waveform's DC offset is removed (see #width=).
      attr_accessor :remove_dc

      # The sync pulse source (see #sync=), or nil.
      attr_reader :sync

      # Whether sync reverses the phase (soft sync) instead of resetting it.
      attr_accessor :soft_sync

      # The reset trigger input (see #reset_input=), or nil.
      attr_reader :reset_input

      # Where a reset trigger moves the phase (see #reset_to=): nil for the
      # starting phase, radians, or a graph node of radians.
      attr_reader :reset_to

      # The seed of the random phase generator (see #random_phase=), or nil.
      attr_reader :random_phase

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
      # +band_limit+ - See #band_limit (noise, with a +random_advance+, is never
      #                band-limited).  Off by default for this low-level class,
      #                which gives the exact shapes; Tone turns it on.
      # +width+ - See #width= (nil for no phase warp).
      # +remove_dc+ - Whether to remove a warped waveform's DC offset.
      # +sync+ - A sync pulse source (see #sync=), or nil.
      # +soft_sync+ - Whether sync reverses the phase instead of resetting it.
      #
      # TODO: it probably makes sense to move pre_power/post_power elsewhere if
      # possible, e.g. a new waveshaper node or something
      def initialize(wave_type, frequency: 1.0, phase: 0.0, phase_mod: nil, range: nil, pre_power: 1.0, post_power: 1.0, advance: Math::PI / 24000.0, random_advance: 0.0, band_limit: false, width: nil, remove_dc: true, sync: nil, soft_sync: false)
        unless WAVE_TYPES.include?(wave_type)
          raise "Invalid wave type #{wave_type.inspect}; only #{WAVE_TYPES.map(&:inspect).join(', ')} are supported"
        end
        @wave_type = wave_type

        self.frequency = frequency
        self.phase_mod = phase_mod

        raise "Invalid phase #{phase.inspect}" unless phase.is_a?(Numeric)
        raise "Invalid advance #{advance.inspect}" unless advance.is_a?(Numeric)
        raise "Invalid random advance #{random_advance.inspect}" unless random_advance.is_a?(Numeric)

        # The phasor's frequency is unused: #sample reads the frequency input
        # and hands it to the phasor's math directly.
        @phasor = Phasor.new(
          frequency: 0.0,
          phase: phase / TWOPI,
          advance: advance / TWOPI,
          random_advance: random_advance / TWOPI
        )

        raise "Invalid range #{range.inspect}" unless range.nil? || range.first.is_a?(Numeric)
        @range = range

        raise "Invalid pre_power #{pre_power.inspect}" unless pre_power.is_a?(Numeric)
        @pre_power = pre_power.to_f

        raise "Invalid post_power #{post_power.inspect}" unless post_power.is_a?(Numeric)
        @post_power = post_power.to_f


        self.band_limit = band_limit
        self.width = width
        @remove_dc = !!remove_dc
        @bl_state = [0.0, 0.0, 0.0, 0]
        @blit_state = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0]
        @pulse_state = [0.0, 0.0, 0]
        self.sync = sync
        @soft_sync = !!soft_sync

        @osc_buf = nil
        @truncated = false

        @last_freq = 0.0
      end

      # The sample rate of the oscillator (calculated from the phase advance
      # value given to the constructor).
      def sample_rate
        (1.0 / @phasor.advance).round(6)
      end

      # Changes the phase advance per sample to match the given +sample_rate+
      # (see the advance parameter to the constructor).
      def sample_rate=(sample_rate)
        @phasor.sample_rate = sample_rate
        self
      end
      alias at_rate sample_rate=

      # The phase advance per sample per Hz, in radians (see #initialize).
      def advance
        @phasor.advance * TWOPI
      end

      # Sets the phase advance per sample per Hz, in radians.
      def advance=(advance)
        @phasor.advance = advance / TWOPI
      end

      # The maximum random addition to the phase advance, in radians.
      def random_advance
        @phasor.random_advance * TWOPI
      end

      # Sets the maximum random addition to the phase advance, in radians.
      def random_advance=(random_advance)
        @kernel = nil
        @phasor.random_advance = random_advance / TWOPI
      end

      def sources
        {
          frequency: @frequency,
          phase: phase,
          phase_mod: @phase_mod,
          width: @width,
          sync: @sync,
          reset: @reset_input,
          reset_to: @reset_to.respond_to?(:sample) ? @reset_to : nil,
        }.compact
      end

      # The starting phase offset in radians (0 to 2pi).
      def phase
        @phasor.phase * TWOPI
      end

      # Changes the starting phase offset for this oscillator, shifting the
      # oscillator's current phase accordingly.
      def phase=(phase)
        @phasor.phase = phase / TWOPI
      end

      # The current phase in radians (0 to 2pi).
      def phi
        @phasor.phi * TWOPI
      end

      # Directly sets the current phase offset for this oscillator.  A
      # band-limited oscillator smooths the jump (see #reset).
      def phi=(phi)
        phase_jump { @phasor.phi = phi / TWOPI }
      end

      # Resets the oscillator phase to its starting phase (see #phase), e.g.
      # when a MIDI voice plays a note.  A band-limited oscillator turns the
      # jump into a band-limited step (minBLEP; see BandLimit.minblep_tables)
      # over the next samples, so a retrigger doesn't alias (the step itself
      # is still there, as a softer click).
      #
      # With a random phase (see #random_phase=) each reset goes to a new
      # random phase instead.
      def reset
        phase_jump { @phasor.phi = @phase_rng ? @phase_rng.rand : @phasor.phase }
      end

      # Sets a reset trigger input: a graph node whose every nonzero sample
      # (any value) moves the phase to #reset_to at that sample, or nil to
      # remove it.  The jump is band-limited like #reset (a 32-sample minBLEP
      # step, including phase modulation at that sample), and works with
      # frequency and phase modulation, but not with #sync.  Buffers with
      # resets are computed in pieces split at the reset samples; buffers
      # without resets cost one scan of the trigger buffer.  A reset input
      # that ends (returns nil) means no more resets, not the end of the
      # oscillator, so e.g. a key-synced clip tone keeps playing through an
      # envelope's release after its clip's trigger has ended.
      def reset_input=(trigger)
        unless trigger.nil? || trigger.respond_to?(:sample)
          raise ArgumentError, "Reset input must be nil or a graph node of triggers (got #{trigger.inspect})"
        end
        raise ArgumentError, 'A synced oscillator cannot also have a reset input' if trigger && @sync

        @reset_input = trigger.respond_to?(:get_sampler) ? trigger.get_sampler : trigger
        @reset_ended = false
      end

      # Sets where the reset input (see #reset_input=) moves the phase: nil
      # for the starting phase (see #phase), a phase in radians (like
      # #phi=), or a graph node of radians read at each reset sample.
      # Ignored while #random_phase is set.
      def reset_to=(to)
        unless to.nil? || to.is_a?(Numeric) || to.respond_to?(:sample)
          raise ArgumentError, "Reset target must be nil, radians, or a graph node of radians (got #{to.inspect})"
        end

        @reset_to = to.respond_to?(:get_sampler) ? to.get_sampler : to
      end

      # Gives this oscillator a random phase from a Random seeded with +seed+
      # (an Integer; see MB::Sound.next_seed), or removes it with nil.  The
      # starting phase (see #phase) becomes random right away, and every
      # reset (#reset or the reset input) goes to a new random phase.
      def random_phase=(seed)
        if seed.nil?
          @random_phase = nil
          @phase_rng = nil
        else
          @random_phase = Integer(seed)
          @phase_rng = Random.new(@random_phase)
          self.phase = @phase_rng.rand * TWOPI
        end
      end


      # Moves the phase to +cycles+ past the starting phase (e.g. to lock a
      # tempo LFO to the timeline; see Sequence::TempoNode), smoothing the
      # jump like #reset.
      def sync_cycles(cycles)
        phase_jump { @phasor.sync(cycles) }
        self
      end

      # Sets a sync input: a graph node of sync pulses (see
      # Phasor.sync_pulses; e.g. another oscillator's #wraps port), or nil.
      # Each pulse resets the phase to zero (hard sync), or reverses its
      # direction with #soft_sync, at the pulse's sub-sample time.  Synced
      # oscillators are band-limited with minBLEP (FastSynth.oscillate_sync)
      # when #band_limit is on, and can't also have phase modulation.  Only
      # ramp, square, triangle, sine, and parabola can be synced.
      def sync=(source)
        @kernel = nil
        unless source.nil? || source.respond_to?(:sample)
          raise ArgumentError, "Sync must be nil or a graph node of sync pulses (got #{source.inspect})"
        end
        raise ArgumentError, 'An oscillator with a reset input cannot also be synced' if source && @reset_input

        @sync = source.respond_to?(:get_sampler) ? source.get_sampler : source
        @sync_state = [@phasor.phi, 0.0, 1.0, 0, 0]
        @sync_ring = Numo::DFloat.zeros(BandLimit::SYNC_TAPS)
      end

      # Sets whether ramp, square, and triangle waves are band-limited (see
      # #band_limit).
      def band_limit=(band_limit)
        @kernel = nil
        unless band_limit == true || band_limit == false || band_limit.nil? || (band_limit.is_a?(Range) && band_limit.begin.is_a?(Numeric))
          raise ArgumentError, "Band limit must be true, false, or a Range of Hz (got #{band_limit.inspect})"
        end
        @band_limit = band_limit || false
      end

      # Sets the phase warp width (pulse width modulation for every shape,
      # see BandLimit): a Numeric or a graph node from 0 to 1 (clamped to
      # BandLimit::MIN_WIDTH..(1 - MIN_WIDTH)), or nil for no warp.  The
      # first half of the waveform plays over +width+ of each cycle and the
      # second half over the rest, so a square becomes a pulse (25% high at
      # 0.25), a triangle a skewed triangle, and a sine an asymmetric sine.
      # Only ramp, square, triangle, sine, and parabola can be warped.
      def width=(width)
        @kernel = nil
        unless width.nil? || width.is_a?(Numeric) || width.respond_to?(:sample)
          raise ArgumentError, "Width must be nil, a Numeric, or a graph node (got #{width.inspect})"
        end

        width = width.get_sampler if width.respond_to?(:get_sampler)
        @width = width
      end

      # True if this oscillator's samples are band-limited right now.
      def band_limited?
        !!@band_limit && @phasor.random_advance == 0 &&
          (BandLimit::WAVES.include?(@wave_type) || (warped? && BandLimit::WARP_WAVES.include?(@wave_type)))
      end

      # True if this oscillator has a phase warp (see #width=).
      def warped?
        !@width.nil?
      end

      # True if this complex oscillator is band-limited right now (see
      # BandLimit.blit_ruby): complex ramp, square, and triangle with
      # band-limiting on, without phase modulation, noise, or a warp (those
      # fall back to the naive complex waves).
      def blit?
        !!@band_limit && BandLimit::COMPLEX_WAVES.include?(@wave_type) && @phasor.random_advance == 0 &&
          !warped? && (@phase_mod.nil? || @phase_mod == 0)
      end

      # Changes the oscillator's frequency source to the given Numeric value or
      # signal graph (responding to :sample).
      def frequency=(frequency)
        raise "Invalid frequency #{frequency.inspect}" unless frequency.is_a?(Numeric) || frequency.respond_to?(:sample) || frequency.respond_to?(:get_sampler)

        frequency = frequency.get_sampler if frequency.respond_to?(:get_sampler)

        @frequency = frequency
      end

      # Sets a phase modulation source.  Frequency modulation is added to the
      # frequency before calculating phase-per-sample, while phase modulation
      # is added directly to the phase value passed into #oscillator.
      def phase_mod=(pm)
        @kernel = nil
        unless pm.nil? || pm.is_a?(Numeric) || pm.respond_to?(:sample) || pm.respond_to?(:get_sampler)
          raise "Phase modulation source must be nil, a Numeric, or respond to :sample"
        end

        pm = pm.get_sampler if pm.respond_to?(:get_sampler)

        @phase_mod = pm
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
        return sample_c(count) if count.nil? || @ports.nil?

        port_frame(count) { sample_main(count) }
      end

      # Oscillator implementation in C.
      def sample_c(count = nil)
        return sample_c(1)[0] if count.nil?

        count, freq, phase, width, pulses, resets, targets = get_upstream_inputs(count)
        return nil if missing_input?(freq, phase, width, pulses, resets, targets)

        if @ports
          @frame_phi = @phasor.state[0]
          @frame_freq = freq
          @frame_segments = nil
        end

        build_buffer(count)
        gain, offset = gain_and_offset

        points = reset_points(resets)
        if points
          buf = sample_segments(count, freq, phase, width, gain, offset, points, targets) do |out, f, ph, w|
            kernel_c(out, f, ph, w, nil, gain, offset)
          end
        else
          buf = kernel_c(@osc_buf[0...count].inplace!, freq, phase, width, pulses, gain, offset)
          add_jump_residual(buf, gain) if @jump_residual
        end

        @last_freq = freq.is_a?(Numeric) ? freq : freq[-1]
        @last_width = width.is_a?(Numo::NArray) ? width[-1] : width

        buf = add_waveshape_and_range(buf)

        buf.not_inplace!
      end

      # Oscillator implementation in Ruby.
      def sample_ruby(count = nil)
        return sample_ruby(1)[0] if count.nil?

        count, freq_table, phase_table, width, pulses, resets, targets = get_upstream_inputs(count)
        return nil if missing_input?(freq_table, phase_table, width, pulses, resets, targets)

        build_buffer(count)
        gain, offset = gain_and_offset

        points = reset_points(resets)
        if points
          buf = sample_segments(count, freq_table, phase_table, width, gain, offset, points, targets) do |out, f, ph, w|
            kernel_ruby(out, f, ph, w, nil, gain, offset)
          end
        else
          buf = kernel_ruby(@osc_buf[0...count].inplace!, freq_table, phase_table, width, pulses, gain, offset)
          add_jump_residual(buf, gain)
        end

        @last_freq = freq_table.is_a?(Numeric) ? freq_table : freq_table[-1]
        @last_width = width.is_a?(Numo::NArray) ? width[-1] : width

        buf = add_waveshape_and_range(buf)
        buf.not_inplace!
      end

      # Wraps an NArray of radians to 0...2pi like Ruby's % (Numo's % keeps
      # the sign of negative values, like C's fmod).  Same as wrap() in
      # fast_sound.c.
      def self.wrap_radians(radians)
        radians - (radians / TWOPI).floor * TWOPI
      end

      # Returns +wave_type+ at +phases+ (cycles, a DFloat NArray) plus
      # +phase_mod+ (radians; Numeric or NArray), as a DFloat or DComplex
      # NArray.  +increments+ (cycles; Numeric or NArray) offset complex
      # square and ramp waves by half an increment.  Ruby version of
      # MB::FastSound.shape (fast_sound.c), vectorized with Numo where the
      # formula allows; see #value_at_ruby for the formulas.
      def self.shape_ruby(wave_type, phases, increments, phase_mod)
        radians = phases * TWOPI
        radians = radians + increments * Math::PI if wave_type == :complex_square || wave_type == :complex_ramp
        radians = radians + phase_mod if phase_mod

        case wave_type
        when :sine
          Numo::NMath.sin(radians)

        when :complex_sine
          # exp(i * (phi - pi / 2)) = sin(phi) - i * cos(phi)
          Numo::NMath.sin(radians) - Numo::NMath.cos(radians) * 1i

        when :triangle
          phi = Oscillator.wrap_radians(radians)
          s = phi * (2.0 / Math::PI)
          falling = phi.ge(0.5 * Math::PI) & phi.lt(1.5 * Math::PI)
          s[falling] = 2.0 - s[falling]
          s[phi.ge(1.5 * Math::PI)] -= 4.0
          s

        when :square
          phi = Oscillator.wrap_radians(radians)
          s = Numo::DFloat.ones(phi.length)
          s[phi.ge(Math::PI)] = -1.0
          s

        when :ramp
          phi = Oscillator.wrap_radians(radians)
          s = phi / Math::PI
          s[phi.ge(Math::PI)] -= 2.0
          s

        when :parabola
          t = Oscillator.wrap_radians(radians) * (2.0 / Math::PI)
          s = 1.0 - (1.0 - t)**2
          upper = t.ge(2.0)
          s[upper] = (t[upper] - 3.0)**2 - 1.0
          s

        when :gauss
          x = Oscillator.wrap_radians(radians) / Math::PI
          s = Numo::DFloat.zeros(x.length)
          lower = x.lt(1.0)
          upper = ~lower
          s[lower] = (Numo::NMath.sqrt(Numo::NMath.log(1.6487212707 / (1.0 - x[lower])) * 2) - 1) * 0.7071067811865476 if lower.count_true > 0
          s[upper] = (-Numo::NMath.sqrt(Numo::NMath.log(1.6487212707 / (x[upper] - 1.0)) * 2) + 1) * 0.7071067811865476 if upper.count_true > 0
          s.clip(-3, 3)

        when :complex_triangle, :complex_square, :complex_ramp
          # These use complex integrals per sample (see #value_at_ruby)
          osc = Oscillator.new(wave_type)
          Numo::DComplex.cast(radians.to_a.map { |phi| osc.value_at_ruby(phi) })

        else
          raise "Invalid wave type #{wave_type.inspect}"
        end
      end

      # The minBLEP and minBLAMP tables at whole-sample offsets (a jump
      # exactly between samples), for #phase_jump, made on first use.
      def self.jump_tables
        @jump_tables ||= begin
          blep, blamp = BandLimit.minblep_tables
          steps = Numo::DFloat.new(BandLimit::SYNC_TAPS).seq * BandLimit::SYNC_OVERSAMPLE
          [blep[steps].freeze, blamp[steps].freeze].freeze
        end
      end

      private

      # Runs the block, which jumps the phase, and for a band-limited
      # oscillator that has played, queues a band-limited step for the
      # following samples (see #reset).  The step is measured at frequency
      # +freq+, warp +width+, and phase modulation +phase_mod+ (radians):
      # by default those of the last sample played and no phase modulation
      # (a jump between buffers), or those of the reset sample (a reset
      # input; see #sample_segments).
      def phase_jump(freq: @last_freq, width: @last_width, phase_mod: 0.0)
        before = @phasor.state[0]
        played = freq != 0.0 && (@bl_state[3] != 0 || @blit_state[6] != 0)
        yield
        after = @phasor.state[0]
        unprime

        return unless played && !@sync && synth_kernel? && !blit?

        w = BandLimit.clamp_width((width || 0.5).to_f)
        pm = phase_mod / TWOPI
        v0, s0 = BandLimit.sync_shape(@wave_type, w, pm == 0 ? before : BandLimit.wrap(before + pm))
        v1, s1 = BandLimit.sync_shape(@wave_type, w, pm == 0 ? after : BandLimit.wrap(after + pm))
        inc = freq * @phasor.advance
        k = @band_limit.is_a?(Range) ? BandLimit.fade(inc.abs / @phasor.advance, @band_limit.begin.to_f, @band_limit.end.to_f) : 1.0
        k = 0.0 unless band_limited?
        return if k == 0

        blep, blamp = Oscillator.jump_tables
        residual = (blep * (v1 - v0) + blamp * ((s1 - s0) * inc)) * k
        @jump_residual = @jump_residual ? residual + pad_residual(@jump_residual, residual.length) : residual
      end

      def pad_residual(r, length)
        return r[0...length] if r.length >= length

        Numo::DFloat.zeros(length).tap { |z| z[0...r.length] = r }
      end

      # Adds any queued phase jump step (see #phase_jump) to +buf+, scaled
      # by the output +gain+.
      def add_jump_residual(buf, gain)
        return unless @jump_residual

        n = [buf.length, @jump_residual.length].min
        buf[0...n] += @jump_residual[0...n] * gain
        @jump_residual = n < @jump_residual.length ? @jump_residual[n..].dup : nil
      end

      # Clears band-limiting history after a phase jump.
      def unprime
        @bl_state[3] = 0
        @blit_state[6] = 0
        if @sync
          @sync_state = [@phasor.phi, 0.0, 1.0, 0, 0]
          @sync_ring.fill(0)
        end
      end

      # Output gain and offset for the kernels from #range (see #sample_c).
      def gain_and_offset
        if @range && @pre_power == 1.0
          [(@range.last - @range.first) / 2.0, (@range.first + @range.last) / 2.0]
        else
          [1, 0]
        end
      end

      # True if an input needed for the next samples has ended.
      def missing_input?(freq, phase, width, pulses, resets, targets)
        freq.nil? || phase.nil? || (warped? && width.nil?) || (@sync && pulses.nil?) ||
          (@reset_to.respond_to?(:sample) && targets.nil?)
      end

      # The indices of the nonzero samples of the reset input's buffer
      # +resets+ as an Array, or nil if there are none (or no reset input).
      #
      # A frozen buffer already found to be all zeros (e.g. the constant
      # buffer of a Notes trigger without note-ons) isn't scanned again.
      def reset_points(resets)
        return nil if resets.nil?
        return nil if resets.equal?(@quiet_resets)

        unless resets.is_a?(Numo::SComplex) || resets.is_a?(Numo::DComplex)
          min, max = resets.minmax
          if min == 0 && max == 0 # cheaper than ne(0).where
            @quiet_resets = resets if resets.frozen?
            return nil
          end
        end

        resets = resets.ne(0).where
        resets.empty? ? nil : resets.to_a
      end

      # Computes +count+ samples split into pieces at the reset sample
      # indices in +points+ (see #reset_input=), jumping the phase before
      # each reset sample.  The block runs a kernel (#kernel_c or
      # #kernel_ruby) on a view of the output buffer with the matching
      # slices of the frequency, phase modulation, and width inputs, and
      # returns the samples.  Returns a view of the output buffer.
      def sample_segments(count, freq, phase, width, gain, offset, points, targets)
        @frame_segments = [] if @ports

        start = 0
        (points + [count]).each do |stop|
          if stop > start
            f = slice_input(freq, start, stop)
            @frame_segments&.push([@phasor.state[0], f, stop - start])

            out = @osc_buf[start...stop].inplace!
            result = yield(out, f, slice_input(phase, start, stop), slice_input(width, start, stop))
            out[true] = result unless result.equal?(out)
            add_jump_residual(out, gain)
          end

          break if stop == count

          target = reset_target(targets, stop)
          phase_jump(freq: input_at(freq, stop), width: width && input_at(width, stop), phase_mod: input_at(phase, stop)) do
            @phasor.phi = target
          end

          start = stop
        end

        @osc_buf[0...count].inplace!
      end

      # The phase in cycles for a reset at sample +i+ (see #reset_to=).
      def reset_target(targets, i)
        return @phase_rng.rand if @phase_rng
        return input_at(targets, i) / TWOPI if targets
        return @reset_to / TWOPI if @reset_to

        @phasor.phase
      end

      # Sample +i+ of a kernel input (Numeric or NArray) as a real Float.
      def input_at(input, i)
        v = input.is_a?(Numo::NArray) ? input[i] : (input || 0)
        v = v.real if v.is_a?(Complex)
        v.to_f
      end

      # Samples +start+...+stop+ of a kernel input (Numeric, NArray, or nil).
      def slice_input(input, start, stop)
        input.is_a?(Numo::NArray) ? input[start...stop] : input
      end

      # Runs the C kernel for the current settings (see #kernel) into +out+
      # (an inplace view of the output buffer), returning the samples.
      def kernel_c(out, freq, phase, width, pulses, gain, offset)
        case kernel
        when :sync
          check_sync(phase)
          blep, blamp = BandLimit.minblep_tables
          buf = MB::Sound::FastSynth.oscillate_sync(
            out, wave_type, freq, @phasor.advance, gain, offset,
            @sync_state, @sync_ring, pulses, @soft_sync, width, @remove_dc,
            blep, blamp, BandLimit::SYNC_OVERSAMPLE, BandLimit::SYNC_TAPS, !!@band_limit
          ).inplace!
          @phasor.state[0] = @sync_state[0]
          buf
        when :blit
          MB::Sound::FastSynth.blit(
            out, wave_type, freq, @phasor.advance, gain, offset, @phasor.state, @blit_state
          ).inplace!
        when :synth
          MB::Sound::FastSynth.oscillate_bl(
            out, wave_type, freq, phase, @phasor.advance, gain, offset,
            @phasor.state, @bl_state, *band_limit_fade, width, @remove_dc
          ).inplace!
        else
          MB::FastSound.oscillate(
            out, wave_type, freq, phase, @phasor.advance, @phasor.random_advance, gain, offset, @phasor.state
          ).inplace!
        end
      end

      # Ruby mirror of #kernel_c: computes out.length samples and stores
      # them in +out+ (an inplace view of the output buffer), returning it.
      def kernel_ruby(out, freq_table, phase_table, width, pulses, gain, offset)
        count = out.length

        if @sync
          check_sync(phase_table)
          blep, blamp = BandLimit.minblep_tables
          values = BandLimit.sync_ruby(
            count, @wave_type, freq_table, @phasor.advance, gain, offset,
            @sync_state, @sync_ring, pulses, @soft_sync, width, @remove_dc,
            blep, blamp, BandLimit::SYNC_OVERSAMPLE, BandLimit::SYNC_TAPS, !!@band_limit
          )
          @phasor.state[0] = @sync_state[0]
        elsif blit?
          values = BandLimit.blit_ruby(count, @wave_type, freq_table, @phasor.advance, gain, offset, @phasor.state, @blit_state)
        elsif synth_kernel?
          values = BandLimit.oscillate_ruby(
            count, @wave_type, freq_table, phase_table, @phasor.advance, gain, offset,
            @phasor.state, @bl_state, *band_limit_fade, width, @remove_dc
          )
        else
          phases, increments = @phasor.phases_ruby(freq_table, count)
          values = Oscillator.shape_ruby(@wave_type, phases, increments, phase_table) * gain + offset
        end

        values = values.real if !out.is_a?(Numo::SComplex) && values.is_a?(Numo::DComplex)
        out[true] = values
        out
      end

      def check_sync(phase_mod)
        unless BandLimit::WARP_WAVES.include?(@wave_type)
          raise ArgumentError, "A #{@wave_type} can't be synced (only #{BandLimit::WARP_WAVES.join(', ')})"
        end
        raise ArgumentError, 'A synced oscillator cannot also have phase modulation' unless phase_mod == 0 || phase_mod.nil?
      end

      # Which kernel computes samples: :sync, :blit, :synth (FastSynth
      # band-limited or warped), or :naive (FastSound), cached until a
      # setting changes.
      def kernel
        @kernel ||= if @sync
                      :sync
                    elsif blit?
                      :blit
                    elsif synth_kernel?
                      :synth
                    else
                      :naive
                    end
      end

      # The main output for GraphNode::Ports.
      def sample_main(count)
        sample_c(count)
      end

      # Port data from the phases of the frame just computed (the phasor's
      # phase, without phase modulation; see Phasor.sync_pulses).
      def compute_ports(count)
        if @frame_segments
          # Resets split the frame into pieces (see #sample_segments)
          parts = @frame_segments.map { |phi, freq, n| Phasor.sync_pulses(phi, freq, @phasor.advance, n, @pulse_state) }
          pulses = parts[0][0].concatenate(*parts[1..].map(&:first))
          increments = parts[0][1].concatenate(*parts[1..].map(&:last))
        else
          pulses, increments = Phasor.sync_pulses(@frame_phi, @frame_freq, @phasor.advance, count, @pulse_state)
        end
        store_port(:wraps, pulses)
        store_port(:increment, increments)
      end

      # [low, high] frequencies (Hz) for fading band-limiting in, or [0, 0]
      # for always on.
      def band_limit_fade
        return BandLimit::NEVER unless band_limited?
        return ALWAYS unless @band_limit.is_a?(Range)

        @fade_band = [@band_limit.begin.to_f, @band_limit.end.to_f].freeze unless @fade_band&.first == @band_limit.begin.to_f && @fade_band.last == @band_limit.end.to_f
        @fade_band
      end

      # The fade band for band-limiting that is always on.
      ALWAYS = [0.0, 0.0].freeze

      # True if samples come from the band-limiting kernel (band-limited or
      # warped waveforms).
      def synth_kernel?
        band_limited? || (warped? && BandLimit::WARP_WAVES.include?(@wave_type) && @phasor.random_advance == 0)
      end

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

        width = @width
        if width.respond_to?(:sample)
          width = width.sample(count)
          width = nil if width&.empty?
          min_length = width.length if width && width.length < min_length
        end

        pulses = @sync
        if pulses.respond_to?(:sample)
          pulses = pulses.sample(count)
          pulses = nil if pulses&.empty?
          min_length = pulses.length if pulses && pulses.length < min_length
        end

        resets = @reset_ended ? nil : @reset_input
        if resets
          resets = resets.sample(count)
          resets = nil if resets&.empty?
          @reset_ended = true if resets.nil?
          min_length = resets.length if resets && resets.length < min_length
        end

        targets = @reset_to
        if targets.respond_to?(:sample)
          targets = targets.sample(count)
          targets = nil if targets&.empty?
          min_length = targets.length if targets && targets.length < min_length
        else
          targets = nil
        end

        if min_length != count
          # TODO: this double truncation might be impossible now that we use get_sampler
          raise "Truncation happened more than once on oscillator #{self} (try adding .with_buffer to upstreams)" if @truncated
          @truncated = true
          freq = freq[0...min_length] if freq&.is_a?(Numo::NArray)
          phase = phase[0...min_length] if phase&.is_a?(Numo::NArray)
          width = width[0...min_length] if width&.is_a?(Numo::NArray)
          pulses = pulses[0...min_length] if pulses&.is_a?(Numo::NArray)
          resets = resets[0...min_length] if resets&.is_a?(Numo::NArray)
          targets = targets[0...min_length] if targets&.is_a?(Numo::NArray)
        end

        return min_length, freq, phase, width, pulses, resets, targets
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
