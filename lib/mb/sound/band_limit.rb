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
      def self.breakpoints(wave_type, w = 0.5)
        k1 = 0.5 / w
        k2 = 0.5 / (1.0 - w)

        candidates(wave_type).filter_map do |ub|
          ul = ub == 0.0 ? 1.0 : ub
          kr = ub < 0.5 ? k1 : k2
          kl = ul <= 0.5 ? k1 : k2

          vr = shape(wave_type, ub)
          dv = vr - shape(wave_type, ul, true)
          ds = slope(wave_type, ub) * kr - slope(wave_type, ul, true) * kl
          next if dv == 0 && ds == 0

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
          f = crossing(e, d, pos)
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
        primed = primed != 0

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
      def self.sync_event(acc, pos, blep, blamp, os, taps, t, dv, ds)
        return if dv == 0 && ds == 0

        taps.times do |j|
          tt = t + j
          k = (pos + j) % taps
          acc[k] += dv * sync_table(blep, os, taps, tt) + ds * sync_table(blamp, os, taps, tt)
        end
      end

      # [value, slope per cycle] of +wave_type+ warped by +w+ at phase +p+.
      def self.sync_shape(wave_type, w, p)
        k = p < w ? 0.5 / w : 0.5 / (1.0 - w)
        u = warp(p, w)
        [shape(wave_type, u), slope(wave_type, u) * k]
      end

      # See sync_move in fast_synth.c; returns the new phase.
      def self.sync_move(points, p, vel, dur, end_t, acc, pos, blep, blamp, os, taps, bl)
        move = vel * dur
        if bl && move != 0
          points.each do |bpos, bdv, bds, _|
            f = crossing(p, move, bpos)
            next if f.nil?

            dv = move > 0 ? bdv : -bdv
            ds = bds * vel.abs
            t = end_t + (1.0 - f) * dur
            sync_event(acc, pos, blep, blamp, os, taps, t, dv, ds)
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
      def self.sync_ruby(count, wave_type, freq, advance, gain, offset, sync_state, ring, pulses, soft, width, remove_dc, blep, blamp, os, taps, bl)
        freqs = freq.is_a?(Numo::NArray) ? real_floats(freq) : nil
        pulse_list = pulses.is_a?(Numo::NArray) ? real_floats(pulses) : nil
        widths = width.is_a?(Numo::NArray) ? real_floats(width) : nil
        freq = freqs ? freqs[0] : freq.to_f
        pulse = pulse_list ? pulse_list[0] : 0.0
        w = clamp_width(widths ? widths[0] : (width || 0.5).to_f)
        half_mean = HALF_MEAN.fetch(wave_type)
        points = breakpoints(wave_type, w)
        blep = blep.to_a
        blamp = blamp.to_a
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
              points = breakpoints(wave_type, w)
            end
          end

          if primed
            vel = dir * prev_inc

            if pulse != 0
              d = 1.0 - pulse.abs
              d = 0.0 if d < 0
              d = 1.0 if d > 1

              p = sync_move(points, p, vel, 1.0 - d, d, acc, pos, blep, blamp, os, taps, bl)

              v0, s0 = sync_shape(wave_type, w, p)
              if soft
                dir = -dir
                nvel = -vel
                sync_event(acc, pos, blep, blamp, os, taps, d, 0.0, s0 * (nvel - vel)) if bl
                vel = nvel
              else
                dir = 1.0
                nvel = prev_inc
                p = 0.0
                v1, s1 = sync_shape(wave_type, w, p)
                sync_event(acc, pos, blep, blamp, os, taps, d, v1 - v0, s1 * nvel - s0 * vel) if bl
                vel = nvel
              end

              p = sync_move(points, p, vel, d, 0.0, acc, pos, blep, blamp, os, taps, bl)
            else
              p = sync_move(points, p, vel, 1.0, 0.0, acc, pos, blep, blamp, os, taps, bl)
            end
          end

          v, _ = sync_shape(wave_type, w, p)
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
