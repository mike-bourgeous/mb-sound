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
      # - +resonance+ 0..1 sets the loop gain k = resonance × #k_max.  By
      #   default #k_max is MAX_K (3.9, just below the oscillation edge at
      #   4), so like the SQ-80 the filter rings but never self-oscillates
      #   (peak about +37 dB over the passband at full resonance).
      # - Passband compensation (+compensation:+, default 0.375 like the
      #   CEM3379): full resonance loses about 6 dB of bass instead of 12.
      #   0 gives a classic Moog-style bass loss.
      # - +self_oscillate: true+ raises #k_max to SELF_OSCILLATE_K (4.3;
      #   oscillation starts at resonance 4 / 4.3 ≈ 0.93) and turns on the
      #   drive (1.0 unless given), whose saturation sets the amplitude.
      # - +drive:+ (nil or 0 for linear) applies tanh(drive × u) / drive to
      #   the cascade's input: unity gain for small signals, saturating above
      #   about 1 / drive.
      # - +mode:+ picks an output tap mix (Oberheim Xpander style): :lp4
      #   (default), :lp2, :bp2, :bp4, :hp2, :hp4.  Compensation only
      #   applies to the lowpass modes.
      class FourPole < Filter
        # Loop gain at full resonance by default (no self-oscillation).
        MAX_K = 3.9

        # Loop gain at full resonance with +self_oscillate: true+.
        SELF_OSCILLATE_K = 4.3

        # The CEM3379's passband compensation (6 dB bass loss at k = 4).
        COMPENSATION = 0.375

        # Lowest cutoff in Hz, and highest as a fraction of the sample rate
        # (the kernel clamps to these).
        MIN_CUTOFF = 1.0
        MAX_CUTOFF_RATIO = 0.49

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
        }.freeze

        # Modes that use passband compensation by default.
        LOWPASS_MODES = [:lp4, :lp2].freeze

        attr_reader :sample_rate, :cutoff, :resonance, :mode, :drive, :compensation, :k_max

        # Creates a filter at +cutoff+ Hz with +resonance+ 0..1 (see the
        # class description for the options).
        def initialize(cutoff: 1000.0, resonance: 0.0, mode: :lp4, drive: nil, self_oscillate: false, compensation: nil, sample_rate: 48000)
          raise ArgumentError, "Unknown four-pole mode #{mode.inspect} (use one of #{MODES.keys.join(', ')})" unless MODES.include?(mode)

          @mode = mode
          @self_oscillate = !!self_oscillate
          @k_max = @self_oscillate ? SELF_OSCILLATE_K : MAX_K

          drive = 1.0 if @self_oscillate && (drive.nil? || drive == 0)
          @drive = drive.nil? || drive == false ? 0.0 : Float(drive)
          raise ArgumentError, "Drive must be a positive number or nil (got #{drive.inspect})" unless @drive >= 0 && @drive.finite?

          @compensation = Float(compensation || (LOWPASS_MODES.include?(mode) ? COMPENSATION : 0.0))
          @mix = MODES.fetch(mode)

          @sample_rate = sample_rate.to_f
          raise ArgumentError, 'Sample rate must be positive' unless @sample_rate > 0

          self.cutoff = cutoff
          self.resonance = resonance

          @state = [0.0, 0.0, 0.0, 0.0]
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
          out = MB::Sound::FastFilter.four_pole(samples, cutoff, resonance, @state, @sample_rate, @k_max, @compensation, @drive, @mix)
          remember(cutoff, resonance)
          out
        end

        # Same as #dynamic_process, through the Ruby mirror (slow; for specs).
        def dynamic_process_ruby(samples, cutoff:, resonance:)
          samples = samples.real if samples.is_a?(Numo::SComplex) || samples.is_a?(Numo::DComplex)
          out = self.class.process_ruby(samples, cutoff, resonance, @state, @sample_rate, @k_max, @compensation, @drive, @mix)
          remember(cutoff, resonance)
          out
        end

        # Sets the state as if +value+ had been the input for a long time
        # (the steady state of the linear filter at the last resonance).
        def reset(value = 0)
          value = value.to_f
          k = @resonance.clamp(0.0, 1.0) * @k_max
          # Every stage holds the lowpass level, whatever the output mix
          dc = value * (1.0 + @compensation * k) / (1.0 + k)
          @state = [dc, dc, dc, dc]
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
          k = @resonance.clamp(0.0, 1.0) * @k_max
          z1 = omega.is_a?(Numo::NArray) ? Numo::NMath.exp(Numo::DComplex.cast(omega) * -1i) : CMath.exp(-1i * omega)

          # One TPT stage: g (1 + z^-1) / ((1 + g) - (1 - g) z^-1)
          h = g * (z1 + 1) / ((1 + g) - (1 - g) * z1)
          u = (1 + @compensation * k) / (1 + k * h**4)
          m = @mix
          u * (m[0] + m[1] * h + m[2] * h**2 + m[3] * h**3 + m[4] * h**4)
        end

        def to_s
          "#{@mode}(#{@cutoff.round(2)} Hz, r=#{@resonance.round(3)}#{@drive > 0 ? ", drive #{@drive}" : ''}#{@self_oscillate ? ', self-osc' : ''})"
        end

        # The Ruby mirror of MB::Sound::FastFilter.four_pole: the same
        # arguments, the same operations in the same order, and the same
        # samples (specs check every sample).  Returns a new SFloat (the C
        # version filters an inplace SFloat in place).
        def self.process_ruby(buffer, cutoff, resonance, state, sample_rate, k_max, comp, drive, mix)
          rate = sample_rate.to_f
          raise ArgumentError, 'Sample rate must be positive and finite' unless rate > 0 && rate.finite?
          k_max = k_max.to_f
          comp = comp.to_f
          drive = drive.to_f
          raise ArgumentError, 'Filter parameters must be finite (and drive not negative)' unless k_max.finite? && comp.finite? && drive >= 0 && drive.finite?
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

          last_fc = Float::NAN
          last_res = Float::NAN
          g_ = 0.0
          one = 1.0
          k = 0.0
          inv = 1.0
          in_gain = 1.0

          length.times do |i|
            fc = fc_arr ? fc_arr[i] : fc_scalar
            res = res_arr ? res_arr[i] : res_scalar

            if fc != last_fc || res != last_res
              last_fc = fc
              last_res = res

              if !(fc >= MIN_CUTOFF)
                fc = MIN_CUTOFF
              elsif fc > fc_max
                fc = fc_max
              end
              if !(res >= 0.0)
                res = 0.0
              elsif res > 1.0
                res = 1.0
              end

              g = tan(fc * pi_over_rate)
              g_ = g / (1.0 + g)
              one = 1.0 - g_
              g2 = g_ * g_
              k = res * k_max
              inv = 1.0 / (1.0 + k * (g2 * g2))
              in_gain = 1.0 + comp * k
            end

            x = data[i]
            sum = ((s0 * one * g_ + s1 * one) * g_ + s2 * one) * g_ + s3 * one
            u = (x * in_gain - k * sum) * inv
            u = tanh(u * drive) * inv_drive if drive > 0

            v = g_ * (u - s0)
            y1 = v + s0
            s0 = y1 + v
            v = g_ * (y1 - s1)
            y2 = v + s1
            s1 = y2 + v
            v = g_ * (y2 - s2)
            y3 = v + s2
            s2 = y3 + v
            v = g_ * (y3 - s3)
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
