module MB
  module Sound
    class Filter
      # A 4-pole resonant lowpass in the style of the CEM3379 (the SQ-80's
      # voice chip) and CEM3320: four one-pole OTA-C stages in a cascade with
      # resonance feedback around them, simulated with zero-delay feedback
      # (trapezoidal integrators, the loop solved in closed form).  The kernel
      # is MB::Sound::FastFilter.four_pole (the fast_filter extension), with
      # an exact Ruby mirror in .process_ruby.
      #
      # Most code uses GraphNode#lp4 (alias #four_pole), which takes nodes
      # for the cutoff and resonance; this object filters buffers directly
      # and holds the state.
      #
      # Behavior (measured; see the specs):
      # - 24 dB/octave; -12 dB at the cutoff without resonance.
      # - +resonance+ 0..1 sets the loop gain k = curve(resonance) × #k_max.
      #   By default #k_max is MAX_K (3.9, just below the oscillation edge
      #   at 4), so like the SQ-80 the filter rings but never self-oscillates
      #   (peak about +37 dB over the passband at full resonance).
      # - +resonance_curve: :db+ (default) makes the gain at the cutoff rise
      #   linearly in dB, -12 dB at 0 to +33.8 dB at 1 (.resonance_curve; the
      #   resonant peak about +2.7, +14.5, +27.8, +37 dB at 0.2, 0.5, 0.8,
      #   1); :linear is k = resonance × #k_max (+7.5 dB at 0.5, +16.8 at
      #   0.8).  .db_resonance converts a :linear value to the :db value
      #   with the same sound (0.5 -> 0.33, 0.75 -> 0.51, 0.9 -> 0.68).
      #   .quality_to_resonance maps a 2-pole Q to the resonance with
      #   the same gain at the cutoff (GraphNode#lp4's +quality:+).
      # - Passband compensation (+compensation:+, default 0.375 like the
      #   CEM3379): full resonance loses about 6 dB of bass instead of 12.
      #   0 gives a classic Moog-style bass loss.
      # - +self_oscillate: true+ gives the resonance its own curve, the same
      #   for both resonance curves (.self_oscillate_gain), so the knob
      #   behaves like a classic synth's emphasis knob: the bottom 90%
      #   (SELF_OSCILLATE_ONSET) is the chosen resonance curve, compressed so
      #   it reaches the oscillation edge k = 4 at 0.9 (ringing grows to a
      #   long, singing tone near the top of that range); above 0.9 the
      #   filter oscillates, and the rest of the knob is "how much": k rises
      #   from 4 to #k_max = SELF_OSCILLATE_K (5) as the square of the
      #   distance above the onset, so the oscillation's amplitude (about
      #   proportional to sqrt(k - 4)) grows roughly linearly from nothing
      #   at 0.9 to about 0.22 peak at 1 (with drive 1; louder with lower
      #   drive), and it starts faster and pushes the input harder as the
      #   knob rises.  It also turns on the drive (1.0 unless given), whose
      #   saturation sets the amplitude.  (Until 2026-10-07 it raised k_max
      #   to 4.3 on the normal curves: oscillation from 0.74 on the dB
      #   curve, 0.93 linear, and only -20 dB at the top.)
      # - +drive:+ (nil or 0 for linear) is the saturation level, tanh(drive
      #   × v) / drive: unity gain for small signals, saturating above about
      #   1 / drive.  +drive_mode:+ says where: :input (default) on the
      #   cascade's input; :stages in every OTA stage (and the input), as
      #   each stage's drive current saturates; :feedback only on the
      #   resonance feedback (y4 - c x; +clip: :soft+ tanh or :hard, a clamp
      #   with a short knee), so the passband stays clean while the
      #   resonance clips and buzzes (the Korg MS-20's diode-clipper idea on
      #   this 4-pole; not an MS-20 filter emulation).  :stages and
      #   :feedback default to drive 1.  Measurements and renders:
      #   /app/tmp/listening/four_pole/README.md (round 2).
      # - +mode:+ picks an output tap mix (Oberheim Xpander style): :lp4
      #   (default), :lp2, :bp2, :bp4, :hp2, :hp4.  Compensation only
      #   applies to the lowpass modes.
      # - +mode: :diode+ is a TB-303-style diode ladder instead of the OTA
      #   cascade (MB::Sound::FastFilter.diode_ladder; mirror
      #   .diode_process_ruby): four stages that load their neighbors, so
      #   the poles spread, oscillating at loop gain 18.39 (DIODE_EDGE_K)
      #   instead of 4.  The same knobs: the resonant peak is at the cutoff,
      #   the resonance 0..1 sits the same distance from oscillation as
      #   lp4's (curves scaled by DIODE_SCALE; the :db curve takes the gain
      #   at the cutoff from -25.3 dB at 0 to +32.3 dB at 1, linear in dB),
      #   +self_oscillate:+ has the same onset and rise, and compensation
      #   and drive work alike (:input or :feedback).  It is darker than
      #   lp4 at low resonance (-25 dB at the cutoff, the poles spread below
      #   it; slopes about 14, 18, and 22 dB/octave over the first three
      #   octaves), so it wants resonance, like a 303.
      class FourPole < Filter
        # Loop gain at full resonance by default (no self-oscillation).
        MAX_K = 3.9

        # Loop gain at full resonance with +self_oscillate: true+ (see
        # .self_oscillate_gain).
        SELF_OSCILLATE_K = 5.0

        # The resonance where a +self_oscillate: true+ filter starts
        # oscillating, and the loop gain there (the oscillation edge).
        SELF_OSCILLATE_ONSET = 0.9
        SELF_OSCILLATE_EDGE = 4.0

        # The CEM3379's passband compensation (6 dB bass loss at k = 4).
        COMPENSATION = 0.375

        # Lowest cutoff in Hz, and highest as a fraction of the sample rate
        # (the kernel clamps to these).
        MIN_CUTOFF = 1.0
        MAX_CUTOFF_RATIO = 0.49

        # With +self_oscillate: true+, the first integrator starts (and
        # resets) this far from rest, like the noise that starts a real
        # filter oscillating; silence would otherwise stay silent.
        SELF_OSCILLATE_SEED = 1e-4

        # States smaller than this are flushed to zero after each buffer.
        FLUSH = 1e-30

        # Output gains for the cascade input and the four stage outputs.
        MODES = {
          lp4: [0.0, 0.0, 0.0, 0.0, 1.0],
          lp2: [0.0, 0.0, 1.0, 0.0, 0.0],
          bp2: [0.0, 2.0, -2.0, 0.0, 0.0],
          bp4: [0.0, 0.0, 4.0, -8.0, 4.0],
          hp2: [1.0, -2.0, 1.0, 0.0, 0.0],
          hp4: [1.0, -4.0, 6.0, -4.0, 1.0],
          diode: [0.0, 0.0, 0.0, 0.0, 1.0], # the diode ladder's fourth stage
        }.freeze

        # Modes that use passband compensation by default.
        LOWPASS_MODES = [:lp4, :lp2, :diode].freeze

        # The diode ladder (+mode: :diode+; see fast_filter.c): its
        # oscillation frequency in units of the stages' angular frequency is
        # sqrt(10/7) (DIODE_INV_W180 is the inverse), where the loop
        # oscillates at k = 901/49 (DIODE_EDGE_K); its curves are lp4's
        # scaled by DIODE_SCALE (DIODE_EDGE_K / 4).
        DIODE_INV_W180 = 0.8366600265340756
        DIODE_EDGE_K = 18.387755102040817
        DIODE_INV_EDGE_K = 0.05438401775804661
        DIODE_SCALE = 4.596938775510204

        # The diode ladder's dB curve: its top loop gain (0.975 ×
        # DIODE_EDGE_K) and log2(40 + 39 × DIODE_EDGE_K), the gain ratio at
        # the cutoff between r = 1 and 0 (.diode_resonance_curve).
        DIODE_CURVE_K = 17.928061224489795
        DIODE_CURVE_LOG2_RATIO = 9.564382835097447

        # Resonance curves (the kernel's +curve+ argument): :db (default)
        # makes the gain at the cutoff rise linearly in dB; :linear is the
        # loop gain k = resonance × #k_max (round 1).
        RESONANCE_CURVES = { linear: 0, db: 1 }.freeze

        # The kernel's +curve+ argument with +self_oscillate: true+ (see
        # .self_oscillate_gain), by resonance curve.
        SELF_OSCILLATE_CURVES = { linear: 2, db: 3 }.freeze

        # Drive modes (the kernel's +drive_mode+): where the saturation is.
        DRIVE_MODES = { input: 0, stages: 1, feedback: 2 }.freeze

        # Clipper shapes for +drive_mode: :feedback+.
        CLIPS = { soft: 0, hard: 1 }.freeze

        # The dB curve's top loop gain, and log2(4 (1 + k) / (4 - k)) there
        # (log2(196): the gain ratio at the cutoff between r = 1 and 0).
        CURVE_K = 3.9
        CURVE_LOG2_RATIO = 7.6147098441152083
        LN2 = 0.69314718055994529

        # 1 / i! for i = 0..13: the kernel's Taylor series for 2^y.
        EXP_TAYLOR = [
          1.0, 1.0, 0.5, 0.16666666666666666, 0.041666666666666664, 0.0083333333333333332,
          0.0013888888888888889, 0.00019841269841269841, 2.4801587301587302e-05,
          2.7557319223985893e-06, 2.7557319223985888e-07, 2.505210838544172e-08,
          2.08767569878681e-09, 1.6059043836821613e-10,
        ].freeze

        attr_reader :sample_rate, :cutoff, :resonance, :mode, :drive, :compensation, :k_max,
          :resonance_curve, :drive_mode, :clip

        # Creates a filter at +cutoff+ Hz with +resonance+ 0..1 (see the
        # class description for the options).
        def initialize(
          cutoff: 1000.0, resonance: 0.0, mode: :lp4, drive: nil, self_oscillate: false, compensation: nil,
          resonance_curve: :db, drive_mode: :input, clip: :soft, sample_rate: 48000
        )
          raise ArgumentError, "Unknown four-pole mode #{mode.inspect} (use one of #{MODES.keys.join(', ')})" unless MODES.include?(mode)
          raise ArgumentError, "Unknown resonance curve #{resonance_curve.inspect} (use :db or :linear)" unless RESONANCE_CURVES.include?(resonance_curve)
          raise ArgumentError, "Unknown drive mode #{drive_mode.inspect} (use :input, :stages, or :feedback)" unless DRIVE_MODES.include?(drive_mode)
          raise ArgumentError, "Unknown clip #{clip.inspect} (use :soft or :hard)" unless CLIPS.include?(clip)
          raise ArgumentError, 'clip: only applies to drive_mode: :feedback' if clip != :soft && drive_mode != :feedback
          raise ArgumentError, 'The diode ladder takes drive_mode: :input or :feedback' if mode == :diode && drive_mode == :stages

          @mode = mode
          @resonance_curve = resonance_curve
          @drive_mode = drive_mode
          @clip = clip
          @self_oscillate = !!self_oscillate
          @k_max = @self_oscillate ? SELF_OSCILLATE_K : MAX_K

          drive = 1.0 if (@self_oscillate || drive_mode != :input) && (drive.nil? || drive == 0)
          @drive = drive.nil? || drive == false ? 0.0 : Float(drive)
          raise ArgumentError, "Drive must be a positive number or nil (got #{drive.inspect})" unless @drive >= 0 && @drive.finite?

          @compensation = Float(compensation || (LOWPASS_MODES.include?(mode) ? COMPENSATION : 0.0))
          @mix = MODES.fetch(mode)

          @sample_rate = sample_rate.to_f
          raise ArgumentError, 'Sample rate must be positive' unless @sample_rate > 0

          self.cutoff = cutoff
          self.resonance = resonance

          @state = [0.0, 0.0, 0.0, 0.0]
          reset(0)
        end

        # True for the diode ladder (+mode: :diode+).
        def diode?
          @mode == :diode
        end

        # Whether the resonance may reach self-oscillation.
        def self_oscillate?
          @self_oscillate
        end

        # Sets the cutoff used by #process (Hz).
        def cutoff=(hz)
          @cutoff = Float(hz)
        end

        # Sets the resonance used by #process (0..1).
        def resonance=(r)
          @resonance = Float(r)
        end

        # Changes the sample rate (the state is kept).
        def sample_rate=(rate)
          raise ArgumentError, 'Sample rate must be positive' unless rate.to_f > 0
          @sample_rate = rate.to_f
        end

        # Filters +samples+ (an NArray) with the current #cutoff and
        # #resonance, returning a new SFloat (or +samples+ itself, filtered in
        # place, if it is an inplace SFloat).
        def process(samples)
          dynamic_process(samples, cutoff: @cutoff, resonance: @resonance)
        end

        # Filters +samples+ with +cutoff+ and +resonance+ given as numbers or
        # NArrays of the same length (read per sample).
        def dynamic_process(samples, cutoff:, resonance:)
          samples = samples.real if samples.is_a?(Numo::SComplex) || samples.is_a?(Numo::DComplex)
          out = if diode?
                  MB::Sound::FastFilter.diode_ladder(samples, cutoff, resonance, @state, @sample_rate, @k_max, @compensation, @drive, *kernel_options)
                else
                  MB::Sound::FastFilter.four_pole(samples, cutoff, resonance, @state, @sample_rate, @k_max, @compensation, @drive, @mix, *kernel_options)
                end
          remember(cutoff, resonance)
          out
        end

        # Same as #dynamic_process, through the Ruby mirror (slow; for specs).
        def dynamic_process_ruby(samples, cutoff:, resonance:)
          samples = samples.real if samples.is_a?(Numo::SComplex) || samples.is_a?(Numo::DComplex)
          out = if diode?
                  self.class.diode_process_ruby(samples, cutoff, resonance, @state, @sample_rate, @k_max, @compensation, @drive, *kernel_options)
                else
                  self.class.process_ruby(samples, cutoff, resonance, @state, @sample_rate, @k_max, @compensation, @drive, @mix, *kernel_options)
                end
          remember(cutoff, resonance)
          out
        end

        # Sets the state as if +value+ had been the input for a long time
        # (the steady state of the linear filter at the last resonance).
        def reset(value = 0)
          value = value.to_f
          k = loop_gain
          # Every stage holds the lowpass level, whatever the output mix
          dc = value * (1.0 + @compensation * k) / (1.0 + k)
          @state = [dc, dc, dc, dc]
          @state[0] += SELF_OSCILLATE_SEED if @self_oscillate
          self
        end

        # A copy of the integrator states (for specs and debugging).
        def state
          @state.dup
        end

        # The linear complex response at +omega+ (radians per sample; a
        # number or NArray) for the current cutoff and resonance (no drive).
        def response(omega)
          fc = @cutoff.clamp(MIN_CUTOFF, @sample_rate * MAX_CUTOFF_RATIO)
          g = Math.tan(Math::PI * fc / @sample_rate)
          k = loop_gain
          z1 = omega.is_a?(Numo::NArray) ? Numo::NMath.exp(Numo::DComplex.cast(omega) * -1i) : CMath.exp(-1i * omega)

          if diode?
            # The bilinear transform of (1 + c k) / (D(s) + k), D(s) = s^4 +
            # 7 s^3 + 15 s^2 + 10 s + 1, with s in units of the stages'
            # angular frequency (g = tan(pi fc / rate) / sqrt(10/7))
            s = (1 - z1) / ((1 + z1) * (g * DIODE_INV_W180))
            return (1 + @compensation * k) / ((((s + 7) * s + 15) * s + 10) * s + 1 + k)
          end

          # One TPT stage: g (1 + z^-1) / ((1 + g) - (1 - g) z^-1)
          h = g * (z1 + 1) / ((1 + g) - (1 - g) * z1)
          u = (1 + @compensation * k) / (1 + k * h**4)
          m = @mix
          u * (m[0] + m[1] * h + m[2] * h**2 + m[3] * h**3 + m[4] * h**4)
        end

        # The loop gain k for +resonance+ (default: the current #resonance),
        # through the #resonance_curve (or the self-oscillation curve, see
        # .self_oscillate_gain): 0 to #k_max.
        def loop_gain(resonance = @resonance)
          r = resonance.to_f.clamp(0.0, 1.0)
          return self.class.diode_loop_gain(r, kernel_options[0], @k_max) if diode?

          return self.class.self_oscillate_gain(r, @resonance_curve == :db, @k_max) if @self_oscillate

          r = self.class.resonance_curve(r) if @resonance_curve == :db
          r * @k_max
        end

        # Filters +source+ with this filter in a GraphNode::FourPole at the
        # current cutoff and resonance (used by GraphNode#filter).
        def wrap(source, in_place: false)
          MB::Sound::GraphNode::FourPole.new(source, self, cutoff: @cutoff, resonance: @resonance)
        end

        def to_s
          drive = @drive > 0 ? ", drive #{@drive}#{@drive_mode == :input ? '' : " #{@drive_mode}"}#{@clip == :hard ? ' hard' : ''}" : ''
          "#{@mode}(#{@cutoff.round(2)} Hz, r=#{@resonance.round(3)}#{@resonance_curve == :linear ? ' linear' : ''}#{drive}#{@self_oscillate ? ', self-osc' : ''})"
        end

        # The Ruby mirror of MB::Sound::FastFilter.four_pole: the same
        # arguments, the same operations in the same order, and the same
        # samples (specs check every sample).  Returns a new SFloat (the C
        # version filters an inplace SFloat in place).
        def self.process_ruby(buffer, cutoff, resonance, state, sample_rate, k_max, comp, drive, mix, curve = 0, drive_mode = 0, clip = 0)
          rate = sample_rate.to_f
          raise ArgumentError, 'Sample rate must be positive and finite' unless rate > 0 && rate.finite?
          k_max = k_max.to_f
          comp = comp.to_f
          drive = drive.to_f
          raise ArgumentError, 'Filter parameters must be finite (and drive not negative)' unless k_max.finite? && comp.finite? && drive >= 0 && drive.finite?
          raise ArgumentError, 'Resonance curve must be 0 (linear), 1 (dB), 2 (self-oscillating linear), or 3 (self-oscillating dB)' unless [0, 1, 2, 3].include?(curve)
          raise ArgumentError, 'Drive mode must be 0 (input), 1 (stages), or 2 (feedback)' unless [0, 1, 2].include?(drive_mode)
          raise ArgumentError, 'Clip must be 0 (soft) or 1 (hard)' unless [0, 1].include?(clip)
          raise ArgumentError, 'Four-pole state must have four elements' unless state.is_a?(Array) && state.length == 4
          raise ArgumentError, 'Four-pole mix must have five elements' unless mix.is_a?(Array) && mix.length == 5

          m0, m1, m2, m3, m4 = mix.map(&:to_f)
          s0, s1, s2, s3 = state.map { |v| v = v.to_f; v.finite? ? v : 0.0 }

          data = Numo::SFloat.cast(buffer)
          raise ArgumentError, "Only 1D NArrays may be processed (got #{data.ndim} dimensions)" unless data.ndim == 1
          length = data.length
          out = Numo::SFloat.zeros(length)

          fc_arr = signal_input(cutoff, length, 'Cutoff')
          res_arr = signal_input(resonance, length, 'Resonance')
          fc_scalar = fc_arr ? nil : (cutoff.nil? ? 0.0 : cutoff.to_f)
          res_scalar = res_arr ? nil : (resonance.nil? ? 0.0 : resonance.to_f)

          pi_over_rate = Math::PI / rate
          fc_max = rate * MAX_CUTOFF_RATIO
          inv_drive = drive > 0 ? 1.0 / drive : 0.0
          driven = drive > 0

          last_fc = Float::NAN
          last_res = Float::NAN
          g = 0.0
          g_ = 0.0
          g4 = 0.0
          one = 1.0
          k = 0.0
          inv = 1.0
          in_gain = 1.0

          length.times do |i|
            fc = fc_arr ? fc_arr[i] : fc_scalar
            res = res_arr ? res_arr[i] : res_scalar

            if fc != last_fc || res != last_res
              # (NaN != NaN, like C, so NaN inputs recompute every sample)
              if res != last_res
                last_res = res
                if !(res >= 0.0)
                  res = 0.0
                elsif res > 1.0
                  res = 1.0
                end
                k = case curve
                    when 1 then resonance_curve(res) * k_max
                    when 2 then self_oscillate_gain(res, false, k_max)
                    when 3 then self_oscillate_gain(res, true, k_max)
                    else res * k_max
                    end
                in_gain = 1.0 + comp * k
              end

              if fc != last_fc
                last_fc = fc
                if !(fc >= MIN_CUTOFF)
                  fc = MIN_CUTOFF
                elsif fc > fc_max
                  fc = fc_max
                end
                g = tan(fc * pi_over_rate)
                g_ = g / (1.0 + g)
                one = 1.0 - g_
                g2 = g_ * g_
                g4 = g2 * g2
              end

              inv = 1.0 / (1.0 + k * g4)
            end

            x = data[i]
            sum = ((s0 * one * g_ + s1 * one) * g_ + s2 * one) * g_ + s3 * one
            u = (x * in_gain - k * sum) * inv

            ga_ = gb_ = gc_ = gd_ = g_

            if driven
              if drive_mode == 0
                u = tanh(u * drive) * inv_drive
              elsif drive_mode == 2
                r = g4 * u + sum - comp * x
                t = secant(r * drive, clip)
                kt = k * t
                u = (x * (1.0 + comp * kt) - kt * sum) / (1.0 + kt * g4)
              else
                p1 = g_ * (u - s0) + s0
                p2 = g_ * (p1 - s1) + s1
                p3 = g_ * (p2 - s2) + s2
                p4 = g_ * (p3 - s3) + s3
                ga = g * secant((u - p1) * drive, 0)
                gb = g * secant((p1 - p2) * drive, 0)
                gc = g * secant((p2 - p3) * drive, 0)
                gd = g * secant((p3 - p4) * drive, 0)
                ga_ = ga / (1.0 + ga)
                gb_ = gb / (1.0 + gb)
                gc_ = gc / (1.0 + gc)
                gd_ = gd / (1.0 + gd)
                sum2 = ((s0 * (1.0 - ga_) * gb_ + s1 * (1.0 - gb_)) * gc_ + s2 * (1.0 - gc_)) * gd_ + s3 * (1.0 - gd_)
                u = (x * in_gain - k * sum2) / (1.0 + k * (ga_ * gb_ * gc_ * gd_))
                u = tanh(u * drive) * inv_drive
              end
            end

            v = ga_ * (u - s0)
            y1 = v + s0
            s0 = y1 + v
            v = gb_ * (y1 - s1)
            y2 = v + s1
            s1 = y2 + v
            v = gc_ * (y2 - s2)
            y3 = v + s2
            s2 = y3 + v
            v = gd_ * (y3 - s3)
            y4 = v + s3
            s3 = y4 + v

            out[i] = m0 * u + m1 * y1 + m2 * y2 + m3 * y3 + m4 * y4
          end

          [s0, s1, s2, s3].each_with_index do |s, j|
            s = 0.0 if !s.finite? || s.abs < FLUSH
            state[j] = s
          end

          out
        end

        # The Ruby mirror of MB::Sound::FastFilter.diode_ladder (the diode
        # ladder, +mode: :diode+): four_pole's arguments without the mix,
        # the same operations in the same order (see fast_filter.c for the
        # model).  Returns a new SFloat.
        def self.diode_process_ruby(buffer, cutoff, resonance, state, sample_rate, k_max, comp, drive, curve = 0, drive_mode = 0, clip = 0)
          rate = sample_rate.to_f
          raise ArgumentError, 'Sample rate must be positive and finite' unless rate > 0 && rate.finite?
          k_max = k_max.to_f
          comp = comp.to_f
          drive = drive.to_f
          raise ArgumentError, 'Filter parameters must be finite (and drive not negative)' unless k_max.finite? && comp.finite? && drive >= 0 && drive.finite?
          raise ArgumentError, 'Resonance curve must be 0 (linear), 1 (dB), 2 (self-oscillating linear), or 3 (self-oscillating dB)' unless [0, 1, 2, 3].include?(curve)
          raise ArgumentError, 'Diode ladder drive mode must be 0 (input) or 2 (feedback)' unless [0, 2].include?(drive_mode)
          raise ArgumentError, 'Clip must be 0 (soft) or 1 (hard)' unless [0, 1].include?(clip)
          raise ArgumentError, 'Diode ladder state must have four elements' unless state.is_a?(Array) && state.length == 4

          s0, s1, s2, s3 = state.map { |v| v = v.to_f; v.finite? ? v : 0.0 }

          data = Numo::SFloat.cast(buffer)
          raise ArgumentError, "Only 1D NArrays may be processed (got #{data.ndim} dimensions)" unless data.ndim == 1
          length = data.length
          out = Numo::SFloat.zeros(length)

          fc_arr = signal_input(cutoff, length, 'Cutoff')
          res_arr = signal_input(resonance, length, 'Resonance')
          fc_scalar = fc_arr ? nil : (cutoff.nil? ? 0.0 : cutoff.to_f)
          res_scalar = res_arr ? nil : (resonance.nil? ? 0.0 : resonance.to_f)

          pi_over_rate = Math::PI / rate
          fc_max = rate * MAX_CUTOFF_RATIO
          inv_drive = drive > 0 ? 1.0 / drive : 0.0
          driven = drive > 0

          last_fc = Float::NAN
          last_res = Float::NAN
          g = 0.0
          r1 = r2 = r3 = r4 = 1.0
          a1 = a2 = a3 = 0.0
          q1 = q2 = q3 = q4 = 0.0
          k = 0.0
          inv = 1.0
          in_gain = 1.0

          length.times do |i|
            fc = fc_arr ? fc_arr[i] : fc_scalar
            res = res_arr ? res_arr[i] : res_scalar

            if fc != last_fc || res != last_res
              if res != last_res
                last_res = res
                if !(res >= 0.0)
                  res = 0.0
                elsif res > 1.0
                  res = 1.0
                end
                k = diode_loop_gain(res, curve, k_max)
                in_gain = 1.0 + comp * k
              end

              if fc != last_fc
                last_fc = fc
                if !(fc >= MIN_CUTOFF)
                  fc = MIN_CUTOFF
                elsif fc > fc_max
                  fc = fc_max
                end
                g = tan(fc * pi_over_rate) * DIODE_INV_W180
                d = 1.0 + 2.0 * g
                r1 = 1.0 / d
                a1 = g * r1
                r2 = 1.0 / (d - g * a1)
                a2 = g * r2
                r3 = 1.0 / (d - g * a2)
                a3 = g * r3
                r4 = 1.0 / ((1.0 + g) - g * a3)
                q1 = g * r1
                q2 = g * q1 * r2
                q3 = g * q2 * r3
                q4 = g * q3 * r4
              end

              inv = 1.0 / (1.0 + k * q4)
            end

            x = data[i]

            p1 = s0 * r1
            p2 = (s1 + g * p1) * r2
            p3 = (s2 + g * p2) * r3
            p4 = (s3 + g * p3) * r4

            u = (x * in_gain - k * p4) * inv
            if driven
              if drive_mode == 0
                u = tanh(u * drive) * inv_drive
              else
                fb = p4 + q4 * u - comp * x
                t = secant(fb * drive, clip)
                kt = k * t
                u = (x * (1.0 + comp * kt) - kt * p4) / (1.0 + kt * q4)
              end
            end

            y4 = p4 + q4 * u
            y3 = p3 + q3 * u + a3 * y4
            y2 = p2 + q2 * u + a2 * y3
            y1 = p1 + q1 * u + a1 * y2

            s0 = 2.0 * y1 - s0
            s1 = 2.0 * y2 - s1
            s2 = 2.0 * y3 - s2
            s3 = 2.0 * y4 - s3

            out[i] = y4
          end

          [s0, s1, s2, s3].each_with_index do |s, j|
            s = 0.0 if !s.finite? || s.abs < FLUSH
            state[j] = s
          end

          out
        end

        # The diode ladder's dB resonance curve: k / DIODE_CURVE_K for
        # resonance +r+ (0..1).  Like .resonance_curve, the gain at the
        # cutoff relative to DC, (1 + k) / (K - k) with K = DIODE_EDGE_K,
        # rises linearly in dB: G = 2^(r log2(757.12)) / K, from -25.3 dB
        # to +32.3 dB, and k = (K G - 1) / (1 + G).
        def self.diode_resonance_curve(r)
          return 0.0 unless r > 0.0
          return 1.0 if r >= 1.0
          e = exp2(r * DIODE_CURVE_LOG2_RATIO)
          (e - 1.0) / ((1.0 + e * DIODE_INV_EDGE_K) * DIODE_CURVE_K)
        end

        # The diode ladder's loop gain for resonance +r+ on kernel curve
        # +curve+ (0..3) with lp4's +k_max+: lp4's curves (the dB curve
        # replaced by .diode_resonance_curve) times DIODE_SCALE.
        def self.diode_loop_gain(r, curve, k_max)
          case curve
          when 1 then diode_resonance_curve(r) * k_max * DIODE_SCALE
          when 2 then self_oscillate_gain(r, false, k_max) * DIODE_SCALE
          when 3
            if r <= SELF_OSCILLATE_ONSET
              diode_resonance_curve(r / SELF_OSCILLATE_ONSET) * SELF_OSCILLATE_EDGE * DIODE_SCALE
            else
              self_oscillate_gain(r, true, k_max) * DIODE_SCALE
            end
          else r * k_max * DIODE_SCALE
          end
        end

        # The kernel's dB resonance curve: k / k_max for resonance +r+
        # (0..1; see the class description).  G = 2^(r log2(196)) / 4 is the
        # gain at the cutoff relative to DC, from 1/4 (-12 dB) to 49 (+33.8
        # dB), and k = (4 G - 1) / (1 + G), scaled to 1 at k = CURVE_K.
        def self.resonance_curve(r)
          return 0.0 unless r > 0.0
          return 1.0 if r >= 1.0
          e = exp2(r * CURVE_LOG2_RATIO)
          (e - 1.0) / ((1.0 + 0.25 * e) * CURVE_K)
        end

        # The loop gain k of a +self_oscillate: true+ filter for resonance
        # +r+ (0..1), the kernel's curves 2 (+db+ false) and 3 (+db+ true):
        # up to SELF_OSCILLATE_ONSET (0.9) the :linear or :db curve of r /
        # 0.9, times SELF_OSCILLATE_EDGE (k = 4, where oscillation starts);
        # above it 4 + (+k_max+ - 4) x², x = (r - 0.9) / 0.1.  0.5 -> 3.20
        # (dB) or 2.22 (linear), 0.8 -> 3.92 or 3.56, 0.9 -> 4, 0.95 ->
        # 4.25, 1 -> 5 (see the class description).
        def self.self_oscillate_gain(r, db, k_max = SELF_OSCILLATE_K)
          if r <= SELF_OSCILLATE_ONSET
            x = r / SELF_OSCILLATE_ONSET
            return (db ? resonance_curve(x) : x) * SELF_OSCILLATE_EDGE
          end
          x = (r - SELF_OSCILLATE_ONSET) / (1.0 - SELF_OSCILLATE_ONSET)
          SELF_OSCILLATE_EDGE + (k_max - SELF_OSCILLATE_EDGE) * (x * x)
        end

        # The resonance on the :db curve that gives the same loop gain as
        # +linear+ on the :linear curve (round 1's mapping), to retune
        # patches written for it: log(4 (1 + K) / (4 - K)) / log(196) with
        # K = 3.9 × linear.  0.3 -> 0.21, 0.5 -> 0.33, 0.6 -> 0.40, 0.7 ->
        # 0.47, 0.75 -> 0.51, 0.8 -> 0.55, 0.9 -> 0.68, 0.95 -> 0.79, 1 -> 1.
        # The inverse is .linear_resonance.
        def self.db_resonance(linear)
          linear = linear.to_f
          return 0.0 unless linear > 0
          return 1.0 if linear >= 1
          k = CURVE_K * linear
          (Math.log(4 * (1 + k) / (4 - k)) / Math.log(196)).clamp(0.0, 1.0)
        end

        # The resonance on the :linear curve that gives the same loop gain as
        # +db+ on the :db curve (.resonance_curve; the inverse of
        # .db_resonance).
        def self.linear_resonance(db)
          resonance_curve(db.to_f)
        end

        # The resonance (0..1) that gives this filter the gain at the cutoff
        # (relative to DC) of a 2-pole filter of quality +q+, which is q:
        # log(4 q) / log(196) with the :db curve (q 0.25 or less gives 0,
        # 0.707 gives 0.19, 4 gives 0.39, 10 gives 0.70, 49 or more gives
        # 1), or the same loop gain with the :linear curve.  +q+ may be a
        # number or an NArray.  +diode: true+ maps to the diode ladder's
        # curves (log(18.39 q) / log(757.12) on the :db curve).
        def self.quality_to_resonance(q, curve: :db, diode: false)
          # Gain ratio at the cutoff from r = 0 to 1 and the gain at r = 0
          log_ratio = Math.log(diode ? 40 + 39 * DIODE_EDGE_K : 196)
          edge = diode ? DIODE_EDGE_K : 4.0
          to_linear = ->(v) { diode ? diode_resonance_curve(v) : resonance_curve(v) }

          if q.is_a?(Numo::NArray)
            r = (Numo::NMath.log(Numo::DFloat.cast(q).clip(1.0 / edge, nil) * edge) * (1.0 / log_ratio)).clip(0.0, 1.0)
            r = r.map { |v| to_linear.(v) } if curve == :linear
            return Numo::SFloat.cast(r)
          end

          q = q.to_f
          r = q > 1.0 / edge ? (Math.log(edge * q) / log_ratio).clamp(0.0, 1.0) : 0.0
          curve == :linear ? to_linear.(r) : r
        end

        # The kernel's 2^y for y >= 0 (a Taylor series for the fraction).
        def self.exp2(y)
          n = y.floor
          x = (y - n) * LN2
          p = EXP_TAYLOR[13]
          12.downto(0) { |i| p = p * x + EXP_TAYLOR[i] }
          Math.ldexp(p, n)
        end

        # The kernel's secant gains (saturator(x) / x): +clip+ 0 for the
        # soft saturator (.tanh), 1 for the hard clipper (linear to 0.8, a
        # quadratic knee to 1 at 1.2).
        def self.secant(x, clip)
          a = x.abs
          if clip == 1
            return 1.0 if a <= 0.8
            if a < 1.2
              d = a - 0.8
              return (a - d * d * 1.25) / a
            end
            return 1.0 / a
          end
          return 1.0 / a if a > 3.0
          x2 = x * x
          (27.0 + x2) / (27.0 + 9.0 * x2)
        end

        # The kernel's tan approximation (see fast_filter.c): a [5/4] Pade
        # approximation of tan(w / 2) and the double-angle formula.
        def self.tan(w)
          y = w * 0.5
          y2 = y * y
          t = y * (945.0 - 105.0 * y2 + y2 * y2) / (945.0 - 420.0 * y2 + 15.0 * y2 * y2)
          2.0 * t / (1.0 - t * t)
        end

        # The kernel's saturator: x (27 + x^2) / (27 + 9 x^2), +-1 beyond 3.
        def self.tanh(x)
          return 1.0 if x > 3.0
          return -1.0 if x < -3.0
          x2 = x * x
          x * (27.0 + x2) / (27.0 + 9.0 * x2)
        end

        # Reads a signal input like mb_read_signal_input: an NArray (real
        # parts as float32 Floats) or nil for a Numeric.
        def self.signal_input(value, length, name)
          return nil unless value.is_a?(Numo::NArray)
          raise ArgumentError, "#{name} array length does not match sample buffer length" if value.length != length
          value = value.real if value.is_a?(Numo::SComplex) || value.is_a?(Numo::DComplex)
          Numo::SFloat.cast(value).to_a
        end
        private_class_method :signal_input

        private

        # The kernel's curve, drive mode, and clip arguments.
        def kernel_options
          curves = @self_oscillate ? SELF_OSCILLATE_CURVES : RESONANCE_CURVES
          [curves.fetch(@resonance_curve), DRIVE_MODES.fetch(@drive_mode), CLIPS.fetch(@clip)]
        end

        # Keeps the last cutoff and resonance (for #reset, #response, #to_s).
        def remember(cutoff, resonance)
          @cutoff = last_value(cutoff, @cutoff)
          @resonance = last_value(resonance, @resonance)
        end

        def last_value(v, previous)
          return previous if v.nil? || (v.is_a?(Numo::NArray) && v.empty?)
          (v.is_a?(Numo::NArray) ? v[-1].real : v).to_f
        end
      end
    end
  end
end
