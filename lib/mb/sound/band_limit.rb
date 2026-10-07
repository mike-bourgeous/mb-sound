module MB
  module Sound
    # Band-limited (antialiased) oscillator waveforms using PolyBLEP and
    # PolyBLAMP corrections.  A naive ramp, square, or triangle aliases
    # because its jumps (or corners) contain harmonics far above Nyquist,
    # which fold back down as inharmonic tones.  The band-limited waveform is
    # the naive one plus a short correction at each jump in value (a BLEP,
    # band-limited step) or slope (a BLAMP, band-limited ramp), touching only
    # the samples on either side of the edge, placed at its exact sub-sample
    # time.  It costs about the same as the naive waveform.
    #
    # Edges are found on the effective phase (phase plus phase modulation),
    # so FM and PM, including through-zero (backward) motion, are corrected
    # too.  The correction slightly softens the top octave (about -5 dB at
    # 20 kHz for a 4 kHz saw), the usual PolyBLEP trade-off.
    #
    # Tone's ramp/saw, square, and triangle are band-limited; aramp/asaw,
    # asquare, and atriangle are the naive (aliased) versions.  Tone#lfo
    # fades the correction in with frequency (LFO_FADE), so slow LFOs keep
    # exact edges (a delay time that jumps should jump) while an LFO pushed
    # to audio rates is band-limited.
    #
    # The C kernel is MB::Sound::FastSynth.oscillate_bl (the fast_synth
    # extension); .oscillate_ruby mirrors it exactly for testing.
    module BandLimit
      # Computes sync pulses and increments for +count+ samples of a phase
      # starting at +phi+ (cycles) and advancing by +freq+ (Hz; Numeric or
      # NArray, read in single precision like the C kernels) times
      # +advance+, the same phases as MB::FastSound.phasor and the oscillator
      # kernels.  +prev+ is [last phase, last increment, primed (0 or 1)] from
      # the previous call, updated.  Returns [pulses, increments] as SFloat
      # NArrays.
      #
      # A pulse marks the first sample after the phase wraps: its value is
      # 1 - d, where d (0 <= d < 1) is how many samples before that sample
      # the wrap happened, so it's in (0, 1] (usable as an ordinary trigger)
      # and exact enough to band-limit a reset (see Tone#sync).  Wrapping
      # backward (negative frequency) gives -(1 - d); a jump of the phase
      # between buffers (a reset or sync) gives 1.  A wrap exactly on a
      # sample (within EPS, like the kernels' edges; e.g. every wrap of
      # 2000 Hz at 48 kHz) gives a pulse of 1 on that sample.  There is no
      # C version: the C sync kernel only reads the pulses.
      def self.sync_pulses(phi, freq, advance, count, prev)
        return [Numo::SFloat[], Numo::SFloat[]] if count == 0

        freq = Numo::DFloat.cast(Numo::SFloat.cast(freq.is_a?(Numo::SComplex) || freq.is_a?(Numo::DComplex) ? freq.real : freq)) if freq.is_a?(Numo::NArray)
        increments = freq * advance

        if increments.is_a?(Numo::NArray)
          sums = increments.cumsum
          steps = Numo::DFloat.zeros(count)
          steps[1..] = sums[0...-1] if count > 1
          incs = increments
        else
          steps = Numo::DFloat.new(count).seq * increments
          incs = Numo::DFloat.new(count).fill(increments)
        end

        phases = steps + phi
        phases -= phases.floor

        # A phase within rounding of the wrap is on it (see .snap and
        # bl_snap in fast_synth.c): e.g. at 2000 Hz, 23/24 + 1/24 is just
        # below 1 in floating point
        near = phases.lt(EPS) | phases.gt(1.0 - EPS)
        phases[near] = 0.0 if near.count_true > 0

        prev_p, prev_inc, primed = prev
        before = Numo::DFloat.zeros(count)
        before_inc = Numo::DFloat.zeros(count)
        before[0] = prev_p
        before_inc[0] = prev_inc
        if count > 1
          before[1..] = phases[0...-1]
          before_inc[1..] = incs[0...-1]
        end

        reached = before + before_inc
        pulses = Numo::DFloat.zeros(count)

        # A wrap within EPS past the end of a step lands on its last sample,
        # and one exactly at its start belongs to the step before (see
        # .crossing and bl_crossing), so a wrap exactly on a sample gives a
        # pulse of 1 on that sample, once
        forward = before_inc.gt(0) & reached.ge(1.0 - EPS)
        pulses[forward] = (1.0 - before[forward]) / before_inc[forward] if forward.count_true > 0
        backward = before_inc.lt(0) & before.gt(0) & reached.le(EPS)
        pulses[backward] = -(before[backward] / -before_inc[backward]) if backward.count_true > 0

        # A phase that didn't continue from the previous sample jumped
        jumped = ((reached - phases + 0.5) - (reached - phases + 0.5).floor - 0.5).abs.gt(1e-6)
        pulses[jumped] = 1.0 if jumped.count_true > 0
        pulses[0] = 0.0 if primed == 0

        prev.replace([phases[-1], incs[-1], 1]) if count > 0

        [Numo::SFloat.cast(pulses.clip(-1, 1)), Numo::SFloat.cast(incs)]
      end

      # Wave types that are band-limited without a phase warp.
      WAVES = [:ramp, :square, :triangle].freeze

      # Wave types that can be warped (Tone#pwm); a warped sine or parabola
      # has corners, which are band-limited too.
      WARP_WAVES = [:ramp, :square, :triangle, :sine, :parabola].freeze

      # Frequencies (Hz) over which Tone#lfo fades band-limiting in.
      LFO_FADE = (15.0..30.0).freeze

      # Passed as the fade band for a naive (unband-limited) warped waveform.
      NEVER = [Float::INFINITY, Float::INFINITY].freeze

      INV_2PI = 1.0 / (2.0 * Math::PI)

      # Phases this close to an edge (cycles) count as on it.
      EPS = 1e-9

      # The narrowest pulse width (and 1 minus the widest).
      MIN_WIDTH = 1e-4

      # The average of each shape's first half; a warped shape's DC offset is
      # this times (2 * width - 1).
      HALF_MEAN = {
        square: 1.0,
        ramp: 0.5,
        triangle: 0.5,
        sine: 2.0 / Math::PI,
        parabola: 2.0 / 3.0,
      }.freeze

      # The naive waveform at phase +u+ (cycles, 0..1): the value after a
      # breakpoint, or before it if +left+ (with u = 1 for the cycle's end).
      def self.shape(wave_type, u, left = false)
        case wave_type
        when :ramp then (left ? u <= 0.5 : u < 0.5) ? 2.0 * u : 2.0 * u - 2.0
        when :square then (left ? u <= 0.5 : u < 0.5) ? 1.0 : -1.0
        when :triangle
          if left ? u <= 0.25 : u < 0.25
            4.0 * u
          elsif left ? u <= 0.75 : u < 0.75
            2.0 - 4.0 * u
          else
            4.0 * u - 4.0
          end
        when :sine then Math.sin(u * (2.0 * Math::PI))
        when :parabola
          if left ? u <= 0.5 : u < 0.5
            x = 1.0 - 4.0 * u
            1.0 - x * x
          else
            x = 4.0 * u - 3.0
            x * x - 1.0
          end
        else
          raise ArgumentError, "No band-limited version of #{wave_type.inspect}"
        end
      end

      # The slope per cycle of the naive waveform at +u+ (see .shape).
      def self.slope(wave_type, u, left = false)
        case wave_type
        when :ramp then 2.0
        when :square then 0.0
        when :triangle
          if left ? u <= 0.25 : u < 0.25
            4.0
          elsif left ? u <= 0.75 : u < 0.75
            -4.0
          else
            4.0
          end
        when :sine then (2.0 * Math::PI) * Math.cos(u * (2.0 * Math::PI))
        when :parabola
          (left ? u <= 0.5 : u < 0.5) ? 8.0 * (1.0 - 4.0 * u) : 8.0 * (4.0 * u - 3.0)
        else
          raise ArgumentError, "No band-limited version of #{wave_type.inspect}"
        end
      end

      # The phases of the shape's own breakpoints, then the wrap and the
      # middle (where a warp bends the phase).
      def self.candidates(wave_type)
        u = case wave_type
            when :ramp then [0.5]
            when :square then [0.0, 0.5]
            when :triangle then [0.25, 0.75]
            else []
            end
        u << 0.0 unless u.include?(0.0)
        u << 0.5 unless u.include?(0.5)
        u
      end

      # Maps phase +p+ through the warp with width +w+ (identity at 0.5).
      def self.warp(p, w)
        p < w ? p * (0.5 / w) : 0.5 + (p - w) * (0.5 / (1.0 - w))
      end

      # Breakpoints of +wave_type+ warped by width +w+: [phase, jump in value,
      # jump in slope per cycle, value after], leaving out points with no
      # jump.  See bl_breakpoints in fast_synth.c.
      def self.breakpoints(wave_type, w = 0.5, all = false)
        k1 = 0.5 / w
        k2 = 0.5 / (1.0 - w)

        candidates(wave_type).filter_map do |ub|
          ul = ub == 0.0 ? 1.0 : ub
          kr = ub < 0.5 ? k1 : k2
          kl = ul <= 0.5 ? k1 : k2

          vr = shape(wave_type, ub)
          dv = vr - shape(wave_type, ul, true)
          ds = slope(wave_type, ub) * kr - slope(wave_type, ul, true) * kl
          next if dv == 0 && ds == 0 && !all

          pos = ub < 0.5 ? ub * (2.0 * w) : w + (ub - 0.5) * (2.0 * (1.0 - w))
          [pos, dv, ds, vr]
        end
      end

      # Clamps a pulse width to MIN_WIDTH..(1 - MIN_WIDTH) (NaN to MIN_WIDTH).
      def self.clamp_width(w)
        return MIN_WIDTH unless w >= MIN_WIDTH
        return 1.0 - MIN_WIDTH if w > 1.0 - MIN_WIDTH
        w
      end

      # Like mb_wrap() in the C extensions (Ruby's %, written out to match C).
      def self.wrap(x)
        x - x.floor
      end

      # If moving from phase +e+ by +d+ cycles crosses phase +b+, returns the
      # crossing time as a fraction of the step in (0, 1], else nil.
      def self.crossing(e, d, b)
        # Both phases are in 0..1, so wrapping is one add (as in C)
        if d > 0
          dist = b - e
        elsif d < 0
          dist = e - b
        else
          return nil
        end
        dist += 1.0 if dist < 0

        dist = 1.0 if dist == 0

        # Edges within EPS past the end land on its last sample (see .snap)
        ad = d.abs
        return nil if ad >= 1.0 || dist > ad + EPS

        dist >= ad ? 1.0 : dist / ad
      end

      # Like .crossing, but a phase on a breakpoint is always on its right
      # side, whichever way it moves (see bl_side_crossing in fast_synth.c;
      # used by the free-running and sync kernels): a backward step starting
      # on +b+ crosses it at once (0.0), and one ending within EPS of it
      # doesn't cross it.
      def self.side_crossing(e, d, b)
        return crossing(e, d, b) if d >= 0

        dist = e - b
        dist += 1.0 if dist < 0
        return 0.0 if dist == 0

        ad = -d
        return nil if ad >= 1.0 || dist >= ad - EPS

        dist / ad
      end

      # Returns the index of a breakpoint within EPS of phase +e+, or nil (a
      # sample there takes the value after the edge; see bl_snap).
      def self.snap(points, e)
        points.each_with_index do |(pos, _, _, _), j|
          diff = (e - pos).abs
          return j if diff < EPS || diff > 1.0 - EPS
        end
        nil
      end

      # The fraction of the correction applied at +freq+ Hz (1 when +lo+ and
      # +hi+ are zero; a smoothstep from +lo+ to +hi+ otherwise).
      def self.fade(freq, lo, hi)
        return 1.0 if lo <= 0 && hi <= 0
        return 0.0 if freq <= lo
        return 1.0 if freq >= hi

        t = (freq - lo) / (hi - lo)
        t * t * (3.0 - 2.0 * t)
      end

      # The corrections for edges crossed while moving from +e+ by +d+:
      # [for the sample at the start of the step, for the sample at its end].
      # See bl_step in fast_synth.c.
      def self.step(points, e, d, adv, lo, hi)
        before = 0.0
        after = 0.0
        k = nil

        points.each do |pos, dv, ds, _|
          f = side_crossing(e, d, pos)
          next if f.nil?

          if k.nil?
            k = fade(d.abs / adv, lo, hi)
            return [0.0, 0.0] if k == 0
          end

          dv = d > 0 ? dv : -dv
          ds *= d.abs

          xa = f
          xb = 1.0 - f
          after += k * (dv * (-0.5 * xa * xa) + ds * (xa * xa * xa / 6.0))
          before += k * (dv * (0.5 * xb * xb) + ds * (xb * xb * xb / 6.0))
        end

        [before, after]
      end

      # The real parts of +narray+ rounded to single precision, as the C code
      # reads signal inputs (mb_read_signal_input in
      # ext/mb/sound/include/mb_ext_helpers.h).
      def self.real_floats(narray)
        narray = narray.real if narray.is_a?(Numo::SComplex) || narray.is_a?(Numo::DComplex)
        Numo::SFloat.cast(narray).to_a
      end

      # Ruby mirror of MB::Sound::FastSynth.oscillate_bl, returning +count+
      # samples as an SFloat.  +freq+, +phase_mod+ (radians), and +width+ are
      # Numerics or NArrays (+width+ nil for 0.5); +state+ is the phasor's
      # [phi] and +bl_state+ the band-limiting state, both updated like the C
      # version.
      def self.oscillate_ruby(count, wave_type, freq, phase_mod, advance, gain, offset, state, bl_state, fade_lo, fade_hi, width = nil, remove_dc = false)
        freqs = freq.is_a?(Numo::NArray) ? real_floats(freq) : nil
        pms = phase_mod.is_a?(Numo::NArray) ? real_floats(phase_mod) : nil
        widths = width.is_a?(Numo::NArray) ? real_floats(width) : nil
        freq = freqs ? freqs[0] : freq.to_f
        pm = pms ? pms[0] : (phase_mod || 0).to_f
        w = clamp_width(widths ? widths[0] : (width || 0.5).to_f)
        half_mean = HALF_MEAN.fetch(wave_type)
        points = breakpoints(wave_type, w)

        phi = state[0].to_f
        prev_e, prev_inc, prev_pm, primed = bl_state
        fresh = primed == 0
        primed = primed == 1

        out = Numo::SFloat.zeros(count)
        steps = 0.0
        e = inc = 0.0
        pending = 0.0
        pending_d = 0.0
        count.times do |i|
          freq = freqs[i] if freqs
          pm = pms[i] if pms
          if widths
            new_w = clamp_width(widths[i])
            if new_w != w
              w = new_w
              points = breakpoints(wave_type, w)
            end
          end

          inc = freq * advance
          steps = inc * i unless freqs

          e = wrap(phi + steps)
          e = wrap(e + pm * INV_2PI) if pm != 0
          snapped = snap(points, e)
          if snapped
            e = points[snapped][0]
            v = points[snapped][3]
          else
            v = shape(wave_type, warp(e, w))
          end

          d_back = prev_inc + (pm - prev_pm) * INV_2PI
          if i > 0 && d_back == pending_d
            v += pending
          elsif primed && (i > 0 || (wrap(prev_e + d_back - e + 0.5) - 0.5).abs < 1e-6)
            v += step(points, prev_e, d_back, advance, fade_lo, fade_hi)[1]
          elsif fresh && i == 0
            v += step(points, wrap(e - inc), inc, advance, fade_lo, fade_hi)[1]
          end

          if i + 1 < count
            next_pm = pms ? pms[i + 1] : pm
          else
            next_pm = pm + (pm - (i > 0 || primed ? prev_pm : pm))
          end
          d_fwd = inc + (next_pm - pm) * INV_2PI
          before, pending = step(points, e, d_fwd, advance, fade_lo, fade_hi)
          v += before
          pending_d = d_fwd

          v -= half_mean * (2.0 * w - 1.0) if remove_dc

          out[i] = v * gain + offset

          prev_e = e
          prev_inc = inc
          prev_pm = pm
          primed = true

          steps += inc if freqs
        end

        steps = freq * advance * count unless freqs
        state[0] = wrap(phi + steps)
        bl_state.replace([prev_e, prev_inc, prev_pm, 1]) if count > 0

        out
      end

      # Complex wave types with band-limited (BLIT) versions; see .blit_ruby.
      COMPLEX_WAVES = [:complex_ramp, :complex_square, :complex_triangle].freeze

      # Leak of the BLIT integrators (see fast_synth.c).
      BLIT_LEAK = 1.0 - 1e-4

      # Highest BLIT harmonic, in cycles per sample.
      BLIT_MAX_CYCLES = 0.49

      # Weight of harmonic +k+ when harmonics below +h+ are allowed.
      def self.blit_weight(k, h)
        w = h - k
        w >= 1.0 ? 1.0 : (w <= 0.0 ? 0.0 : w)
      end

      def self.blit_mul(ar, ai, br, bi)
        [ar * br - ai * bi, ar * bi + ai * br]
      end

      def self.blit_div(ar, ai, br, bi)
        d = br * br + bi * bi
        [(ar * br + ai * bi) / d, (ai * br - ar * bi) / d]
      end

      # Sum of e^{ikx} for k = 1..n plus frac e^{i(n+1)x}.
      def self.blit_all(x, n, frac)
        s = Math.sin(0.5 * x)
        mag = s.abs < 1e-9 ? n * Math.cos(0.5 * n * x) / Math.cos(0.5 * x) : Math.sin(0.5 * n * x) / s
        ph = 0.5 * (n + 1.0) * x
        re = mag * Math.cos(ph)
        im = mag * Math.sin(ph)
        if frac > 0
          re += frac * Math.cos((n + 1.0) * x)
          im += frac * Math.sin((n + 1.0) * x)
        end
        [re, im]
      end

      # Sum of e^{ikx} over the first m odd k plus frac times the next.
      def self.blit_odd(x, m, frac)
        s = Math.sin(x)
        mag = s.abs < 1e-9 ? m * Math.cos(m * x) / Math.cos(x) : Math.sin(m * x) / s
        ph = m * x
        re = mag * Math.cos(ph)
        im = mag * Math.sin(ph)
        if frac > 0
          re += frac * Math.cos((2.0 * m + 1.0) * x)
          im += frac * Math.sin((2.0 * m + 1.0) * x)
        end
        [re, im]
      end

      # See blit_derivative in fast_synth.c.
      def self.blit_derivative(shape, theta, h)
        if shape == :complex_ramp
          n = [(h - 1.0).floor.to_f, 0.0].max
          re, im = blit_all(theta + Math::PI, n, blit_weight(n + 1.0, h))
          [re * (-2.0 / Math::PI), im * (-2.0 / Math::PI)]
        else
          m = [(0.5 * ((h - 1.0).floor + 1.0)).floor.to_f, 0.0].max
          frac = blit_weight(2.0 * m + 1.0, h)
          scale = shape == :complex_square ? 4.0 / Math::PI : 8.0 / (Math::PI * Math::PI)
          re, im = blit_odd(shape == :complex_square ? theta : theta + 0.5 * Math::PI, m, frac)
          [re * scale, im * scale]
        end
      end

      # See blit_start in fast_synth.c: [y re, y im, g re, g im].
      def self.blit_start(shape, theta, h, delta)
        yre = yim = gre = gim = 0.0

        top = h.ceil
        (1..top).each do |k|
          w = blit_weight(k.to_f, h)
          break if w == 0
          next if shape != :complex_ramp && k.even?

          kd = k * delta
          er = Math.cos(kd)
          ei = -Math.sin(kd)
          denr = 1.0 - BLIT_LEAK * er
          deni = -BLIT_LEAK * ei
          hr = Math.cos(0.5 * kd)
          hi = -Math.sin(0.5 * kd)
          zr = Math.cos(k * theta)
          zi = Math.sin(k * theta)

          if shape == :complex_triangle
            bmag = w * 8.0 / (Math::PI * Math::PI * k)
            br = 0.0
            bi = k % 4 == 1 ? bmag : -bmag
            gr, gi = blit_mul(br * delta * k, bi * delta * k, hr, hi)
            gr, gi = blit_div(gr, gi, denr, deni)

            tr, ti = blit_mul(gr, gi, zr, zi)
            gre += tr
            gim += ti

            sr, si = blit_mul(0.5 * delta * (1.0 + er), 0.5 * delta * ei, gr, gi)
            sr, si = blit_div(sr, si, denr, deni)
          else
            a = shape == :complex_ramp ? (k.odd? ? 2.0 : -2.0) / (Math::PI * k) : 4.0 / (Math::PI * k)
            sr, si = blit_mul(w * a * delta * k, 0.0, hr, hi)
            sr, si = blit_div(sr, si, denr, deni)
          end

          tr, ti = blit_mul(sr, si, zr, zi)
          yre += tr
          yim += ti
        end

        [yre, yim, gre, gim]
      end

      # Ruby mirror of MB::Sound::FastSynth.blit, returning +count+ samples
      # as an SComplex NArray.  +blit_state+ is [y re, y im, g re, g im, last
      # phase, last increment, primed].
      def self.blit_ruby(count, shape, freq, advance, gain, offset, state, blit_state)
        raise ArgumentError, "No band-limited complex version of #{shape.inspect}" unless COMPLEX_WAVES.include?(shape)

        freqs = freq.is_a?(Numo::NArray) ? real_floats(freq) : nil
        freq = freqs ? freqs[0] : freq.to_f
        phi = state[0].to_f
        yre, yim, gre, gim, prev_p, prev_inc, primed = blit_state
        primed = primed != 0

        out = Numo::SComplex.zeros(count)
        steps = 0.0
        p = inc = 0.0
        count.times do |i|
          freq = freqs[i] if freqs
          inc = freq * advance
          steps = inc * i unless freqs

          p = wrap(phi + steps)
          theta = p * (2.0 * Math::PI)

          continued = primed && (i > 0 || (wrap(prev_p + prev_inc - p + 0.5) - 0.5).abs < 1e-6)
          if !continued
            h = inc.abs > 0 ? BLIT_MAX_CYCLES / inc.abs : 1.0
            yre, yim, gre, gim = blit_start(shape, theta, h, inc * (2.0 * Math::PI))
          elsif prev_inc != 0
            h = BLIT_MAX_CYCLES / prev_inc.abs
            dtheta = prev_inc * (2.0 * Math::PI)
            dre, dim = blit_derivative(shape, theta - 0.5 * dtheta, h)

            if shape == :complex_triangle
              ngre = BLIT_LEAK * gre + dtheta * dre
              ngim = BLIT_LEAK * gim + dtheta * dim
              yre = BLIT_LEAK * yre + dtheta * 0.5 * (gre + ngre)
              yim = BLIT_LEAK * yim + dtheta * 0.5 * (gim + ngim)
              gre = ngre
              gim = ngim
            else
              yre = BLIT_LEAK * yre + dtheta * dre
              yim = BLIT_LEAK * yim + dtheta * dim
            end
          end

          out[i] = Complex(yre * gain + offset, yim * gain)

          prev_p = p
          prev_inc = inc
          primed = true

          steps += inc if freqs
        end

        steps = freq * advance * count unless freqs
        state[0] = wrap(phi + steps)
        blit_state.replace([yre, yim, gre, gim, prev_p, prev_inc, 1]) if count > 0

        out
      end

      # Taps and oversampling of the minBLEP tables used by synced
      # oscillators (see .minblep_tables).
      SYNC_TAPS = 32
      SYNC_OVERSAMPLE = 64

      # Returns [blep, blamp] residual tables for synced oscillators
      # (FastSynth.oscillate_sync), built once: a Blackman-windowed sinc
      # (cutoff 0.45 of the sample rate) made minimum-phase by the real
      # cepstrum, integrated into a band-limited step B(t) over SYNC_TAPS
      # samples at SYNC_OVERSAMPLE points per sample.  The step residual is
      # R = B - 1; the ramp residual is the integral of R minus its final
      # value times B, which is still band-limited and settles exactly on the
      # ideal ramp (a plain integral would leave a permanent offset, since a
      # minimum-phase step is delayed).
      def self.minblep_tables
        @minblep_tables ||= begin
          taps = SYNC_TAPS
          os = SYNC_OVERSAMPLE
          len = taps * os + 1
          t = Numo::DFloat.new(len).seq / os - taps / 2.0
          x = t * (2 * 0.45)
          sinc = Numo::DFloat.ones(len)
          nz = x.ne(0)
          sinc[nz] = Numo::NMath.sin(x[nz] * Math::PI) / (x[nz] * Math::PI)
          window = t / taps + 0.5
          blackman = 0.42 - 0.5 * Numo::NMath.cos(window * 2 * Math::PI) + 0.08 * Numo::NMath.cos(window * 4 * Math::PI)

          step = minimum_phase(sinc * blackman).cumsum
          step /= step[-1]
          step[-1] = 1.0

          blep = step - 1.0
          ramp = blep.cumsum / os
          blamp = ramp - ramp[-1] * step
          blep[-1] = 0.0
          blamp[-1] = 0.0

          [blep.freeze, blamp.freeze]
        end
      end

      # Rows per cycle per sample of .sync_sine_table, and its highest
      # frequency (the minBLEP's response is -107 dB there; sines above it
      # are silent).
      SYNC_SINE_ROWS_PER_CYCLE = 256
      SYNC_SINE_MAX = 0.75

      # Returns [r0, r1, r2, m1, m2, sine] for synced oscillators of
      # +wave_type+ (FastSynth.oscillate_sync; see there): residual tables
      # R_n = B_n - M_n of jumps in the n-th time derivative, sampled like
      # .minblep_tables, the first two moments of h, the minBLEP's impulse
      # (m1 is the delay of a minimum-phase step at low frequencies, about
      # 2.78 samples), and for sines .sync_sine_table (nil otherwise).  B_1
      # and B_2 are integrals of B by the trapezoid rule (the integrals of
      # the linearly interpolated tables), and the moments come from their
      # final values, so every residual settles exactly on zero.
      def self.sync_tables(wave_type)
        @sync_tables ||= begin
          blep, _ = minblep_tables
          os = SYNC_OVERSAMPLE
          taps = SYNC_TAPS.to_f
          b = blep + 1.0
          t = Numo::DFloat.new(b.length).seq / os
          b1 = (b.cumsum - (b[0] + b) * 0.5) / os
          b2 = (b1.cumsum - (b1[0] + b1) * 0.5) / os
          m1 = taps - b1[-1]
          m2 = 2.0 * (b2[-1] - taps * taps / 2.0 + m1 * taps)
          r1 = b1 - (t - m1)
          r2 = b2 - (t * t / 2.0 - m1 * t + m2 / 2.0)
          r1[-1] = 0.0
          r2[-1] = 0.0

          poly = [blep, r1.freeze, r2.freeze, m1, m2, nil].freeze
          {
            poly: poly,
            sine: [*poly[0..4], sync_sine_table(m1)].freeze,
          }.freeze
        end

        @sync_tables[wave_type == :sine ? :sine : :poly]
      end

      # The residuals of switching on a complex exponential e^(2 pi i g t)
      # (cycles per sample g) at t = 0, for synced sines: h applied to it is
      # H(g) e^(2 pi i g t) + E(g, t) e^(2 pi i g t), with
      # E(g, t) = -(integral of h(s) e^(-2 pi i g s) for s > t), h the
      # minBLEP's impulse (piecewise constant between the points of
      # .minblep_tables, integrated exactly), so E(0, t) is the minBLEP
      # residual and E(g, 0) = -H(g).  Stored times e^(2 pi i g m1) (taking
      # out the delay, so rows interpolate well) as a contiguous DComplex of
      # [rows for g = 0 to SYNC_SINE_MAX in steps of
      # 1 / SYNC_SINE_ROWS_PER_CYCLE, SYNC_TAPS * SYNC_OVERSAMPLE + 1].
      def self.sync_sine_table(m1)
        blep, _ = minblep_tables
        os = SYNC_OVERSAMPLE
        b = blep + 1.0
        h = b[1..] - b[0...-1]
        a = Numo::DFloat.new(h.length).seq / os
        rows = (SYNC_SINE_MAX * SYNC_SINE_ROWS_PER_CYCLE).round + 1
        table = Numo::DComplex.zeros(rows, b.length)
        rows.times do |r|
          g = r.to_f / SYNC_SINE_ROWS_PER_CYCLE
          if r == 0
            c = Numo::DComplex.cast(h)
          else
            w = 2 * Math::PI * g
            e0 = Numo::NMath.exp(a * Complex(0, -w))
            e1 = Numo::NMath.exp((a + 1.0 / os) * Complex(0, -w))
            c = h * os * (e0 - e1) / Complex(0, w)
          end
          tail = c.reverse.cumsum.reverse
          row = Numo::DComplex.zeros(b.length)
          row[0...-1] = -tail
          table[r, true] = row * Complex.polar(1.0, 2 * Math::PI * g * m1)
        end
        table.freeze
      end

      # Minimum-phase version of the FIR +h+ by the real cepstrum.
      def self.minimum_phase(h)
        len = h.length
        m = 2**(Math.log2(len).ceil + 3)
        x = Numo::DFloat.zeros(m)
        x[0...len] = h
        cep = MB::Sound.ifft(Numo::NMath.log(MB::Sound.fft(x).abs + 1e-12)).real
        fold = Numo::DFloat.zeros(m)
        fold[0] = 1
        fold[1...(m / 2)] = 2
        fold[m / 2] = 1
        MB::Sound.ifft(Numo::NMath.exp(MB::Sound.fft(cep * fold))).real[0...len]
      end

      # See sync_table in fast_synth.c.
      def self.sync_table(table, os, taps, t)
        x = t * os
        return 0.0 if x < 0 || x >= (taps * os).to_f

        idx = x.to_i
        frac = x - idx
        table[idx] + (table[idx + 1] - table[idx]) * frac
      end

      # See sync_event in fast_synth.c.
      def self.sync_event(acc, pos, tables, t, a0, a1, a2)
        return if a0 == 0 && a1 == 0 && a2 == 0

        r0, r1, r2, os, taps = tables
        taps.times do |j|
          tt = t + j
          k = (pos + j) % taps
          acc[k] += a0 * sync_table(r0, os, taps, tt) + a1 * sync_table(r1, os, taps, tt) +
            a2 * sync_table(r2, os, taps, tt)
        end
      end

      # [value, slope per cycle] of +wave_type+ warped by +w+ at phase +p+
      # (for phase jumps of free-running tones; see Tone#queue_jump).
      def self.sync_shape(wave_type, w, p)
        k = p < w ? 0.5 / w : 0.5 / (1.0 - w)
        u = warp(p, w)
        [shape(wave_type, u), slope(wave_type, u) * k]
      end

      # [value, first and second derivatives per cycle] at +x+ of the segment
      # of +wave_type+ that holds phase +u+ (see .shape for +left+).  See
      # sync_segment in fast_synth.c.
      def self.sync_segment(wave_type, u, left, x)
        case wave_type
        when :ramp then [(left ? u <= 0.5 : u < 0.5) ? 2.0 * x : 2.0 * x - 2.0, 2.0, 0.0]
        when :square then [(left ? u <= 0.5 : u < 0.5) ? 1.0 : -1.0, 0.0, 0.0]
        when :triangle
          if left ? u <= 0.25 : u < 0.25
            [4.0 * x, 4.0, 0.0]
          elsif left ? u <= 0.75 : u < 0.75
            [2.0 - 4.0 * x, -4.0, 0.0]
          else
            [4.0 * x - 4.0, 4.0, 0.0]
          end
        when :sine
          v = Math.sin(x * (2.0 * Math::PI))
          [v, (2.0 * Math::PI) * Math.cos(x * (2.0 * Math::PI)), -(4.0 * Math::PI * Math::PI) * v]
        when :parabola
          if left ? u <= 0.5 : u < 0.5
            y = 1.0 - 4.0 * x
            [1.0 - y * y, 8.0 * y, -32.0]
          else
            y = 4.0 * x - 3.0
            [y * y - 1.0, 8.0 * y, 32.0]
          end
        else
          raise ArgumentError, "No band-limited version of #{wave_type.inspect}"
        end
      end

      # [value, first and second time derivatives per sample] of +wave_type+
      # warped by +w+ at phase +p+ moving at +vel+ cycles per sample (on the
      # left side of a breakpoint there if +left+, with p = 1 for the
      # cycle's end).  See sync_raw in fast_synth.c.
      def self.sync_raw(wave_type, w, p, left, vel)
        first = left ? p <= w : p < w
        k = first ? 0.5 / w : 0.5 / (1.0 - w)
        u = first ? p * k : 0.5 + (p - w) * k
        g = vel * k
        f0, f1, f2 = sync_segment(wave_type, u, left, u)
        [f0, f1 * g, f2 * (g * g)]
      end

      # [u, g]: the shape's phase +u+ (cycles) of the segment of a sine
      # warped by +w+ at phase +p+ (left side if +left+), and its frequency
      # +g+ (cycles per sample) at +vel+.  See sync_sine_segment in
      # fast_synth.c.
      def self.sync_sine_segment(w, p, left, vel)
        first = left ? p <= w : p < w
        k = first ? 0.5 / w : 0.5 / (1.0 - w)
        u = first ? p * k : 0.5 + (p - w) * k
        [u, vel * k]
      end

      # The flat Array of [re, im] pairs of a .sync_sine_table, cached.
      def self.sine_flat(table)
        @sine_flat ||= {}
        @sine_flat[table.object_id] ||= Numo::DFloat.cast(table.real).to_a.flatten.zip(Numo::DFloat.cast(table.imag).to_a.flatten).flatten
      end

      # [re, im] of .sync_sine_table at frequency +g+ (cycles per sample,
      # either sign) and +t+ samples after the switch, interpolated linearly
      # in both.  See sync_sine_lookup in fast_synth.c.
      def self.sync_sine_lookup(flat, rows, len, os, taps, g, t)
        gr = g.abs * SYNC_SINE_ROWS_PER_CYCLE
        return [0.0, 0.0] if gr >= rows - 1

        x = t * os
        return [0.0, 0.0] if x < 0 || x >= (taps * os).to_f

        r = gr.to_i
        fg = gr - r
        idx = x.to_i
        ft = x - idx
        i00 = (r * len + idx) * 2
        i10 = i00 + len * 2
        are = flat[i00] + (flat[i00 + 2] - flat[i00]) * ft
        aim = flat[i00 + 1] + (flat[i00 + 3] - flat[i00 + 1]) * ft
        bre = flat[i10] + (flat[i10 + 2] - flat[i10]) * ft
        bim = flat[i10 + 1] + (flat[i10 + 3] - flat[i10 + 1]) * ft
        re = are + (bre - are) * fg
        im = aim + (bim - aim) * fg
        im = -im if g < 0
        [re, im]
      end

      # Adds (+sign+ 1) or removes (-1) the residual of a sine segment at
      # phase +u+ and frequency +g+ switched on +t+ samples before the
      # current sample.  See sync_sine_switch in fast_synth.c.
      def self.sync_sine_switch(acc, pos, sine, t, u, g, sign)
        flat, rows, len, os, taps, m1 = sine
        psi = 2.0 * Math::PI * (u + g * (t - m1))
        dpsi = 2.0 * Math::PI * g
        cr = Math.cos(psi)
        ci = Math.sin(psi)
        sr = Math.cos(dpsi)
        si = Math.sin(dpsi)
        taps.times do |j|
          re, im = sync_sine_lookup(flat, rows, len, os, taps, g, t + j)
          acc[(pos + j) % taps] += sign * (re * ci + im * cr)

          nr = cr * sr - ci * si
          ci = cr * si + ci * sr
          cr = nr
        end
      end

      # A synced sine at phase +u+ and frequency +g+, filtered by h (see
      # sync_sine_value in fast_synth.c).
      def self.sync_sine_value(sine, u, g)
        flat, rows, len, os, taps, m1 = sine
        re, im = sync_sine_lookup(flat, rows, len, os, taps, g, 0.0)
        psi = 2.0 * Math::PI * (u - g * m1)
        -(re * Math.sin(psi) + im * Math.cos(psi))
      end

      # See sync_move in fast_synth.c; returns the new phase.
      def self.sync_move(wave_type, w, points, p, vel, dur, end_t, acc, pos, tables, bl, sine = nil)
        move = vel * dur
        if bl && move != 0
          points.each do |bpos, _, _, _|
            f = side_crossing(p, move, bpos)
            next if f.nil?

            t = end_t + (1.0 - f) * dur
            if sine
              ur, gr = sync_sine_segment(w, bpos, false, vel)
              ul, gl = sync_sine_segment(w, bpos == 0.0 ? 1.0 : bpos, true, vel)
              next if gl == gr # the same exponential (no warp here)

              if move > 0
                sync_sine_switch(acc, pos, sine, t, ul, gl, -1.0)
                sync_sine_switch(acc, pos, sine, t, ur, gr, 1.0)
              else
                sync_sine_switch(acc, pos, sine, t, ur, gr, -1.0)
                sync_sine_switch(acc, pos, sine, t, ul, gl, 1.0)
              end
              next
            end

            r = sync_raw(wave_type, w, bpos, false, vel)
            l = sync_raw(wave_type, w, bpos == 0.0 ? 1.0 : bpos, true, vel)
            if move > 0
              sync_event(acc, pos, tables, t, r[0] - l[0], r[1] - l[1], r[2] - l[2])
            else
              sync_event(acc, pos, tables, t, l[0] - r[0], l[1] - r[1], l[2] - r[2])
            end
          end
        end

        # A phase within rounding of an edge is on it (see bl_snap)
        p = wrap(p + move)
        snapped = snap(points, p)
        snapped ? points[snapped][0] : p
      end

      # Ruby mirror of MB::Sound::FastSynth.oscillate_sync (see there),
      # returning +count+ samples as an SFloat; +sync_state+ and the +ring+
      # (a DFloat) are updated like the C version.
      def self.sync_ruby(count, wave_type, freq, advance, gain, offset, sync_state, ring, pulses, soft, width, remove_dc, r0, r1, r2, os, taps, bl, m1, m2, sine_table = nil, reset_phase = nil)
        reset_phase = reset_phase.nil? ? 0.0 : reset_phase.to_f
        freqs = freq.is_a?(Numo::NArray) ? real_floats(freq) : nil
        pulse_list = pulses.is_a?(Numo::NArray) ? real_floats(pulses) : nil
        widths = width.is_a?(Numo::NArray) ? real_floats(width) : nil
        freq = freqs ? freqs[0] : freq.to_f
        pulse = pulse_list ? pulse_list[0] : 0.0
        w = clamp_width(widths ? widths[0] : (width || 0.5).to_f)
        half_mean = HALF_MEAN.fetch(wave_type)
        points = breakpoints(wave_type, w, true)
        tables = [r0.to_a, r1.to_a, r2.to_a, os, taps]
        m1 = bl ? m1.to_f : 0.0
        half_m2 = bl ? 0.5 * m2 : 0.0
        sine = nil
        if bl && sine_table && wave_type == :sine
          sine = [sine_flat(sine_table), sine_table.shape[0], sine_table.shape[1], os, taps, m1]
        end
        acc = ring.to_a

        p, prev_inc, dir, pos, primed = sync_state
        pos %= taps
        primed = primed != 0

        out = Numo::SFloat.zeros(count)
        count.times do |i|
          freq = freqs[i] if freqs
          pulse = pulse_list[i] if pulse_list
          if widths
            new_w = clamp_width(widths[i])
            if new_w != w
              w = new_w
              points = breakpoints(wave_type, w, true)
            end
          end

          vel = dir * (primed ? prev_inc : freq * advance)

          if primed
            if pulse != 0
              d = 1.0 - pulse.abs
              d = 0.0 if d < 0
              d = 1.0 if d > 1

              p = sync_move(wave_type, w, points, p, vel, 1.0 - d, d, acc, pos, tables, bl, sine)

              a0 = sync_raw(wave_type, w, p, false, vel)
              u0, g0 = sync_sine_segment(w, p, false, vel) if sine
              if soft
                dir = -dir
                nvel = -vel
              else
                dir = 1.0
                nvel = prev_inc
                p = reset_phase
              end
              a1 = sync_raw(wave_type, w, p, false, nvel)
              if sine
                u1, g1 = sync_sine_segment(w, p, false, nvel)
                sync_sine_switch(acc, pos, sine, d, u0, g0, -1.0)
                sync_sine_switch(acc, pos, sine, d, u1, g1, 1.0)
              elsif bl
                sync_event(acc, pos, tables, d, a1[0] - a0[0], a1[1] - a0[1], a1[2] - a0[2])
              end
              vel = nvel

              p = sync_move(wave_type, w, points, p, vel, d, 0.0, acc, pos, tables, bl, sine)
            else
              p = sync_move(wave_type, w, points, p, vel, 1.0, 0.0, acc, pos, tables, bl, sine)
            end
          end

          if sine
            u, g = sync_sine_segment(w, p, false, vel)
            v = sync_sine_value(sine, u, g)
          else
            a = sync_raw(wave_type, w, p, false, vel)
            v = a[0] - m1 * a[1] + half_m2 * a[2]
          end
          v += acc[pos]
          acc[pos] = 0.0
          pos = (pos + 1) % taps

          v -= half_mean * (2.0 * w - 1.0) if remove_dc

          out[i] = v * gain + offset

          prev_inc = freq * advance
          primed = true
        end

        if count > 0
          sync_state.replace([p, prev_inc, dir, pos, 1])
          ring[0...taps] = Numo::DFloat.cast(acc)
        end

        out
      end
    end
  end
end
