module MB
  module Sound
    # An oscillator: a graph node that generates a waveform at a frequency
    # (Hz, or a node), with optional phase modulation, phase warp (pulse
    # width), hard or soft sync, reset inputs, and band-limiting.  It is also
    # the oscillator DSL: methods like #ramp, #at, #fm, #pm, #lfo, #pwm,
    # #sync, #reset, and #rnd configure it before it plays and return self,
    # so a tone is built by chaining:
    #
    #     play 440.hz.saw.at(0.3).fm(110.hz.at(200))
    #
    # Usually made from a Pitch (`440.hz`, `C4`, `1.beat.hz`, `v.hz` in a
    # synth voice; see Pitch, Note, Notes::NotePitch), or as `Tone.new` /
    # `Tone[frequency]`.
    #
    # A tone is configured before it plays; values that change while it
    # plays come from its inputs (frequency, phase modulation, width, sync,
    # reset, and reset target nodes; use a Constant or any node for a value
    # that changes).  Configuration calls after the first sample raise a
    # FrozenError.  #sample_rate= (e.g. from Session#add or #oversample)
    # works at any time.
    #
    # Everything that changes from sample to sample is in #state (a
    # Tone::State: the phase in cycles, band-limiting history, the queued
    # phase-jump step, the random phase generator, ...), so the node
    # itself only holds configuration and caches.
    #
    # == Waveforms
    #
    # Shapes are WAVE_TYPES (see #sine, #ramp, ...).  Ramp, square, and
    # triangle are band-limited by default (PolyBLEP/PolyBLAMP; see
    # BandLimit) and have naive (aliased) twins (#aramp, #asquare,
    # #atriangle); complex ramp, square, and triangle are closed-form
    # band-limited impulse trains (BLIT) with naive twins.  A #phasor tone
    # outputs its phase in cycles (0...1) instead of a shape, e.g. for
    # wavetables and as a sync master.
    #
    # == Per-sample math as plan-layer ops
    #
    # Each buffer runs these steps (the shape planned for fused plans; see
    # the plan-layer notes), each a C kernel with an exact Ruby mirror
    # (#sample_c and #sample_ruby):
    #
    # 1. Inputs: read +count+ samples of each input node (frequency, phase
    #    modulation, width, sync pulses, reset triggers, reset targets, and
    #    a tempo tone's timeline jumps and jump phases); numbers are
    #    constants.  A plan would read them from registers.
    # 2. SPLIT (control): nonzero reset triggers and timeline jumps split the
    #    buffer into segments; before each such sample the phase jumps (a
    #    JUMP to the reset target, or to the starting phase plus the jump
    #    phase).  Buffers without them are one segment (one scan of the
    #    triggers; shared frozen zero buffers are recognized without one).
    #    A plan would run quiet buffers fused and hand split buffers to the
    #    node, or port the split as an op.
    # 3. PHASE: inc[i] = freq[i] * advance (+ random * random_advance for
    #    noise); phase[i] = wrap(phase0 + sum(inc[0...i])) in cycles, double
    #    precision; state.phase[0] is phase0 and becomes the next phase.
    # 4. SHAPE (fused with PHASE in each kernel): one of
    #    - naive: shape(wave, phase[i] + pm[i]) (FastSound.oscillate);
    #    - band-limited: the naive shape plus PolyBLEP/BLAMP corrections at
    #      edges of the warped, modulated phase, with state.blep carrying
    #      the previous sample (FastSynth.oscillate_bl);
    #    - BLIT: integrated complex impulse trains, state.blit carrying the
    #      integrators (FastSynth.blit);
    #    - SYNC: phase driven by sync pulses with minBLEP/minBLAMP events in
    #      state.sync and state.sync_ring (FastSynth.oscillate_sync); also
    #      #clean band-limited tones with resets or a timeline (reset_sync?), whose
    #      jumps are hard sync events to the target phase;
    #    - PHASOR: the phase itself (FastSound.phasor);
    #    - FEEDBACK: a sine whose phase adds feedback * the average of its
    #      last two outputs, times an in-loop gain (FastSynth.feedback_sine,
    #      state.feedback; see #feedback): a per-sample recurrence, so a
    #      fused plan keeps it as one sequential op.
    # 5. GAIN (fused into the kernel): y = v * gain + offset, from #at;
    #    then (after the JUMP residual) y *= the #gain input, if any
    #    (FastArithmetic.scale on the output buffer, the same samples as a
    #    following Multiplier).
    # 6. JUMP: a phase jump (reset input, timeline lock) of a #clean tone on
    #    the SYNC kernel (reset_sync?) is a sync event on its sample; for
    #    other band-limited tones (the default) it
    #    queues a minBLEP/minBLAMP step from the old waveform to the new
    #    (state.jump_residual), with its area set to that of an ideal step
    #    on the sample (see .jump_residual), so audio-rate resets don't
    #    drift; queued steps are added as y += r * gain.
    # 7. PORTS (when used): wraps/increment from the frame's phases
    #    (BandLimit.sync_pulses with state.pulses).
    #
    # == Ports
    #
    # #wraps gives sync pulses (see BandLimit.sync_pulses) and #increment
    # the phase increment of each sample in cycles (see GraphNode::Ports).
    class Tone
      include GraphNode
      include GraphNode::SampleRateHelper
      include GraphNode::Ports

      port :wraps, 'Sync pulses: 0 except just after the phase wraps, where the value 1 - d (0 < 1 - d <= 1) says the wrap was d samples earlier; negative when moving backward; 1 after a jump (reset or sync)'
      port :increment, 'The phase increment of each sample, in cycles'

      TWOPI = Math::PI * 2.0

      # The splitmix64 generator for noise (see #noise and noise_random).
      NOISE_GAMMA = 0x9E3779B97F4A7C15
      NOISE_MIX1 = 0xBF58476D1CE4E5B9
      NOISE_MIX2 = 0x94D049BB133111EB
      MASK64 = (1 << 64) - 1

      # Ruby mirror of noise_random() in fast_sound.c: advances the
      # splitmix64 state in +rng+ (an Array of one Integer; see
      # State#noise) and returns a uniform Float in 0...1 (53 bits).
      def self.noise_random(rng)
        z = rng[0] = (rng[0] + NOISE_GAMMA) & MASK64
        z = ((z ^ (z >> 30)) * NOISE_MIX1) & MASK64
        z = ((z ^ (z >> 27)) * NOISE_MIX2) & MASK64
        z ^= z >> 31
        (z >> 11) * (2.0**-53)
      end

      # Waveform shapes (see #sine, #ramp, ...).  A #phasor tone has the
      # wave type :phasor instead.
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
      ].freeze

      # Buffer type for each wave type; anything not here uses
      # Numo::SFloat.
      BUFFER_CLASS = {
        complex_sine: Numo::SComplex,
        complex_square: Numo::SComplex,
        complex_triangle: Numo::SComplex,
        complex_ramp: Numo::SComplex,
      }.freeze

      # The band-limiting fade band for band-limiting that is always on.
      ALWAYS = [0.0, 0.0].freeze

      attr_reader :wave_type, :frequency, :amplitude, :range, :wavelength, :phase
      attr_reader :period, :period_samples
      attr_reader :amplitude_set

      # The phase modulation source (radians; a number or node), or nil.
      attr_reader :phase_mod

      # The phase warp width (see #pwm), or nil.
      attr_reader :width

      # The sync pulse source (see #sync), or nil.
      attr_reader :sync_source

      # Whether #softsync was used (sync reverses the phase).
      attr_reader :soft_sync

      # The seed of this tone's random phase generator (see #random_phase),
      # or nil if none has been set or drawn.
      attr_reader :seed

      # The seed of this tone's noise generator (see #noise), or nil.
      attr_reader :noise_seed

      # Shortcut for creating a new tone with the given frequency source, for
      # building more complex FM signal graphs.
      def self.[](frequency)
        new(frequency: frequency)
      end

      # Returns the value of +wave_type+ at phase +phi+ (radians), from -1 to
      # 1 (C).
      def self.value_at(wave_type, phi)
        MB::FastSound.osc(wave_type, phi)
      end

      # Ruby version of .value_at.
      def self.value_at_ruby(wave_type, phi)
        case wave_type
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
          raise "Invalid wave type #{wave_type.inspect}"
        end

        s
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
      # formula allows; see .value_at_ruby for the formulas.
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
          phi = wrap_radians(radians)
          s = phi * (2.0 / Math::PI)
          falling = phi.ge(0.5 * Math::PI) & phi.lt(1.5 * Math::PI)
          s[falling] = 2.0 - s[falling]
          s[phi.ge(1.5 * Math::PI)] -= 4.0
          s

        when :square
          phi = wrap_radians(radians)
          s = Numo::DFloat.ones(phi.length)
          s[phi.ge(Math::PI)] = -1.0
          s

        when :ramp
          phi = wrap_radians(radians)
          s = phi / Math::PI
          s[phi.ge(Math::PI)] -= 2.0
          s

        when :parabola
          t = wrap_radians(radians) * (2.0 / Math::PI)
          s = 1.0 - (1.0 - t)**2
          upper = t.ge(2.0)
          s[upper] = (t[upper] - 3.0)**2 - 1.0
          s

        when :gauss
          x = wrap_radians(radians) / Math::PI
          s = Numo::DFloat.zeros(x.length)
          lower = x.lt(1.0)
          upper = ~lower
          s[lower] = (Numo::NMath.sqrt(Numo::NMath.log(1.6487212707 / (1.0 - x[lower])) * 2) - 1) * 0.7071067811865476 if lower.count_true > 0
          s[upper] = (-Numo::NMath.sqrt(Numo::NMath.log(1.6487212707 / (x[upper] - 1.0)) * 2) + 1) * 0.7071067811865476 if upper.count_true > 0
          s.clip(-3, 3)

        when :complex_triangle, :complex_square, :complex_ramp
          # These use complex integrals per sample (see .value_at_ruby)
          Numo::DComplex.cast(radians.to_a.map { |phi| value_at_ruby(wave_type, phi) })

        else
          raise "Invalid wave type #{wave_type.inspect}"
        end
      end

      # The samples of .jump_residual's area correction: a raised cosine
      # (sin² over JUMP_AREA_TAPS + 1 steps), centered 1.5 samples after the
      # jump, about half the minBLEP's delay, which cancels the first-order
      # (low-frequency phase) error too.  Measured (harmonic error against
      # the ideal reset waveform, 11 cases): 4 taps beat 3, 6, 8, 16, and
      # 32 below 2 kHz and above.
      JUMP_AREA_TAPS = 4

      # The minBLEP and minBLAMP tables at whole-sample offsets (a jump
      # exactly between samples), for phase jumps, and the area correction
      # shape for .jump_residual (sum 1), made on first use.
      def self.jump_tables
        @jump_tables ||= begin
          blep, blamp = BandLimit.minblep_tables
          steps = Numo::DFloat.new(BandLimit::SYNC_TAPS).seq * BandLimit::SYNC_OVERSAMPLE
          n = JUMP_AREA_TAPS
          area = Numo::DFloat.cast(Array.new(n) { |i| Math.sin(Math::PI * (i + 1) / (n + 1))**2 })
          area /= area.sum
          [blep[steps].freeze, blamp[steps].freeze, area.freeze].freeze
        end
      end

      # The sum of an ideal band-limited step's samples minus the naive
      # step's, per unit of jump, for a jump exactly on a sample (whose
      # ideal value there is the midpoint; see .jump_residual).
      JUMP_STEP_AREA = -0.5

      # The same for a unit change in slope per sample exactly on a sample
      # (a kink: 1/12, from the Poisson sum of the ideal ramp residual).
      JUMP_KINK_AREA = 1.0 / 12

      # The residual (to add to the naive waveform from the jump sample on)
      # of a band-limited phase jump that changes the value by +dv+ and the
      # slope per sample by +ds+: the minBLEP/minBLAMP residuals, plus the
      # short raised cosine (JUMP_AREA_TAPS) scaled so the residual's sum is
      # that of an ideal (zero-phase) step on the sample.  A minimum-phase
      # step acts like a step delayed by about 2.8 samples, so its residual
      # alone leaves about -2.8 × dv of extra area per jump: a DC offset
      # that grows with the reset rate (e.g. -0.36 on a 1500 Hz square
      # reset at 2900 Hz), the same drift the sync kernel had (see
      # research-sync).  With the correction the mean matches the ideal
      # waveform's (and sync's) exactly.
      def self.jump_residual(dv, ds)
        blep, blamp, area = jump_tables
        residual = blep * dv + blamp * ds
        residual[0...area.length] += area * ((JUMP_STEP_AREA * dv + JUMP_KINK_AREA * ds) - residual.sum)
        residual
      end

      # Initializes an oscillator node with a simple generated waveform,
      # which plays forever (see Session and PlaybackMethods for ending
      # playback, or use a finite source such as an envelope or a file).
      #
      # +wave_type+ - One of WAVE_TYPES (e.g. :sine), or :phasor.
      # +frequency+ - The frequency of the tone, in Hz at the given
      #               +:sample_rate+ (or a wavelength as Meters or Feet), or
      #               a node producing Hz.
      # +amplitude+ - The linear peak amplitude of the tone, or a Range
      #               (default 1: full scale, -1..1; the master bus is
      #               -10 dB by default, see Session#master_gain).
      # +phase+ - The starting phase, in radians relative to a sine wave (0
      #           radians phase starts at 0 and rises).
      # +sample_rate+ - The sample rate to use to calculate the frequency.
      def initialize(wave_type: :sine, frequency: 440, amplitude: 1.0, phase: 0, sample_rate: 48000)
        check_wave_type(wave_type)
        @wave_type = wave_type
        @band_limit = true
        @lfo = false
        @width = nil
        @keep_dc = false
        @sync_source = nil
        @soft_sync = false
        @noise = 0
        @amplitude_set = false
        @phase_mod = nil
        @reset = nil
        @reset_to = nil
        @free = false
        @clean = false
        @random_phase = false
        @seed = nil
        @noise_seed = nil
        @start_cycles = nil
        @tempo = nil
        @lock = nil
        @lock_phase = nil
        @table = nil
        @zone_table = nil
        @scan = nil
        @interpolation = nil
        @scan_wrap = false
        @feedback = nil
        @feedback_gain = nil
        @feedback_dc = false
        @keep_feedback = false
        @out_gain = nil

        @frequency = nil
        @phase = nil
        @period = nil

        @state = nil
        @osc_buf = nil
        @truncated = false
        @quiet_resets = nil
        @quiet_locks = nil

        self.or_at(amplitude).at_rate(sample_rate).with_phase(phase)
        set_frequency(fixup_source(frequency))
      end

      # Changes the waveform type to sine.
      def sine
        set_wave(:sine, @band_limit)
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

      # Makes this tone output its phase in cycles (0 <= phase < 1) instead
      # of a waveform: a phase accumulator for driving wavetables or other
      # shapers, or a sync master (see #sync).  Its phase runs like any
      # tone's (frequency and #reset inputs, timeline locks for tempo
      # pitches).  It has no amplitude (#at raises); scale it with
      # arithmetic (e.g. `phasor * 2 * Math::PI` for radians).
      #
      # Example (bin/sound.rb):
      #     plot 100.hz.phasor, samples: 1000
      #     plot 100.hz.phasor.wraps, samples: 2000
      def phasor
        raise ArgumentError, 'A phasor outputs cycles (0...1) and has no amplitude; scale it with arithmetic' if @amplitude_set

        set_wave(:phasor, false)
      end

      # True if this is a #phasor.
      def phasor?
        @wave_type == :phasor
      end

      # Makes a MB::Sound::Wavetable this tone's waveform: +table+ is
      # anything Wavetable.[] accepts (a Wavetable, a library name like
      # :saw, a sound file, samples) or a Wavetable::KeyMap.  A cycle-mode
      # table plays one cycle per period, with +scan+ (0..1, a number or a
      # graph node; a Tone without an amplitude scans 0..1) morphing across
      # its frames; a sample-mode table plays its sound at this tone's pitch
      # relative to its root, restarting at each reset (see #reset, e.g.
      # key sync in a synth voice).  +interpolation+ overrides the table's
      # (see Wavetable::INTERPOLATIONS).
      #
      # Scan positions outside 0..1 clamp to the first or last frame
      # unless +scan_wrap+ is true: then the timbre wraps around, with the
      # last frame (still at 1.0) morphing into the first over one more
      # frame step, so with N frames the scan repeats every N / (N - 1)
      # (frame k at k / (N - 1) + any whole number of periods; negative
      # scans wrap the same way).  A steady ramp or LFO then morphs at a
      # constant rate through every frame in a loop, without a jump at the
      # end or a duplicated first frame; e.g. `scan: 0.1.hz.ramp.lfo.at(0..8.0 / 7)`
      # loops an 8-frame table seamlessly (a phasor times N / (N - 1) too).
      #
      # Band-limited tables pick their levels from this tone's motion per
      # sample, so FM, phase modulation (#pm), and phase warps (#pwm) stay
      # clean as far as the levels allow; warp corners get PolyBLAMP
      # corrections, and resets, timeline jumps, and hard or soft sync
      # (#sync, #softsync, real or complex tables) get minimum-phase steps
      # measured on the table.  A synced table reads the table's sync levels
      # (finely spaced, crossfaded continuously, every harmonic below 20 kHz;
      # Wavetable#sync_levels), every harmonic is filtered by the minBLEP
      # and switched with its exact minimum-phase residual at every sync
      # event and warp corner (FastWavetable.sync), so DC and harmonics
      # match the ideal synced waveform's: a synced saw table aliases -112
      # dB at 1 kHz and -106 dB at 3 kHz (with pwm(0.3) -107 and -100); the
      # kernel's cost grows with the harmonics played (85 ns per sample for
      # a 2.4 kHz slave, 220 ns at 150 Hz; more while the pitch glides).  Sample-mode tables take no phase modulation, warp,
      # sync, or noise.  #noise reads a cycle table at random phases
      # (picking levels by the pitch), so it has the table's distribution
      # of values.
      #
      # Examples (bin/sound.rb):
      #     play 110.hz.wavetable(:basic, scan: 0.2.hz.lfo.triangle.at(0..1)).at(-12.db)
      #     play C3.wavetable(:pulses, scan: adsr(0.01, 1, 0.2, 0.5)).at(-12.db)
      #     # past the last frame (saw) back into the first (sine)
      #     play 110.hz.wavetable(:basic, scan: 0.1.hz.phasor * 4 / 3.0, scan_wrap: true).at(-12.db)
      #     t = Wavetable.from_file('sounds/piano_120hz_b2.flac', mode: :sample, root: 120)
      #     play E3.wavetable(t)
      def wavetable(table, scan: nil, interpolation: nil, scan_wrap: false)
        table = MB::Sound::Wavetable.for(table)
        tables = table.is_a?(MB::Sound::Wavetable::KeyMap) ? table.tables : [table]
        tables.each { |t| t.interpolation_code(interpolation) } # checks the name
        unless scan.nil? || scan.is_a?(Numeric) || scan.respond_to?(:sample)
          raise ArgumentError, "Scan must be nil, a number, or a graph node (got #{scan.inspect})"
        end

        scan = scan.at(0..1) if scan.is_a?(Tone) && !scan.amplitude_set && !scan.phasor? # (fixup_source would make it -1..1)

        configure do
          @table = table
          @zone_table = nil
          @scan = fixup_source(scan)
          @interpolation = interpolation
          @scan_wrap = !!scan_wrap
          @wave_type = :wavetable
          @band_limit = true
        end
      end

      # The table (a Wavetable or Wavetable::KeyMap) of a #wavetable tone,
      # or nil.
      def table
        @table
      end

      # The scan input of a #wavetable tone (nil, a number, or a node).
      def scan
        @scan
      end

      # True if a #wavetable tone's scan wraps around instead of clamping
      # (see #wavetable).
      def scan_wrap?
        @scan_wrap
      end

      # True if this is a #wavetable tone.
      def wavetable?
        @wave_type == :wavetable
      end

      # True if this tone's samples are band-limited (see BandLimit): a
      # band-limited ramp, square, or triangle (not their naive a* twins),
      # or a warped band-limited shape, and not noise.  See also #blit?.
      def band_limited?
        return current_table.mipped? if table_kernel?

        !!band_limit_setting && random_advance == 0 &&
          (BandLimit::WAVES.include?(@wave_type) || (warped? && BandLimit::WARP_WAVES.include?(@wave_type)))
      end

      # True if this tone has a phase warp (see #pwm).
      def warped?
        !@width.nil?
      end

      # True if this complex tone plays from the closed-form band-limited
      # impulse trains (see BandLimit.blit_ruby): complex ramp, square, and
      # triangle with band-limiting on, without phase modulation, noise, or
      # a warp (with those, or sync, they play from complex wavetables; see
      # #complex_table?).
      def blit?
        !!band_limit_setting && BandLimit::COMPLEX_WAVES.include?(@wave_type) && random_advance == 0 &&
          !warped? && (@phase_mod.nil? || @phase_mod == 0)
      end

      # Complex shapes that play from complex wavetables (see
      # #complex_table?).
      COMPLEX_TABLE_WAVES = [:complex_ramp, :complex_square, :complex_triangle, :complex_sine].freeze

      # The complex wavetable a band-limited complex +wave_type+ plays from
      # with phase modulation, a warp, or sync (see #complex_table?): the
      # library's exact Fourier series (Wavetable::Library) as an analytic
      # table, made on first use and shared.
      def self.complex_table(wave_type)
        @complex_tables ||= {}
        @complex_tables[wave_type] ||= begin
          library = MB::Sound::Wavetable::Library
          amplitudes = case wave_type
                       when :complex_ramp then library.saw
                       when :complex_square then library.square
                       when :complex_triangle then library.triangle
                       when :complex_sine then [1.0]
                       else raise ArgumentError, "No complex table for #{wave_type.inspect}"
                       end
          MB::Sound::Wavetable.from_harmonics(amplitudes, complex: true, name: wave_type.to_s)
        end
      end

      # True if this complex tone plays from a complex wavetable (see
      # .complex_table) instead of the closed-form impulse trains (#blit?):
      # band-limited complex ramp, square, triangle, and sine with phase
      # modulation (not sines, which stay exact), a warp (#pwm), sync, or
      # (with #clean) a reset input or a timeline.  Without #clean, resets
      # of otherwise plain complex tones restart the impulse trains, as
      # before (a minBLEP step on a complex table measured worse at edges,
      # where the imaginary part peaks).
      # The wavetable kernels band-limit all of those (levels picked by the
      # motion per sample, PolyBLAMP warp corners, exact synced harmonics),
      # so complex shapes keep no negative frequencies or aliases beyond
      # what the motion itself makes (FM/PM sidebands past Nyquist).  The
      # tables are the exact series (no top-octave lift; the impulse trains'
      # phase leads by their integrators' leak, 0.6 samples at 100 Hz, 0.006
      # at 1 kHz).
      def complex_table?
        COMPLEX_TABLE_WAVES.include?(@wave_type) && band_limit_setting == true && random_advance == 0 &&
          (warped? || !@sync_source.nil? || (@clean && (!@reset.nil? || !@lock.nil?)) ||
            (@wave_type != :complex_sine && !(@phase_mod.nil? || @phase_mod == 0)))
      end

      # True if this tone is #clean and a table kernel plays it with a warp,
      # resets, or a timeline (and no sync, phase modulation, or noise): the
      # synced table kernel without sync events (FastWavetable.sync) plays
      # it, where warp corners are exact per harmonic (aliasing -110 to -118
      # dB at 1-3 kHz with pwm(0.3), against -31 to -41 for the free-running
      # table kernel's PolyBLAMP corners; about 4x the cost and 2.8 samples
      # of minimum-phase delay) and jumps are hard sync events on their
      # samples (see #reset_sync?).  Complex shapes and cycle-mode
      # band-limited wavetables (not key maps).
      def clean_table?
        return false unless @clean && @sync_source.nil? && random_advance == 0 && (@phase_mod.nil? || @phase_mod == 0)
        return false unless warped? || !@reset.nil? || !@lock.nil?

        return complex_table? unless wavetable?

        @table.is_a?(MB::Sound::Wavetable) && @table.mode == :cycle && @table.mipped?
      end

      # True if a wavetable kernel plays this tone (#wavetable, or
      # #complex_table?).
      def table_kernel?
        wavetable? || complex_table?
      end

      # Warps the phase so the first half of the waveform plays over +width+
      # of each cycle and the second half over the rest: pulse width
      # modulation for every shape.  A square becomes a pulse (see #pulse), a
      # triangle a skewed triangle (towards a saw near 0 or 1), a ramp a saw
      # with a kink, and a sine an asymmetric sine (like Casio's phase
      # distortion).  +width+ is a number from 0 to 1 (0.5 is no change) or a
      # graph node, read every sample (clamped to BandLimit::MIN_WIDTH..(1 -
      # MIN_WIDTH)).  Band-limited shapes stay band-limited (including the
      # corners the warp adds to sines and parabolas).  Only ramp, square,
      # triangle, sine, and parabola can be warped.
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
      def pwm(width, dc: false, clean: nil)
        unless width.nil? || width.is_a?(Numeric) || width.respond_to?(:sample)
          raise ArgumentError, "Width must be nil, a Numeric, or a graph node (got #{width.inspect})"
        end

        configure do
          @width = fixup_source(width)
          @keep_dc = !!dc
          @clean = !!clean unless clean.nil?
        end
      end
      alias skew pwm

      # Hard sync: restarts this tone's waveform at every cycle of a master,
      # the classic sweepable lead sound.  With +ratio:+ the master is this
      # tone's own pitch (hidden, not heard) and this tone plays at that
      # pitch times +ratio+ (a number or a graph node), so the note sets the
      # pitch and the ratio sweeps the timbre:
      #
      #     play C2.saw.sync(ratio: adsr(0.01, 0.4, 0.3, 0.3).at(1..6))
      #
      # Or give a +master+: a Pitch or Note (a hidden phasor at that pitch),
      # a Tone (its #wraps port, so it can be heard too), or any graph node
      # of sync pulses or triggers (e.g. clip.trigger; a value v resets the
      # phase 1 - v samples before its sample, so 1 is exactly on it):
      #
      #     play C3.saw.sync(C2)
      #
      # Synced tones are band-limited with minBLEP (BandLimit, FastSynth.
      # oscillate_sync), clean even at high ratios; aramp etc. give naive
      # sync.  A synced tone can't also have phase modulation or a reset
      # input.  Only ramp, square, triangle, sine, and parabola can be
      # synced.  See #softsync.
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
        set_wave(:gauss, @band_limit)
      end

      # Changes the waveform type to parabolic.
      def parabola
        set_wave(:parabola, @band_limit)
      end

      # Changes the waveform to complex sine.  The real part is equal to the
      # sine waveform, and the complex part is such that the combined waveform
      # spirals counterclockwise.
      def complex_sine
        set_wave(:complex_sine, @band_limit)
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
      # slightly (+2.6 dB at 20 kHz).  With phase modulation (#pm), a warp
      # (#pwm), #sync/#softsync, or (with #clean) a #reset input or a
      # timeline, they play from complex wavetables of the exact series instead (see
      # #complex_table?), which band-limit all of those like any wavetable;
      # with #clean, warps, resets, and timeline jumps without phase
      # modulation go through the synced table kernel, where warp corners
      # and jumps are exact per harmonic (see #clean_table?).  Complex sines take a warp,
      # sync, and resets the same way.  The naive versions (acomplex_ramp,
      # ...) alias and clip their imaginary parts.
      #
      # Examples (bin/sound.rb; the imaginary part is the real part's
      # Hilbert transform until something warps or modulates it):
      #     play 110.hz.complex_ramp.pm(220.hz.sine.at(0.7)).real * -12.db
      #     play 110.hz.complex_square.pwm(0.2.hz.lfo.at(0.2..0.8)).real * -12.db
      #     play 110.hz.complex_ramp.sync(ratio: 0.3.hz.lfo.at(1..3)).real * -12.db
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
      # This sets the phase advance to 0 and the random advance to one cycle
      # per Hz per sample, or if +blend+ is used, to values between those and
      # the original values.
      #
      # The +blend+ parameter may be used to give a value between 0 and 1 to
      # interpolate between the original tone and pure noise.  Useful values
      # are around 0.000001 to 0.0001.
      #
      # Example:
      #     1.hz.gauss.noise
      #
      # The random numbers come from the tone's own generator, seeded with
      # +seed+, or by default a sub-seed drawn from the root generator when
      # this is called (see MB::Sound.seed), so noise created in the same
      # order after the same root seed repeats, and every noise tone has its
      # own stream.
      #
      # Also see the MB::Sound::Noise class for another way to synthesize
      # noise.
      def noise(blend = true, seed: nil)
        configure do
          @noise_seed = Integer(seed) if seed
          @noise_seed ||= MB::Sound.next_seed if blend != false && blend != 0

          case blend
          when true
            @noise = 1.0

          when false
            @noise = 0.0

          else
            @noise = blend.to_f
          end
        end
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
        raise ArgumentError, 'A phasor outputs cycles (0...1) and has no amplitude; scale it with arithmetic' if phasor? && !@in_or_at

        configure do
          @musical_time = durations == 2

          if amplitude.is_a?(Range)
            @range = amplitude.begin.to_f..amplitude.end.to_f
            @amplitude = (@range.end - @range.begin) / 2
          else
            @amplitude = amplitude.to_f
            @range = -@amplitude..@amplitude
          end

          @amplitude_set = true
        end
      end

      # Multiplies the tone's output by +gain+ (a number or a graph node,
      # e.g. an envelope; nil removes it) inside the oscillator, after #at
      # (its scale and offset) and any band-limited jump steps: the same
      # samples as `tone.at(...) * gain` (bit for bit), without a separate
      # Multiplier node, and a step the planner can fold into the
      # oscillator.  An input that ends (a one-shot envelope) ends the tone.
      # Also available as #amp.
      #
      # On a #feedback sine this is the output gain, after the feedback
      # loop: the timbre stays fixed while the level changes.  #feedback's
      # +gain:+ is the in-loop level instead, which the feedback reads, so
      # the timbre follows it (the FM-synth operator behavior).  Both can be
      # used together.
      #
      #     play 220.hz.saw.gain(adsr(0.01, 0.3, 0.5, 0.4, hold: 1))
      #     v.hz.ramp.at(0.5).gain(v.amp_env)          # in a synth voice
      def gain(gain)
        raise ArgumentError, 'A phasor outputs cycles (0...1) and has no gain; scale it with arithmetic' if phasor?
        unless gain.nil? || gain.is_a?(Numeric) || gain.respond_to?(:sample)
          raise ArgumentError, "Gain must be nil, a Numeric, or a graph node (got #{gain.inspect})"
        end

        configure do
          @out_gain = gain.is_a?(Numeric) || gain.nil? ? gain : fixup_source(gain)
        end
      end
      alias amp gain

      # The output gain given to #gain (a number or node), or nil.
      def output_gain = @out_gain

      # True if #at was given a Range of Durations, so this tone outputs a
      # musical length in whole notes rather than a plain number.
      def musical_time?
        !!@musical_time
      end

      # Sets the default linear +amplitude+ of the tone, which may be a Numeric
      # or a Range, if #at has not yet been called (and the tone hasn't
      # started playing).
      def or_at(amplitude)
        unless @amplitude_set || @started
          begin
            @in_or_at = true
            at(amplitude)
          ensure
            @in_or_at = false
          end
          @amplitude_set = false
        end

        self
      end

      # Changes the sample rate of the tone (and its inputs; see
      # GraphNode::SampleRateHelper), at any time.
      def sample_rate=(sample_rate)
        super
        @period_samples = @period * @sample_rate if @period
        @advance = nil
        @kernel = nil
        Plan.changed(self, structure: false)
        self
      end
      alias at_rate sample_rate=

      # Changes the initial phase of the tone, in radians relative to a sine
      # wave.  0 phase starts oscillators at 0 and rising (or at the top half
      # of the cycle for a square wave).
      #
      # Example: 123.hz.with_phase(90.degrees)
      def with_phase(phase)
        configure do
          @phase = phase
          @start_cycles = nil
        end
      end

      # Like #with_phase, in cycles (0 to 1; e.g. 0.25 is 90 degrees).
      def with_phase_cycles(cycles)
        configure do
          @phase = cycles * TWOPI
          @start_cycles = cycles
        end
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
        configure do
          tone = tone.hz if tone.is_a?(Numeric)
          tone = tone.at(1) if index && tone.is_a?(Tone)
          tone = fixup_source(tone)
          index = fixup_source(index)

          @frequency = MB::Sound::GraphNode::Mixer.new([@frequency, [tone, index || 1]], sample_rate: @sample_rate)
        end
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
        configure do
          tone = tone.hz if tone.is_a?(Numeric)
          tone = tone.at(1) if index && tone.is_a?(Tone)

          tone = fixup_source(tone)
          index = fixup_source(index)

          tone = 2 ** (tone / 12)
          tone = tone * index if index
          @frequency = @frequency * tone
        end
      end

      # Adds the given other +tone+ or signal graph as a phase modulation
      # source for this tone.  Like #fm, but added to the phase given to the
      # oscillator, rather than to the frequency itself.
      def pm(tone, index = nil)
        configure do
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
        end
      end

      # Operator self-feedback (FM synth style): the sine's phase is
      # modulated by its own output, averaged over the last two samples (as
      # the DX7 does; one-sample feedback "hunts" at Nyquist at high
      # amounts), computed per sample inside the kernel rather than through
      # a graph loop:
      #
      #     y[n] = sin(2pi * phase[n] + pm[n] + amount * (y[n-1] + y[n-2]) / 2) * gain[n]
      #
      # +amount+ is in radians of phase modulation per unit of output (a
      # number or a node, read every sample; nil removes feedback).  A sine
      # brightens towards a saw (measured at 125 Hz, H2/H3 relative to the
      # fundamental; a saw is -6.0/-9.5 dB):
      #
      #     0.5 rad   -12.5/-21.5 dB, harmonics above -60 dB to the 9th
      #     1.0 rad    -8.1/-12.9 dB, to the 36th
      #     1.5 rad    -7.0/-11.0 dB, to the 104th (a saw-like tone)
      #     2.0 rad    -6.6/-10.5 dB, to the 162nd (brightest clean setting)
      #
      # Above about 2.2 rad the loop turns chaotic, but only above 12 kHz at
      # first: up to about 3.5 rad the audible tone stays saw-like and a
      # hiss sits at 12-24 kHz (non-harmonic power -11 to -6 dB of the
      # total there, -50 to -40 dB below 4 kHz), which many playback chains
      # and ears hardly reproduce.  Grit reaches the audible band from 3.5
      # rad, and from about 4 rad it is broadband noise (non-harmonic power
      # below 4 kHz -6 dB), as a DX7 at full feedback (2pi; see
      # .dx7_feedback) is.  This doesn't depend on the pitch (55-440 Hz
      # measured).  Negative amounts give the same harmonic levels.
      #
      # The feedback sine has a DC offset that grows with the amount (a
      # mean of -0.04 at 1 rad, -0.14 at 1.5, -0.25 at 2, -0.38 at 3 at
      # 110 Hz; -0.09 at 1 rad and -0.30 at 2 at 440 Hz; positive for
      # negative amounts).  It is removed from the output by default, like
      # #pwm's (pass dc: true to keep it): a one-pole DC tracker whose
      # cutoff follows the pitch (1/20 of the frequency, so LFO-rate
      # feedback sines work too) is subtracted after the loop, so the loop
      # itself is unchanged.  That is a one-pole highpass at f/20: harmonic
      # levels change by under 0.03 dB, the fundamental's phase by 2.9
      # degrees, and the estimate settles within a few cycles after the
      # amount or gain changes (a small low-frequency bump on attacks, as
      # from an AC-coupled output).  In a modulator, removing DC removes a
      # constant phase shift of the carrier.  With dc: true and feedback 0
      # the tone is exactly a plain sine.
      #
      # Nothing clamps the amount; FEEDBACK_MAX (2pi, noise) is the top of
      # the useful range, e.g. for a knob.  #feedback_cycles takes the
      # amount in cycles instead (1.0 = 2pi).
      #
      # +gain:+ (a number or node, default 1) is the operator's output level
      # inside the loop, e.g. its envelope: the tone outputs the enveloped
      # signal, and the feedback reads it, so the timbre follows the level
      # (bright attacks, mellowing decays) as on an FM synth.  #at scales the
      # output after the loop (e.g. a modulator's index in radians), so it
      # doesn't change the operator's own timbre.  An input that ends (e.g.
      # a one-shot envelope) ends the tone.
      #
      # Only plain sines take feedback (not other shapes, warps (#pwm),
      # #sync, #noise, or wavetables; those raise an ArgumentError when the
      # tone starts).  It works with #fm, #pm, #reset (key sync), and
      # timeline locks.  A reset (e.g. key sync at each note-on) clears the
      # feedback history and the DC estimate too, so every note starts
      # identically; `reset(trigger, keep_feedback: true)` or
      # #keep_feedback (e.g. on a key-synced voice tone) keeps the history
      # across resets instead.  Free-running tones (#free) never reset, and
      # timeline jumps (seeks) keep the history.
      #
      # Feedback raises the bandwidth like FM, so high notes alias: at 1 kHz
      # the worst alias is -103 dB at 1.0 rad, -59 dB at 1.5 rad, -30 dB at
      # 2.0 rad (a band-limited ramp: -41 dB); at 4 kHz -46 dB at 1.0 rad
      # and -27 dB at 1.5.  `oversample(4)` brings 1.5 rad at 1 kHz to -135
      # dB (bin/aliasing.rb 'p.feedback(1.5)').  Cost: about 28 ns per
      # sample whatever the amount (a plain sine: 21 ns; nodes for the
      # amount and gain add their own cost).  See .dx7_feedback for the DX7's
      # 0-7 feedback setting in radians.  Also available as #fb.
      #
      # Examples (bin/sound.rb):
      #     play 110.hz.feedback(1.3).at(-12.db)                          # a saw-like sine
      #     play 220.hz.feedback(2.hz.lfo.at(0..1.5)).at(-12.db)          # sweeping brightness
      #     e = adsr(0.05, 0.4, 0.5, 0.3, hold: 1)
      #     play 220.hz.feedback(1.4, gain: e).at(-6.db)                  # brass-like: bright as it swells
      #     play 220.hz.pm(440.hz.feedback(1.0).at(1.5)).at(-12.db)       # a feedback modulator
      def feedback(amount, gain: nil, dc: false)
        if amount.nil?
          return configure do
            @feedback = nil
            @feedback_gain = nil
            @feedback_dc = false
          end
        end

        [[amount, 'Feedback amount'], [gain, 'Feedback gain']].each do |v, name|
          next if v.nil? || v.is_a?(Numeric) || v.respond_to?(:sample)
          raise ArgumentError, "#{name} must be a Numeric or a graph node (got #{v.inspect})"
        end
        raise ArgumentError, "Only sines take feedback (this is a #{wave_name})" unless @wave_type == :sine

        configure do
          @feedback = amount.is_a?(Numeric) ? amount.to_f : fixup_source(amount)
          @feedback_gain = gain.nil? ? 1.0 : (gain.is_a?(Numeric) ? gain.to_f : fixup_source(gain))
          @feedback_dc = !!dc
        end
      end
      alias fb feedback

      # Like #feedback, with the amount in cycles of phase modulation per
      # unit of output instead of radians (+cycles+ times 2pi radians; a
      # number or a node), like #with_phase_cycles: 1.0 is FEEDBACK_MAX
      # (2pi, noise), about 0.24 is saw-like, 0.32 the brightest clean
      # setting.
      def feedback_cycles(cycles, gain: nil, dc: false)
        return feedback(nil) if cycles.nil?

        amount = cycles * TWOPI
        feedback(amount, gain: gain, dc: dc)
      end
      alias fb_cycles feedback_cycles

      # The feedback amount (radians; a number or node) given to #feedback,
      # or nil for none.
      def feedback_amount = @feedback

      # The in-loop gain given to #feedback (a number or node), or nil
      # without feedback.
      def feedback_gain = @feedback && @feedback_gain

      # True if this tone has operator feedback (see #feedback).
      def feedback?
        !@feedback.nil?
      end

      # The top of the useful #feedback range: 2pi rad per unit of output,
      # a DX7's FB 7 at full operator level (see .dx7_feedback), well into
      # noise.  The range for a feedback knob is 0..FEEDBACK_MAX, e.g.
      # `v.cc(1, range: 0.0..Tone::FEEDBACK_MAX)`.  Nothing clamps the
      # amount: larger and negative amounts play as given.
      FEEDBACK_MAX = 2 * Math::PI

      # The DX7's FB 7 at full level (see .dx7_feedback; FEEDBACK_MAX).
      DX7_FEEDBACK_MAX = FEEDBACK_MAX

      # Converts a DX7 feedback setting +fb+ (0 to 7) to radians for
      # #feedback, for an operator whose #feedback gain is 1.0 at full
      # level (output level 99, envelope at 99): 0 for 0, else 2pi *
      # 2**(fb - 7) (pi/32 at 1, ..., pi at 6, 2pi at 7).
      #
      # From the arithmetic of MSFA (Apache-2.0, in Dexed): the feedback
      # term is (y[n-1] + y[n-2]) >> (9 - fb) on Q24 values whose phase
      # unit is one cycle per 2**24, and a full-level operator's output
      # peaks at 2.0 (its maximum modulation index is 4pi).  So the DX7's
      # feedback depends on the operator's level, which is what #feedback's
      # +gain:+ is for: pass the operator's linear level (relative to full)
      # times its envelope.  Full-level FB 7 is noise, as on the DX7 (a known
      # noise trick); saw-like patches use FB 6-7 on quieter operators or
      # lower FB.  Not bit-exact (the DX7 works on log-sine tables).
      def self.dx7_feedback(fb)
        fb = Integer(fb)
        raise ArgumentError, "DX7 feedback must be 0 to 7 (got #{fb})" unless (0..7).cover?(fb)
        return 0.0 if fb == 0

        DX7_FEEDBACK_MAX * 2.0**(fb - 7)
      end

      # Resets the phase at every nonzero sample of +trigger+ (a graph node,
      # e.g. clip.trigger or a MIDI note-on trigger; the value is ignored),
      # at exactly that sample, or removes the reset input with nil.  The
      # phase goes +to:+
      #
      # - nil (default): the starting phase (see #with_phase; 0 unless set),
      # - a phase in radians, like #with_phase (e.g. 90.degrees),
      # - a graph node of radians, read at each reset sample,
      # - :random, a new random phase at each reset (the same as #rnd).
      #
      # The jump is band-limited: a 32-sample minBLEP step from the value the
      # wave would have had, including phase modulation at that sample, with
      # an ideal step's area (Tone.jump_residual).  With +clean: true+ (see
      # #clean), band-limited ramps, squares, triangles, warped shapes,
      # wavetables, and complex shapes without phase modulation play through
      # the synced kernels instead, where each reset is a hard sync event on
      # its sample, as clean as #sync.  Works with #fm and #pm.  Buffers
      # with resets are computed in pieces
      # split at the reset samples; buffers without resets cost one scan of
      # the trigger buffer.  A reset input that ends (returns nil) means no
      # more resets, not the end of the tone, so e.g. a key-synced clip tone
      # keeps playing through an envelope's release after its clip's
      # trigger has ended.
      #
      # A #feedback sine clears its feedback history at each reset, so every
      # note starts the same; +keep_feedback:+ true keeps it (see
      # #keep_feedback; nil leaves that setting as it is).
      #
      # A tone can't have both a reset input and #sync (an error: sync
      # already resets the phase, in its own kernel).  On a #free tone the
      # last call wins: a reset input makes it no longer free, and a fixed
      # +to:+ replaces #rnd, each with a warning.
      #
      # Examples (bin/sound.rb):
      #     bpm 120; c = grid(16, 'x..x..x.').loop
      #     play 55.hz.saw.reset(c.trigger) * c.env           # every hit starts at phase 0
      #     play 2.hz.lfo.reset(c.trigger, to: 90.degrees)    # an LFO that restarts at its peak
      def reset(trigger, to: nil, clean: nil, keep_feedback: nil)
        self.clean(clean) unless clean.nil?
        if trigger.nil?
          return configure do
            @reset = nil
            @reset_to = nil
          end
        end

        unless trigger.respond_to?(:sample)
          raise ArgumentError, "Reset input must be nil or a graph node of triggers (got #{trigger.inspect})"
        end
        raise ArgumentError, 'A synced tone cannot also have a reset input' if @sync_source
        unless to.nil? || to == :random || to.is_a?(Numeric) || to.respond_to?(:sample)
          raise ArgumentError, "Reset target must be nil, :random, radians, or a graph node (got #{to.inspect})"
        end

        configure do
          if @free
            override_warning('reset overrides free (the tone is no longer free)')
            @free = false
          end

          if to == :random
            to = nil
            random_phase
          elsif to && @random_phase
            override_warning("reset(to: #{make_source_name(to)}) overrides rnd (no more random phases)")
            @random_phase = false
          end

          @reset = fixup_source(trigger)
          @reset_to = to.respond_to?(:sample) ? fixup_source(to) : to
          @keep_feedback = keep_feedback unless keep_feedback.nil?
        end
      end

      # Makes a #feedback sine keep its feedback history (and DC estimate)
      # across resets (see #reset) instead of clearing it, e.g. on a synth
      # voice's key-synced tone: `v.hz.feedback(1.4).keep_feedback`.
      def keep_feedback(keep = true)
        configure { @keep_feedback = !!keep }
      end

      # True if resets keep the feedback history (see #keep_feedback).
      def keep_feedback?
        !!@keep_feedback
      end

      # The reset trigger input (see #reset), or nil.
      def reset_input = @reset

      # The reset target given to #reset (nil, radians, or a node).
      def reset_to = @reset_to

      # Plays this tone's phase jumps and warps through the synced kernels
      # (+enabled+ true; false for the default): resets, key sync, and
      # timeline jumps become hard sync events on their samples, as clean as
      # #sync (band-limited ramps, squares, triangles, and warped shapes
      # without phase modulation: #reset_sync?; harmonic error against the
      # ideal reset waveform -72 to -86 dB instead of -19 to -38), and
      # warped (#pwm) or reset wavetables and complex shapes get exact
      # corners and jumps per harmonic (#clean_table?).  The cost: the tone
      # becomes the naive waveform through the minBLEP's minimum-phase
      # filter (about 2.8 samples of delay, minBLEP edges with their ringing,
      # peaks up to ~1.4x PolyBLEP's) and about twice the oscillator's CPU
      # (4x for tables).  Also #reset(trig, clean: true) and
      # #pwm(w, clean: true).  Off by default (user's choice, 2026-10-08:
      # predictable cost for key-synced voices).
      #
      #     play 700.hz.ramp.reset(200.hz.lfo.wraps, clean: true).at(-12.db)   # as clean as sync
      #     play 110.hz.wavetable(:saw).pwm(0.3, clean: true).at(-12.db)        # exact warp corners
      #     midi.synth { |v| v.hz.saw.clean * v.amp_env }                       # key-synced voices
      def clean(enabled = true)
        configure do
          @clean = !!enabled
        end
      end

      # True if this tone plays its jumps and warps through the synced
      # kernels (see #clean).
      def clean?
        @clean
      end

      # Marks this tone as never reset: a free-running oscillator whose phase
      # never restarts, like an analog oscillator.  Synth voices don't key
      # sync it (see Notes::KeyedTone).  It replaces a reset input (see #reset; the
      # last call wins, with a warning).  Combine with #rnd for a random starting phase (analog-style unison):
      #
      #     play 3.times.map { |i| (110 + i * 0.3).hz.saw.free.rnd }.sum * -15.db
      def free(free = true)
        configure do
          if free && @reset
            override_warning('free overrides reset (removed the reset input)')
            reset(nil)
          end

          @free = !!free
        end
      end

      # True if #free was called (never reset).  LFOs (#lfo) aren't key
      # synced by synth voices either, but may still have a reset input; see
      # #lfo?.
      def free?
        @free
      end

      # Gives this tone a random phase: a random starting phase, and with a
      # reset input (see #reset) a new random phase at every reset.  The
      # random numbers come from a Random seeded with +seed+, or by default
      # a sub-seed drawn from the root generator when this is called (see
      # MB::Sound.seed), so tones created in the same order after the same
      # root seed repeat.  Replaces a fixed +to:+ given to #reset (the last
      # call wins, with a warning).  Also available as #rnd.
      #
      #     play 220.hz.saw.rnd                                # random start
      #     play 110.hz.square.reset(clip.trigger).rnd        # random at each note
      def random_phase(seed: nil)
        configure do
          if @reset_to
            override_warning("rnd overrides reset(to: #{make_source_name(@reset_to)}) (resets go to random phases)")
            @reset_to = nil
          end

          @seed = Integer(seed) if seed
          @seed ||= MB::Sound.next_seed
          @random_phase = true
        end
      end
      alias rnd random_phase

      # True if this tone has a random phase (see #random_phase).
      def random_phase?
        @random_phase
      end

      # Sets the seed for this tone's random phase (see #random_phase),
      # before it plays.  For code that derives seeds itself (e.g. one per
      # synth voice).
      def seed=(seed)
        configure { @seed = Integer(seed) }
      end

      # Makes this Tone a low-frequency oscillator for modulation: synth
      # voices don't key sync it (see Notes::KeyedTone) and it swings over the
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
        configure { @lfo = true }
        or_at(1)
      end

      # Locks this tone's phase to the timeline of +tempo+ (a
      # Sequence::TempoNode in :hz mode, usually this tone's frequency; see
      # Pitch, Sequence::Duration#hz): at each sample where the tempo node's
      # #jumps port is nonzero (the timeline started, jumped, or resumed),
      # the phase goes to the tempo node's #jump_phase (cycles of its
      # duration) past this tone's starting phase (see #with_phase), with a
      # band-limited step like a reset (see #reset).  Both ports are inputs
      # of this tone, read every buffer.  Called by Pitch for tones made
      # from a tempo pitch.
      def follow_timeline(tempo)
        raise ArgumentError, "Expected a Sequence::TempoNode in :hz mode (got #{tempo.inspect})" unless tempo.is_a?(Sequence::TempoNode) && tempo.mode == :hz

        configure do
          @tempo = tempo
          @lock = tempo.jumps.get_sampler
          @lock_phase = tempo.jump_phase.get_sampler
        end
      end

      # The Sequence::TempoNode this tone's phase follows (see
      # #follow_timeline), or nil.
      def timeline
        @tempo
      end

      # For a Tone whose phase follows the timeline (see #follow_timeline,
      # Sequence::Duration#hz), lets its phase run free of the timeline and
      # keeps it running while the timeline is paused.  Its frequency still
      # follows the tempo.  This changes the tempo node (see
      # Sequence::TempoNode#freewheel), so every tone made from the same
      # tempo pitch freewheels.
      def freewheel(free = true)
        raise ArgumentError, 'Only tempo-synced tones (e.g. 4.bars.lfo) can freewheel' if @tempo.nil?

        @tempo.freewheel(free)
        self
      end

      # Returns true if #lfo was called (a modulation source that synth
      # voices don't key sync).
      def lfo?
        @lfo
      end

      # Converts this Tone to the nearest Note based on its frequency.
      def to_note
        MB::Sound::Note.new(self)
      end

      # Converts this Tone to a note-on MB::Sound::MIDI::Event at the
      # nearest note (see Note#to_midi).
      def to_midi(velocity: 64, channel: 0)
        to_note.to_midi(velocity: velocity, channel: channel)
      end

      # The per-sample state (see Tone::State), made when the tone starts
      # playing (or on first use).
      def state
        @state ||= initial_state
      end

      # The current phase in radians (0 to 2pi).
      def phi
        state.phi * TWOPI
      end

      # The last frequency value used for synthesis (0 before the first
      # sample).
      def last_freq
        @state ? @state.last_freq : 0.0
      end

      # The phase advance per sample per Hz, in cycles (normally 1 /
      # sample_rate; a little less with #noise, which adds a random
      # advance).
      def advance
        @advance || compute_advance
        @advance
      end

      # The maximum random addition to the phase advance per Hz per sample,
      # in cycles (see #noise).
      def random_advance
        MB::M.interp(0, TWOPI, @noise) / TWOPI
      end

      # Generates +count+ samples of the tone.  Returns nil only if an input
      # (frequency, phase modulation, width, sync, or reset target) ends.
      def sample(count)
        return nil if count <= 0

        count = count.round
        return sample_c(count) if @ports.nil?

        port_frame(count) { sample_c(count) }
      end

      # The tone in C (see the class description for the steps).
      def sample_c(count)
        start unless @started
        return nil if one_shot_ended?

        count, freq, phase, width, pulses, resets, targets, jumps, jump_phase, scan, fb, fb_gain, out_gain = get_upstream_inputs(count)
        return nil if missing_input?(freq, phase, width, pulses, resets, targets, scan, fb, fb_gain, out_gain)

        state = @state
        if @ports
          state.frame_phase = state.phase[0]
          state.frame_freq = freq
          state.frame_segments = nil
        end

        pick_zone(freq) if @table.is_a?(MB::Sound::Wavetable::KeyMap) && (@zone_table.nil? || @reset.nil?)
        build_buffer(count)

        points = reset_points(resets)
        locks = lock_points(jumps)
        if points || locks
          buf = sample_segments(count, freq, phase, width, points, targets, locks, jump_phase, scan, fb, fb_gain) do |out, f, ph, w, sc, fbs, fgs|
            kernel_c(out, f, ph, w, nil, sc, fbs, fgs)
          end
        else
          buf = kernel_c(osc_view(count), freq, phase, width, pulses, scan, fb, fb_gain)
          add_jump_residual(buf) if state.jump_residual
        end
        apply_output_gain(buf, out_gain) if out_gain

        state.last_freq = freq.is_a?(Numeric) ? freq : freq[-1]
        state.last_width = width.is_a?(Numo::NArray) ? width[-1] : width

        buf.not_inplace!
      end

      # The tone in Ruby: the same samples as #sample_c (except noise),
      # from the kernels' Ruby mirrors.
      def sample_ruby(count)
        start unless @started
        return nil if one_shot_ended?

        count, freq_table, phase_table, width, pulses, resets, targets, jumps, jump_phase, scan, fb, fb_gain, out_gain = get_upstream_inputs(count)
        return nil if missing_input?(freq_table, phase_table, width, pulses, resets, targets, scan, fb, fb_gain, out_gain)

        compute_ruby(count, freq_table, phase_table, width, pulses, resets, targets, jumps, jump_phase, scan, fb, fb_gain, out_gain)
      end

      # The samples of #sample_ruby from inputs already read (the inputs
      # are as #get_upstream_inputs returns them).  Also the Ruby mirror of
      # the plan layer's tone op (Plan::Op::Tone).
      def compute_ruby(count, freq_table, phase_table, width, pulses, resets, targets, jumps, jump_phase, scan, fb, fb_gain, out_gain)
        pick_zone(freq_table) if @table.is_a?(MB::Sound::Wavetable::KeyMap) && (@zone_table.nil? || @reset.nil?)
        build_buffer(count)

        points = reset_points(resets)
        locks = lock_points(jumps)
        if points || locks
          buf = sample_segments(count, freq_table, phase_table, width, points, targets, locks, jump_phase, scan, fb, fb_gain) do |out, f, ph, w, sc, fbs, fgs|
            kernel_ruby(out, f, ph, w, nil, sc, fbs, fgs)
          end
        else
          buf = kernel_ruby(osc_view(count), freq_table, phase_table, width, pulses, scan, fb, fb_gain)
          add_jump_residual(buf)
        end
        buf.inplace * out_gain if out_gain # Numo: the mirror of FastArithmetic.scale

        @state.last_freq = freq_table.is_a?(Numeric) ? freq_table : freq_table[-1]
        @state.last_width = width.is_a?(Numo::NArray) ? width[-1] : width

        buf.not_inplace!
      end

      # Plan layer (see MB::Sound::Plan and Plan::Op::Tone): one oscillator
      # op on this tone's own state, for the :naive and :synth kernels.
      include Plan::Describable

      def plan_describe(p)
        # A Notes trigger the region owns is described inside the plan (it
        # stops planning before it could end; see Plan::EventList), anything
        # else is an optional boundary input
        reset = @reset && !state.reset_ended ? p.optional(@reset) : nil
        target = @reset_to.respond_to?(:sample) ? p.boundary(@reset_to) : nil
        p.tone(
          self,
          frequency: p[@frequency], phase_mod: p[@phase_mod || 0], width: @width && p[@width],
          reset: reset, target: target, gain: @out_gain && p[@out_gain]
        )
      end

      def plan_inputs
        [@frequency, @phase_mod, @width, @reset, @reset_to, @out_gain].select { |v| v.respond_to?(:sample) }
      end

      def plan_boundary_inputs
        list = [@reset_to].select { |v| v.respond_to?(:sample) }
        list << @reset if @reset.respond_to?(:sample) && !Plan.event_node?(Plan.origin(@reset))
        list
      end

      def plan_unsupported_reason
        return 'ports (wraps or increment) in use' if @ports
        return 'a timeline (tempo tone)' if @lock
        return 'sync' if @sync_source

        k = kernel
        return "the #{k} kernel" unless Plan::Op::Tone::KERNELS.include?(k)
        return 'a complex gain' if @out_gain.is_a?(Complex)

        nil
      end

      def plan_output_type
        BUFFER_CLASS[@wave_type] == Numo::SComplex ? :complex : :real
      end

      # For plans: true while Plan::Op::Tone's Ruby mirror runs a tone with
      # fast shapes (Plan.precision = :fast; see Plan::FastMath).
      attr_accessor :plan_fast_shapes

      # For plans: starts the tone as its first #sample would.
      def plan_start
        start unless @started
      end

      # For plans (Plan::Op::Tone in C): the phase jump of a reset on the
      # sample where the frequency is +freq+, the phase modulation
      # +phase_mod+, the width +width+ (nil without #pwm), and the reset
      # target input +target+ (radians, or nil without one); the same Ruby
      # as an unplanned reset (see #sample_segments).
      def plan_reset(freq, phase_mod, width, target)
        reset_jump({ freq: freq, width: width, phase_mod: phase_mod }, reset_target_value(target))
      end

      # For plans: the executor added the first +n+ samples of the queued
      # jump step (see #add_jump_residual).
      def plan_residual_used(n)
        residual = @state.jump_residual
        @state.jump_residual = n < residual.length ? residual[n..].dup : nil
      end

      # For plans: the reset input (whose origin is +source+) ended.
      def plan_input_ended(source)
        @state.reset_ended = true if @reset && Plan.origin(@reset).equal?(source)
      end

      def plan_snapshot
        @state&.to_h
      end

      def plan_restore(snapshot)
        return unless snapshot

        fresh = State.new(**snapshot)
        fresh.instance_variables.each { |iv| @state.instance_variable_set(iv, fresh.instance_variable_get(iv)) }
      end

      # See GraphNode#sources.  Returns the frequency, phase modulation, and
      # other inputs of the tone, each either a number or a signal
      # generator.
      def sources
        {
          frequency: @frequency,
          phase: @phase,
          phase_mod: @phase_mod,
          width: @width,
          sync: @sync_source,
          reset: @reset,
          reset_to: @reset_to.respond_to?(:sample) ? @reset_to : nil,
          timeline_jumps: @lock,
          timeline_phase: @lock_phase,
          scan: @scan.respond_to?(:sample) ? @scan : nil,
          feedback: @feedback.respond_to?(:sample) ? @feedback : nil,
          feedback_gain: @feedback && @feedback_gain.respond_to?(:sample) ? @feedback_gain : nil,
          gain: @out_gain.respond_to?(:sample) ? @out_gain : nil,
        }.compact
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
        "#{super} -- #{wave_name} freq=#{make_source_name(@frequency)} range=#{@range}#{" pwm=#{make_source_name(@width)}" if @width}#{" #{@soft_sync ? 'softsync' : 'sync'}" if @sync_source}"
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

      # Runs the block (which changes configuration) and returns self,
      # forgetting cached settings (and a state made early for
      # introspection) so the first sample picks the change up.  Raises
      # FrozenError once the tone has started playing (in live mode,
      # MB::Sound.live?, it warns and leaves the tone unchanged instead).
      def configure
        if @started
          MB::Sound.live_error(FrozenError.new(
            "#{self.class.name} #{wave_name} #{make_source_name(@frequency)} is already playing, so its settings are fixed " \
            '(values that change while playing come from inputs, e.g. a Constant or another node)',
            receiver: self
          ))
          return self
        end

        yield
        @kernel = nil
        @advance = nil
        @state = nil
        Plan.changed(self)
        self
      end

      def check_wave_type(wave_type)
        return if WAVE_TYPES.include?(wave_type) || wave_type == :phasor
        raise ArgumentError, 'Use Tone#wavetable to give a wavetable tone its table' if wave_type == :wavetable

        raise ArgumentError, "Invalid wave type #{wave_type.inspect}; only #{WAVE_TYPES.map(&:inspect).join(', ')}, or :phasor are supported"
      end

      # Prepares to play: makes the state and caches the settings.
      def start
        state
        @started = true
      end

      # The state at the start: the starting phase (with a random phase
      # drawn if #rnd was used; the same arithmetic as the old Phasor#phase=,
      # so renders match), unprimed.
      def initial_state
        start = @start_cycles || (@phase / TWOPI) % 1.0
        s = State.new(phase: start)
        s.noise = [@noise_seed & MASK64] if @noise != 0
        if @random_phase
          s.seed = @seed
          p = (s.random * TWOPI) / TWOPI
          s.phi = s.phi + p - start
          start = p % 1.0
        end
        @start_cycles = start
        s
      end

      # Computes the phase advance and random advance in cycles per Hz per
      # sample (see #advance).
      def compute_advance
        ra = MB::M.interp(0, TWOPI, @noise)
        @random_advance = ra / TWOPI
        @advance = (phasor? && ra == 0) ? 1.0 / @sample_rate : (TWOPI / @sample_rate - 0.5 * ra) / TWOPI
        @gain, @offset = gain_and_offset
      end

      # Output gain and offset for the kernels from #range.
      def gain_and_offset
        if @range && !phasor?
          [(@range.last - @range.first) / 2.0, (@range.first + @range.last) / 2.0]
        else
          [1, 0]
        end
      end

      # The band_limit setting for the kernels: false, true, or a Range of
      # frequencies (Hz) over which band-limiting fades in (LFOs).
      def band_limit_setting
        return false unless @band_limit
        @lfo ? BandLimit::LFO_FADE : true
      end

      # Runs the block, which jumps the phase, and for a band-limited
      # tone that has played, queues a band-limited step for the following
      # samples.  The step is measured at frequency +freq+, warp +width+, and
      # phase modulation +phase_mod+ (radians): by default those of the last
      # sample played and no phase modulation (a jump between buffers), or
      # those of the reset sample (a reset input; see #sample_segments).
      def phase_jump(freq: state.last_freq, width: state.last_width, phase_mod: 0.0, scan: nil)
        state = @state
        if kernel == :reset_sync || clean_table?
          # A hard sync event on the jump sample (see #reset_sync?,
          # #clean_table?), or the start of a tone that hasn't played
          yield
          if state.sync[4] == 0
            state.sync[0] = state.phase[0]
          else
            @sync_reset = state.phase[0]
          end
          return
        end

        before = state.phase[0]
        played = freq != 0.0 && (state.blep[3] == 1 || state.blit[6] != 0 || state.table[2] != 0)
        if table_kernel?
          table_before = current_table
          position = state.table[0]
        end
        yield
        after = state.phase[0]
        state.unprime(sync: !!@sync_source)

        return table_jump(table_before, before, after, position, freq, width, phase_mod, scan) if table_kernel? && played && !@sync_source
        return unless played && !@sync_source && synth_kernel? && !blit?

        w = BandLimit.clamp_width((width || 0.5).to_f)
        pm = phase_mod / TWOPI
        v0, s0 = jump_from_shape(w, pm == 0 ? before : BandLimit.wrap(before + pm), freq > 0)
        v1, s1 = BandLimit.sync_shape(@wave_type, w, pm == 0 ? after : BandLimit.wrap(after + pm))
        inc = freq * advance
        bl = band_limit_setting
        k = bl.is_a?(Range) ? BandLimit.fade(inc.abs / advance, bl.begin.to_f, bl.end.to_f) : 1.0
        k = 0.0 unless band_limited?
        return if k == 0

        residual = Tone.jump_residual(v1 - v0, (s1 - s0) * inc) * k
        state.jump_residual = state.jump_residual ? residual + pad_residual(state.jump_residual, residual.length) : residual
      end

      # [value, slope per cycle] of the old waveform at phase +p+ (cycles)
      # for a phase jump (see #phase_jump), warped by width +w+.  A phase on
      # a jump in value (within BandLimit::EPS) that the tone reached moving
      # +forward+ hasn't crossed it yet at the jump (an edge and a reset on
      # the same sample, e.g. a 1 kHz ramp reset at 400 Hz), so it takes
      # the value and slope before the edge; moving backward, the value
      # after it (the side it came from; see BandLimit.side_crossing).
      # Corners without a jump in value (triangles) keep the slope after
      # them, which measured slightly closer to the ideal.
      def jump_from_shape(w, p, forward)
        points = BandLimit.breakpoints(@wave_type, w)
        j = BandLimit.snap(points, p)
        return BandLimit.sync_shape(@wave_type, w, p) unless j && points[j][1] != 0

        pos, dv, ds, _ = points[j]
        v, s = BandLimit.sync_shape(@wave_type, w, pos)
        forward ? [v - dv, s - ds] : [v, s]
      end

      def pad_residual(r, length)
        return r[0...length] if r.length >= length

        r.class.zeros(length).tap { |z| z[0...r.length] = r }
      end

      # Queues a band-limited step (see #phase_jump) for a wavetable tone
      # whose phase jumped from +before+ to +after+ (cycles; sample mode:
      # from source position +position+ to the start), measuring the old
      # waveform in +old_table+ and the new in the current table.
      def table_jump(old_table, before, after, position, freq, width, phase_mod, scan)
        table = current_table
        return unless old_table.mipped? && table.mipped?

        scan = scan.nil? ? 0.0 : scan.to_f
        inc = freq * advance

        if table.mode == :sample
          v0 = old_table.value_at(position, increment: freq * old_table.speed(@sample_rate), sample_rate: @sample_rate, interpolation: @interpolation)
          v1 = table.value_at(@state.table[0], increment: freq * table.speed(@sample_rate), sample_rate: @sample_rate, interpolation: @interpolation)
          s0 = s1 = 0.0
        else
          w = width.nil? ? 0.5 : BandLimit.clamp_width(width.to_f)
          pm = phase_mod / TWOPI
          v0, s0 = table_shape(old_table, before + pm, w, inc, scan)
          v1, s1 = table_shape(table, after + pm, w, inc, scan)
        end

        residual = Tone.jump_residual(v1 - v0, (s1 - s0) * inc)
        residual = residual.real if residual.is_a?(Numo::DComplex) && !table.complex?
        @state.jump_residual = @state.jump_residual ? residual + pad_residual(@state.jump_residual, residual.length) : residual
      end

      # [value, slope per cycle] of a cycle-mode +table+ at phase +e+ (cycles,
      # with phase modulation) warped by width +w+, for a tone moving +inc+
      # cycles per sample.
      def table_shape(table, e, w, inc, scan)
        wf = w == 0.5 ? 1.0 : 0.5 / [w, 1.0 - w].min
        m = inc.abs * wf
        x = e - e.floor
        u = w == 0.5 ? x : BandLimit.warp(x, w)
        k = w == 0.5 ? 1.0 : (x < w ? 0.5 / w : 0.5 / (1.0 - w))
        value = table.value_at(u, scan: scan, increment: m, sample_rate: @sample_rate, interpolation: @interpolation, scan_wrap: @scan_wrap)

        # The exact slope from the table's harmonics (see
        # Wavetable::KernelRuby.spectral_derivs)
        spec = table.kernel_spec(@sample_rate, @interpolation, scan_wrap: @scan_wrap)
        dre = [0.0, 0.0]
        dim = [0.0, 0.0]
        kr = MB::Sound::Wavetable::KernelRuby
        kr.spectral_derivs(spec, u, kr.select(spec, m, scan.to_f), 2, dre, dim)
        slope = table.complex? ? Complex(dre[1], dim[1]) : dre[1]

        [value, slope * k]
      end

      # Multiplies +buf+ (the output view) by the #gain input in place: in C
      # (FastArithmetic.scale, no allocation) when it can, else with Numo;
      # both give the same values as a following Multiplier.
      def apply_output_gain(buf, out_gain)
        return if MB::Sound::FastArithmetic.scale(buf, out_gain)

        buf.inplace * out_gain
      end

      # Adds any queued phase jump step (see #phase_jump) to +buf+, scaled
      # by the output gain.
      def add_jump_residual(buf)
        residual = @state.jump_residual
        return unless residual

        n = [buf.length, residual.length].min
        buf[0...n] += residual[0...n] * @gain
        @state.jump_residual = n < residual.length ? residual[n..].dup : nil
      end

      # True if an input needed for the next samples has ended.
      def missing_input?(freq, phase, width, pulses, resets, targets, scan = nil, fb = 0, fb_gain = 1, out_gain = 1)
        freq.nil? || phase.nil? || (warped? && width.nil?) || (@sync_source && pulses.nil?) ||
          (@reset_to.respond_to?(:sample) && targets.nil?) || (@scan.respond_to?(:sample) && scan.nil?) ||
          (@feedback && (fb.nil? || fb_gain.nil?)) || (@out_gain && out_gain.nil?)
      end

      # True if this is a sample-mode one-shot (see Wavetable) that has
      # played to its end without a reset input to restart it.
      def one_shot_ended?
        return false unless wavetable? && @reset.nil? && @state

        table = current_table
        table.one_shot? && @state.table[0] >= table.size
      end

      # The table a #wavetable tone plays now (for a KeyMap, the zone picked
      # by #pick_zone).
      def current_table
        return Tone.complex_table(@wave_type) unless wavetable?
        return @table unless @table.is_a?(MB::Sound::Wavetable::KeyMap)

        @zone_table || @table.tables[0]
      end

      # Picks a KeyMap zone from the frequency +freq+ (Hz; a number or the
      # first value of an NArray).
      def pick_zone(freq)
        @zone_table = @table.table_for_frequency(input_at(freq, 0))
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

      # The indices of the nonzero samples of the timeline jumps input (see
      # #follow_timeline), or nil if there are none.  The tempo node's
      # shared frozen zeros are recognized without a scan.
      def lock_points(jumps)
        return nil if jumps.nil? || jumps.equal?(@quiet_locks)

        if jumps.frozen? && jumps.max == 0 && jumps.min == 0
          @quiet_locks = jumps
          return nil
        end

        points = jumps.ne(0).where
        points.empty? ? nil : points.to_a
      end

      # Computes +count+ samples split into pieces at the sample indices of
      # timeline jumps (+locks+, see #follow_timeline) and resets (+points+,
      # see #reset), jumping the phase before each of those samples (a
      # timeline jump first, then a reset, at the same sample).  Each jump
      # is band-limited at that sample's frequency, phase modulation, and
      # width (see #phase_jump).  The block runs a kernel (#kernel_c or
      # #kernel_ruby) on a view of the output buffer with the matching
      # slices of the frequency, phase modulation, and width inputs, and
      # returns the samples.  Returns a view of the output buffer.
      def sample_segments(count, freq, phase, width, points, targets, locks = nil, jump_phase = nil, scan = nil, fb = nil, fb_gain = nil)
        state = @state
        state.frame_segments = [] if @ports

        splits = locks ? (points ? (points | locks).sort : locks) : points

        start = 0
        (splits + [count]).each do |stop|
          if stop > start
            f = slice_input(freq, start, stop)
            state.frame_segments&.push([state.phase[0], f, stop - start])

            out = @osc_buf[start...stop].inplace!
            result = yield(
              out, f, slice_input(phase, start, stop), slice_input(width, start, stop), slice_input(scan, start, stop),
              slice_input(fb, start, stop), slice_input(fb_gain, start, stop)
            )
            out[true] = result unless result.equal?(out)
            add_jump_residual(out)
          end

          break if stop == count

          jump_args = { freq: input_at(freq, stop), width: width && input_at(width, stop), phase_mod: input_at(phase, stop) }
          jump_args[:scan] = input_at(scan, stop) if table_kernel?
          if locks&.include?(stop)
            target = @start_cycles + jump_phase[stop]
            phase_jump(**jump_args) { state.phi = target }
          end

          reset_jump(jump_args, reset_target(targets, stop)) if points&.include?(stop)

          start = stop
        end

        @osc_buf[0...count].inplace!
      end

      # The phase in cycles for a reset at sample +i+ (see #reset).
      def reset_target(targets, i)
        reset_target_value(targets && input_at(targets, i))
      end

      # The phase in cycles for a reset whose target input (see #reset's
      # +to:+) is +value+ (radians, a Float), or nil without a target input.
      def reset_target_value(value)
        return @state.random if @state.random?
        return value / TWOPI if value
        return @reset_to / TWOPI if @reset_to

        @start_cycles
      end

      # Jumps the phase for a reset to +target+ (cycles; see #reset_target),
      # band-limited at the reset sample's +jump_args+ (see #phase_jump).
      def reset_jump(jump_args, target)
        state = @state
        phase_jump(**jump_args) {
          state.phi = target
          state.feedback.fill(0.0) if @feedback && !@keep_feedback
          if table_kernel?
            # Samples restart; key zones are picked anew
            state.table[0] = 0.0
            pick_zone(jump_args[:freq]) if @table.is_a?(MB::Sound::Wavetable::KeyMap)
          end
        }
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
      def kernel_c(out, freq, phase, width, pulses, scan = nil, fb = nil, fb_gain = nil)
        state = @state
        case kernel
        when :feedback
          MB::Sound::FastSynth.feedback_sine(
            out, freq, phase, @advance, @gain, @offset, state.phase, state.feedback, fb, fb_gain, !@feedback_dc
          ).inplace!
        when :wavetable
          table = current_table
          if @sync_source
            check_sync(phase)
            ensure_sync_ring(table)
            buf = table.sync(
              out, freq, @advance, @gain, @offset, state.sync, state.sync_ring, pulses, @soft_sync, width, scan || 0,
              @interpolation, @sample_rate, !@keep_dc, table.mipped?, scan_wrap: @scan_wrap
            ).inplace!
            state.phase[0] = state.sync[0]
            buf
          elsif clean_table?
            ensure_sync_ring(table)
            pulses, target = reset_pulse(out.length)
            buf = table.sync(
              out, freq, @advance, @gain, @offset, state.sync, state.sync_ring, pulses, false, width, scan || 0,
              @interpolation, @sample_rate, !@keep_dc, true, scan_wrap: @scan_wrap, reset_phase: target
            ).inplace!
            sync_next_phase
            buf
          elsif table.mode == :cycle
            table.oscillate(
              out, freq, @advance, @gain, @offset, state.phase, state.table, phase, width, scan || 0,
              @interpolation, @sample_rate, !@keep_dc, @random_advance, state.noise, scan_wrap: @scan_wrap
            ).inplace!
          else
            table.play(
              out, freq, @advance, table.speed(@sample_rate), @gain, @offset, state.phase, state.table,
              @interpolation, @sample_rate
            ).inplace!
          end
        when :sync
          check_sync(phase)
          r0, r1, r2, m1, m2, sine = BandLimit.sync_tables(@wave_type)
          buf = MB::Sound::FastSynth.oscillate_sync(
            out, @wave_type, freq, @advance, @gain, @offset,
            state.sync, state.sync_ring, pulses, @soft_sync, width, !@keep_dc,
            r0, r1, r2, BandLimit::SYNC_OVERSAMPLE, BandLimit::SYNC_TAPS, !!band_limit_setting, m1, m2, sine
          ).inplace!
          state.phase[0] = state.sync[0]
          buf
        when :reset_sync
          r0, r1, r2, m1, m2, sine = BandLimit.sync_tables(@wave_type)
          pulses, target = reset_pulse(out.length)
          buf = MB::Sound::FastSynth.oscillate_sync(
            out, @wave_type, freq, @advance, @gain, @offset,
            state.sync, state.sync_ring, pulses, false, width, !@keep_dc,
            r0, r1, r2, BandLimit::SYNC_OVERSAMPLE, BandLimit::SYNC_TAPS, true, m1, m2, sine, target
          ).inplace!
          sync_next_phase
          buf
        when :blit
          MB::Sound::FastSynth.blit(
            out, @wave_type, freq, @advance, @gain, @offset, state.phase, state.blit
          ).inplace!
        when :synth
          MB::Sound::FastSynth.oscillate_bl(
            out, @wave_type, freq, phase, @advance, @gain, @offset,
            state.phase, state.blep, @fade_band[0], @fade_band[1], width, !@keep_dc
          ).inplace!
        when :phasor
          MB::FastSound.phasor(out, freq, @advance, @random_advance, state.phase, nil, state.noise).inplace!
        else
          MB::FastSound.oscillate(
            out, @wave_type, freq, phase, @advance, @random_advance, @gain, @offset, state.phase, state.noise
          ).inplace!
        end
      end

      # Ruby mirror of #kernel_c: computes out.length samples and stores
      # them in +out+ (an inplace view of the output buffer), returning it.
      def kernel_ruby(out, freq_table, phase_table, width, pulses, scan = nil, fb = nil, fb_gain = nil)
        count = out.length
        state = @state

        case kernel
        when :feedback
          values = feedback_ruby(count, freq_table, phase_table, fb, fb_gain)
        when :wavetable
          table = current_table
          if @sync_source
            check_sync(phase_table)
            ensure_sync_ring(table)
            values = table.sync_ruby(
              out.dup, freq_table, @advance, @gain, @offset, state.sync, state.sync_ring, pulses, @soft_sync, width, scan || 0,
              @interpolation, @sample_rate, !@keep_dc, table.mipped?, scan_wrap: @scan_wrap
            )
            state.phase[0] = state.sync[0]
          elsif clean_table?
            ensure_sync_ring(table)
            pulses, target = reset_pulse(count)
            values = table.sync_ruby(
              out.dup, freq_table, @advance, @gain, @offset, state.sync, state.sync_ring, pulses, false, width, scan || 0,
              @interpolation, @sample_rate, !@keep_dc, true, scan_wrap: @scan_wrap, reset_phase: target
            )
            sync_next_phase
          elsif table.mode == :cycle
            values = table.oscillate_ruby(
              out.dup, freq_table, @advance, @gain, @offset, state.phase, state.table, phase_table, width, scan || 0,
              @interpolation, @sample_rate, !@keep_dc, @random_advance, state.noise, scan_wrap: @scan_wrap
            )
          else
            values = table.play_ruby(
              out.dup, freq_table, @advance, table.speed(@sample_rate), @gain, @offset, state.phase, state.table,
              @interpolation, @sample_rate
            )
          end
        when :sync
          check_sync(phase_table)
          r0, r1, r2, m1, m2, sine = BandLimit.sync_tables(@wave_type)
          values = BandLimit.sync_ruby(
            count, @wave_type, freq_table, @advance, @gain, @offset,
            state.sync, state.sync_ring, pulses, @soft_sync, width, !@keep_dc,
            r0, r1, r2, BandLimit::SYNC_OVERSAMPLE, BandLimit::SYNC_TAPS, !!band_limit_setting, m1, m2, sine
          )
          state.phase[0] = state.sync[0]
        when :reset_sync
          r0, r1, r2, m1, m2, sine = BandLimit.sync_tables(@wave_type)
          pulses, target = reset_pulse(count)
          values = BandLimit.sync_ruby(
            count, @wave_type, freq_table, @advance, @gain, @offset,
            state.sync, state.sync_ring, pulses, false, width, !@keep_dc,
            r0, r1, r2, BandLimit::SYNC_OVERSAMPLE, BandLimit::SYNC_TAPS, true, m1, m2, sine, target
          )
          sync_next_phase
        when :blit
          values = BandLimit.blit_ruby(count, @wave_type, freq_table, @advance, @gain, @offset, state.phase, state.blit)
        when :synth
          values = BandLimit.oscillate_ruby(
            count, @wave_type, freq_table, phase_table, @advance, @gain, @offset,
            state.phase, state.blep, *@fade_band, width, !@keep_dc
          )
        when :phasor
          phases, _increments = phases_ruby(freq_table, count)
          values = Numo::SFloat.cast(phases)
        else
          phases, increments = phases_ruby(freq_table, count)
          values = if @plan_fast_shapes
                     MB::Sound::Plan::FastMath.shape_ruby(@wave_type, phases, phase_table) * @gain + @offset
                   else
                     Tone.shape_ruby(@wave_type, phases, increments, phase_table) * @gain + @offset
                   end
        end

        values = values.real if !out.is_a?(Numo::SComplex) && values.is_a?(Numo::DComplex)
        out[true] = values
        out
      end

      # Advances the phase over +count+ samples at +freq+ (Hz; a Numeric or
      # an NArray of +count+ values) in Ruby, returning [phases, increments]
      # as DFloat NArrays (increments is a Float if every sample advances by
      # the same amount).  The same math as MB::FastSound.phasor: phase[i] =
      # phi + sum(increments[0...i]) (i * increment when constant), wrapped
      # once to 0...1.
      def phases_ruby(freq, count)
        freq = Numo::DFloat.cast(freq) if freq.is_a?(Numo::NArray)

        if @random_advance != 0
          rng = @state.noise
          random = Numo::DFloat.cast(Array.new(count) { Tone.noise_random(rng) })
          increments = freq * (random * @random_advance + @advance)
        else
          increments = freq * @advance
        end

        if increments.is_a?(Numo::NArray)
          # Running sum: phase i has advanced by increments 0...i
          sums = increments.cumsum
          steps = Numo::DFloat.zeros(count)
          steps[1..] = sums[0...-1] if count > 1
          total = sums[-1]
        else
          steps = Numo::DFloat.new(count).seq * increments
          total = increments * count
        end

        phi = @state.phi
        phases = steps + phi
        phases -= phases.floor # like Ruby's %, not Numo's (which keeps the sign)
        @state.phi = phi + total

        [phases, increments]
      end

      # Complex tables keep imaginary sync corrections after the real ones.
      def ensure_sync_ring(table)
        taps = BandLimit::SYNC_TAPS * (table.complex? ? 2 : 1)
        @state.sync_ring = Numo::DFloat.zeros(taps) if @state.sync_ring.length != taps
      end

      # Raises an error for settings a #wavetable tone can't play.
      def check_wavetable
        tables = @table.is_a?(MB::Sound::Wavetable::KeyMap) ? @table.tables : [@table]
        if random_advance != 0 && (@sync_source || tables.any? { |t| t.mode == :sample })
          raise ArgumentError, 'Synced and sample-mode wavetable tones cannot be noise'
        end
        if tables.any? { |t| t.mode == :sample }
          raise ArgumentError, 'Sample-mode wavetables take no phase modulation' if @phase_mod && @phase_mod != 0
          raise ArgumentError, 'Sample-mode wavetables take no phase warp (pwm)' if warped?
          raise ArgumentError, 'Sample-mode wavetables cannot be synced' if @sync_source
        end
      end

      # Raises an error for settings a #feedback tone can't play.
      def check_feedback
        raise ArgumentError, "Only sines take feedback (this is a #{wave_name})" unless @wave_type == :sine
        raise ArgumentError, 'A feedback sine cannot be synced' if @sync_source
        raise ArgumentError, 'A feedback sine cannot be warped (pwm)' if warped?
        raise ArgumentError, 'A feedback sine cannot be noise' if random_advance != 0
      end

      # The DC tracker's cutoff relative to the frequency (FB_DC_RATIO in
      # fast_synth.c; see #feedback).
      FEEDBACK_DC_RATIO = 1.0 / 20.0

      # Ruby mirror of FastSynth.feedback_sine (see #feedback): the same
      # phases as the naive kernel (#phases_ruby), then the feedback loop
      # one sample at a time with the C kernel's operations in its order.
      def feedback_ruby(count, freq, phase_mod, fb, fb_gain)
        phases, increments = phases_ruby(freq, count)
        y1, y2, dc = @state.feedback
        remove_dc = !@feedback_dc
        dc_k = 2.0 * Math::PI * FEEDBACK_DC_RATIO
        values = Numo::DFloat.zeros(count)
        count.times do |i|
          pm = input_at(phase_mod, i)
          b = input_at(fb, i)
          lvl = input_at(fb_gain, i)

          radians = phases[i] * TWOPI
          avg = y1 + y2
          avg = avg * 0.5
          m = b * avg
          arg = radians + pm
          arg = arg + m
          y = Math.sin(arg) * lvl
          y2 = y1
          y1 = y

          v = y
          if remove_dc
            inc = increments.is_a?(Numo::NArray) ? increments[i] : increments
            c = inc.abs * dc_k
            c = 1.0 if c > 1.0
            dc = dc + (y - dc) * c
            v = y - dc
          end
          values[i] = v * @gain + @offset
        end
        @state.feedback[0] = y1
        @state.feedback[1] = y2
        @state.feedback[2] = dc
        values
      end

      def check_sync(phase_mod)
        unless BandLimit::WARP_WAVES.include?(@wave_type) || table_kernel?
          raise ArgumentError, "A #{wave_name} can't be synced (only #{BandLimit::WARP_WAVES.join(', ')}, band-limited complex shapes, or wavetables)"
        end
        raise ArgumentError, 'A synced oscillator cannot also have phase modulation' unless phase_mod == 0 || phase_mod.nil?
      end

      # Which kernel computes samples: :sync, :blit, :synth (FastSynth
      # band-limited or warped), :phasor, or :naive (FastSound), cached
      # (with the advance, gain, and band-limit fade) until a setting
      # changes.
      def kernel
        @kernel ||= begin
          compute_advance
          @fade_band = band_limit_fade
          if wavetable?
            check_wavetable
            :wavetable
          elsif complex_table?
            :wavetable
          elsif phasor?
            :phasor
          elsif @feedback
            check_feedback
            :feedback
          elsif @sync_source
            :sync
          elsif reset_sync?
            :reset_sync
          elsif blit?
            :blit
          elsif synth_kernel?
            :synth
          else
            :naive
          end
        end
      end

      # The main output for GraphNode::Ports.
      def sample_main(count)
        sample_c(count)
      end

      # Port data from the phases of the frame just computed (the phase,
      # without phase modulation; see BandLimit.sync_pulses).
      def compute_ports(count)
        state = @state
        if state.frame_segments
          # Resets split the frame into pieces (see #sample_segments)
          parts = state.frame_segments.map { |phi, freq, n| BandLimit.sync_pulses(phi, freq, advance, n, state.pulses) }
          pulses = parts[0][0].concatenate(*parts[1..].map(&:first))
          increments = parts[0][1].concatenate(*parts[1..].map(&:last))
        else
          pulses, increments = BandLimit.sync_pulses(state.frame_phase, state.frame_freq, advance, count, state.pulses)
        end
        store_port(:wraps, pulses)
        store_port(:increment, increments)
      end

      # [low, high] frequencies (Hz) for fading band-limiting in, or [0, 0]
      # for always on.
      def band_limit_fade
        return BandLimit::NEVER unless band_limited?

        bl = band_limit_setting
        return ALWAYS unless bl.is_a?(Range)

        [bl.begin.to_f, bl.end.to_f].freeze
      end

      # True if this #clean tone's phase jumps (reset inputs, key sync, timeline
      # jumps) run through the synced oscillator kernel as hard sync events
      # on their samples (FastSynth.oscillate_sync with a reset phase), so
      # resets are exactly as clean as sync: the whole tone is the naive
      # waveform through the minBLEP's minimum-phase filter (about 2.8
      # samples of delay; edges alias -95 dB or less instead of PolyBLEP's
      # -35), with each jump an exact event.  For band-limited (or warped)
      # ramps, squares, triangles, and warped sines and parabolas, with a
      # reset input or a timeline, without phase modulation, noise, an LFO
      # fade, or sync.  Other tones (the default, user's choice 2026-10-08:
      # predictable cost) queue a minBLEP step with the ideal step's area
      # (Tone.jump_residual).
      def reset_sync?
        @clean && (!@reset.nil? || !@lock.nil?) && @sync_source.nil? && band_limit_setting == true && synth_kernel? &&
          random_advance == 0 && (@phase_mod.nil? || @phase_mod == 0) && BandLimit::WARP_WAVES.include?(@wave_type)
      end

      # [pulses, target] for the reset-sync kernel (see #reset_sync?): a
      # pulse of 1 on the first sample of +count+ and the reset target if a
      # phase jump is pending (see #phase_jump), else [nil, nil].
      def reset_pulse(count)
        target = @sync_reset
        return [nil, nil] if target.nil?

        @sync_reset = nil
        pulses = Numo::SFloat.zeros(count)
        pulses[0] = 1.0
        [pulses, target]
      end

      # Sets state.phase (the phase of the next sample, as the free-running
      # kernels leave it) from the synced kernel's state (the phase of the
      # last sample, which moves by the last increment into the next).
      def sync_next_phase
        sync = @state.sync
        @state.phase[0] = BandLimit.wrap(sync[0] + sync[2] * sync[1])
      end

      # True if samples come from the band-limiting kernel (band-limited or
      # warped waveforms).
      def synth_kernel?
        band_limited? || (warped? && BandLimit::WARP_WAVES.include?(@wave_type) && random_advance == 0)
      end

      # An inplace view of the first +count+ samples of the output buffer,
      # reused while the buffer and count stay the same (a new view and
      # Range every buffer were a top allocation site).  Only for kernels
      # that return the view they write (a Marshal copy of a Tone has a
      # cached view that is no longer a view of its @osc_buf).
      def osc_view(count)
        view = @osc_view
        unless view && @osc_view_buf.equal?(@osc_buf) && view.length == count
          @osc_view_buf = @osc_buf
          view = @osc_view = @osc_buf[0...count]
        end
        view.inplace!
      end

      # TODO: use BufferHelper?
      def build_buffer(count)
        buf_class = BUFFER_CLASS[@wave_type] || (wavetable? && current_table.complex? ? Numo::SComplex : Numo::SFloat)
        if @osc_buf.nil? || @osc_buf.class != buf_class || @osc_buf.length != count
          old_length = @osc_buf&.length || 0
          @osc_buf = buf_class.zeros(MB::M.max(count, old_length))
        end
      end

      # This retrieves the upstream input buffers, finds whichever is
      # shortest, truncates to that length, and returns the new count and
      # buffers.
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

        pulses = @sync_source
        if pulses.respond_to?(:sample)
          pulses = pulses.sample(count)
          pulses = nil if pulses&.empty?
          min_length = pulses.length if pulses && pulses.length < min_length
        end

        resets = @state.reset_ended ? nil : @reset
        if resets
          resets = resets.sample(count)
          resets = nil if resets&.empty?
          @state.reset_ended = true if resets.nil?
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

        scan = @scan
        if scan.respond_to?(:sample)
          scan = scan.sample(count)
          scan = nil if scan&.empty?
          min_length = scan.length if scan && scan.length < min_length
        end

        fb = @feedback
        fb_gain = @feedback_gain
        if fb
          if fb.respond_to?(:sample)
            fb = fb.sample(count)
            fb = nil if fb&.empty?
            min_length = fb.length if fb && fb.length < min_length
          end
          if fb_gain.respond_to?(:sample)
            fb_gain = fb_gain.sample(count)
            fb_gain = nil if fb_gain&.empty?
            min_length = fb_gain.length if fb_gain && fb_gain.length < min_length
          end
        end

        out_gain = @out_gain
        if out_gain.respond_to?(:sample)
          out_gain = out_gain.sample(count)
          out_gain = nil if out_gain&.empty?
          min_length = out_gain.length if out_gain && out_gain.length < min_length
        end

        # Timeline jumps (see #follow_timeline); a tempo node never ends
        if @lock
          jumps = @lock.sample(count)
          jump_phase = @lock_phase.sample(count)
          jumps = nil if jumps&.empty? || jump_phase.nil? || jump_phase.empty?
          min_length = jumps.length if jumps && jumps.length < min_length
        end

        if min_length != count
          raise "Truncation happened more than once on oscillator #{self} (try adding .with_buffer to upstreams)" if @truncated
          @truncated = true
          freq = freq[0...min_length] if freq&.is_a?(Numo::NArray)
          phase = phase[0...min_length] if phase&.is_a?(Numo::NArray)
          width = width[0...min_length] if width&.is_a?(Numo::NArray)
          pulses = pulses[0...min_length] if pulses&.is_a?(Numo::NArray)
          resets = resets[0...min_length] if resets&.is_a?(Numo::NArray)
          targets = targets[0...min_length] if targets&.is_a?(Numo::NArray)
          jumps = jumps[0...min_length] if jumps&.is_a?(Numo::NArray)
          jump_phase = jump_phase[0...min_length] if jump_phase&.is_a?(Numo::NArray)
          scan = scan[0...min_length] if scan&.is_a?(Numo::NArray)
          fb = fb[0...min_length] if fb&.is_a?(Numo::NArray)
          fb_gain = fb_gain[0...min_length] if fb_gain&.is_a?(Numo::NArray)
          out_gain = out_gain[0...min_length] if out_gain&.is_a?(Numo::NArray)
        end

        # One Array reused by every call (destructured by the callers), not
        # a new one per buffer
        ret = (@upstream_inputs ||= Array.new(13))
        ret[0] = min_length
        ret[1] = freq
        ret[2] = phase
        ret[3] = width
        ret[4] = pulses
        ret[5] = resets
        ret[6] = targets
        ret[7] = jumps
        ret[8] = jump_phase
        ret[9] = scan
        ret[10] = fb
        ret[11] = fb_gain
        ret[12] = out_gain
        ret
      end

      # Warns that a call replaced an earlier conflicting setting (the last
      # call wins; see #reset, #free, #random_phase).
      def override_warning(message)
        warn "Tone #{wave_name} #{make_source_name(@frequency)}: #{message}"
      end

      # See #sync and #softsync.
      def set_sync(master, ratio, soft)
        raise ArgumentError, 'A tone with a reset input cannot also be synced' if @reset
        raise ArgumentError, 'Give a master or a ratio:, not both' if master && ratio
        raise ArgumentError, 'Give a master (e.g. C2) or ratio: (e.g. ratio: 2.5)' if master.nil? && ratio.nil?

        configure do
          if master.nil?
            # A hidden master at this tone's pitch; this tone plays ratio times higher
            hidden = Tone.new(wave_type: :phasor, frequency: @frequency, sample_rate: @sample_rate)
            ratio = fixup_source(ratio)
            set_frequency(@frequency.is_a?(Numeric) && ratio.is_a?(Numeric) ? @frequency * ratio : fixup_source(ratio.is_a?(Numeric) ? @frequency * ratio : ratio * @frequency))
            pulses = hidden.wraps
          else
            pulses = case master
                     when Pitch then master.phasor.wraps
                     when Tone then master.wraps
                     else
                       raise ArgumentError, "Sync master must be a Pitch, Tone, or a graph node (got #{master.inspect})" unless master.respond_to?(:sample)
                       master
                     end
          end

          @sync_source = pulses.respond_to?(:get_sampler) ? pulses.get_sampler : pulses
          @soft_sync = soft
        end
      end

      # Sets the wave type and whether it's band-limited (see #ramp, #aramp).
      def set_wave(wave_type, band_limit)
        configure do
          @wave_type = wave_type
          @band_limit = band_limit
        end
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

        unless freq.is_a?(Numeric) || freq.respond_to?(:sample)
          raise ArgumentError, "Invalid frequency #{freq.inspect}"
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
      end

      # Configures the source given as the frequency, FM amount, PM amount,
      # etc. for indefinite playback and for this node's sample rate.  Returns
      # a tee'd sampler from the source if it responds to :get_sampler, or the
      # source itself.
      #
      # Returns nil if the source is nil.
      def fixup_source(src)
        return nil if src.nil?

        # A cycle exists only if this tone is +src+ or feeds +src+.  A node
        # that already feeds this tone through another input (e.g. one
        # trigger, through a Tee, resetting both this tone and its vibrato
        # LFO) just adds a second path, which is fine.
        if src.respond_to?(:sources)
          # O(n^2)ish if building a complex network of modulation?
          if src.equal?(self) || src.graph(include_tees: true).any? { |n| n.equal?(self) }
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
