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
      # Wave types that have band-limited versions.
      WAVES = [:ramp, :square, :triangle].freeze

      # Frequencies (Hz) over which Tone#lfo fades band-limiting in.
      LFO_FADE = (15.0..30.0).freeze

      INV_2PI = 1.0 / (2.0 * Math::PI)

      # Phases this close to an edge (cycles) count as on it.
      EPS = 1e-9

      # The naive waveform at phase +u+ (cycles, 0..1).
      def self.shape(wave_type, u)
        case wave_type
        when :ramp then u < 0.5 ? 2.0 * u : 2.0 * u - 2.0
        when :square then u < 0.5 ? 1.0 : -1.0
        when :triangle
          if u < 0.25
            4.0 * u
          elsif u < 0.75
            2.0 - 4.0 * u
          else
            4.0 * u - 4.0
          end
        else
          raise ArgumentError, "No band-limited version of #{wave_type.inspect}"
        end
      end

      # Breakpoints of +wave_type+: [phase (cycles), jump in value, jump in
      # slope per cycle], moving forward.
      def self.breakpoints(wave_type)
        case wave_type
        when :ramp then [[0.5, -2.0, 0.0]]
        when :square then [[0.0, 2.0, 0.0], [0.5, -2.0, 0.0]]
        when :triangle then [[0.25, 0.0, -8.0], [0.75, 0.0, 8.0]]
        else raise ArgumentError, "No band-limited version of #{wave_type.inspect}"
        end
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

      # Returns phase +e+ moved onto any breakpoint within EPS of it, so a
      # sample at an edge takes the value after the edge (see bl_snap in
      # fast_synth.c).
      def self.snap(points, e)
        points.each do |pos, _, _|
          diff = (e - pos).abs
          return pos if diff < EPS || diff > 1.0 - EPS
        end
        e
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

      # The correction for edges crossed while moving from +e+ by +d+; see
      # bl_step in fast_synth.c.
      def self.correction(points, e, d, after, adv, lo, hi)
        corr = 0.0
        k = nil

        points.each do |pos, dv, ds|
          f = crossing(e, d, pos)
          next if f.nil?

          if k.nil?
            k = fade(d.abs / adv, lo, hi)
            return 0.0 if k == 0
          end

          dv = d > 0 ? dv : -dv
          ds *= d.abs

          x = after ? f : 1.0 - f
          blep = after ? -0.5 * x * x : 0.5 * x * x
          blamp = x * x * x / 6.0

          corr += k * (dv * blep + ds * blamp)
        end

        corr
      end

      # The real parts of +narray+ rounded to single precision, as the C code
      # reads signal inputs (mb_read_signal_input in ext/mb/sound/include/mb_ext_helpers.h).
      def self.real_floats(narray)
        narray = narray.real if narray.is_a?(Numo::SComplex) || narray.is_a?(Numo::DComplex)
        Numo::SFloat.cast(narray).to_a
      end

      # Ruby mirror of MB::Sound::FastSynth.oscillate_bl, returning +count+ samples
      # as an SFloat.  +freq+ and +phase_mod+ (radians) are Numerics or
      # NArrays; +state+ is the phasor's [phi] and +bl_state+ the
      # band-limiting state, both updated like the C version.
      def self.oscillate_ruby(count, wave_type, freq, phase_mod, advance, gain, offset, state, bl_state, fade_lo, fade_hi)
        points = breakpoints(wave_type)
        freqs = freq.is_a?(Numo::NArray) ? real_floats(freq) : nil
        pms = phase_mod.is_a?(Numo::NArray) ? real_floats(phase_mod) : nil
        freq = freqs ? freqs[0] : freq.to_f
        pm = pms ? pms[0] : (phase_mod || 0).to_f

        phi = state[0].to_f
        prev_e, prev_inc, prev_pm, primed = bl_state
        primed = primed != 0

        out = Numo::SFloat.zeros(count)
        steps = 0.0
        e = inc = 0.0
        count.times do |i|
          freq = freqs[i] if freqs
          pm = pms[i] if pms

          inc = freq * advance
          steps = inc * i unless freqs

          e = wrap(phi + steps)
          e = wrap(e + pm * INV_2PI) if pm != 0
          e = snap(points, e)
          v = shape(wave_type, e)

          d_back = prev_inc + (pm - prev_pm) * INV_2PI
          if primed && (i > 0 || (wrap(prev_e + d_back - e + 0.5) - 0.5).abs < 1e-6)
            v += correction(points, prev_e, d_back, true, advance, fade_lo, fade_hi)
          end

          if i + 1 < count
            next_pm = pms ? pms[i + 1] : pm
          else
            next_pm = pm + (pm - (i > 0 || primed ? prev_pm : pm))
          end
          d_fwd = inc + (next_pm - pm) * INV_2PI
          v += correction(points, e, d_fwd, false, advance, fade_lo, fade_hi)

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
    end
  end
end
