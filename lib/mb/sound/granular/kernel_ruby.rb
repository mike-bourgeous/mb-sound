module MB
  module Sound
    module Granular
      # The exact Ruby mirror of MB::Sound::FastSampler.grains (see
      # ext/mb/sound/fast_sampler/granular.c for the arguments): the same
      # double operations in the same order, signal inputs read as float32,
      # table reads through Wavetable::KernelRuby, so specs compare the two
      # for equality.
      module KernelRuby
        # Grain slot columns (FastSampler::GRAIN_COLS).
        ACTIVE, POS, STEP, AGE, LEN, WSTEP, GL, GR = (0..7).to_a
        COLS = 8

        # Global state entries (FastSampler::GRAIN_STATE_LENGTH).
        PHASE, Q, PLAYHEAD = (0..2).to_a
        STATE_LENGTH = 3

        # Window table points (plus one).
        WINDOW = 1024

        # The most grain slots.
        MAX_SLOTS = 256

        MIN_Q = 1e-3
        EPS = 1e-9
        SQRT2 = 1.4142135623730951
        QUARTER_PI = 0.78539816339744831

        module_function

        def grains(out_l, out_r, specs, slots, state, rng, window, inputs, config)
          raise ArgumentError, 'Grain inputs have 12 entries' unless inputs.length == 12
          raise ArgumentError, 'Grain config has 14 entries' unless config.length == 14

          count = out_l.length
          fs, root_hz, choices, interp, _sinc, normalize, mw2, start, stop, reversed, rate, tune, level, max_len = config
          c = {
            specs: specs, nch: specs.length, mode: Integer(interp), fs: fs.to_f, root_hz: root_hz.to_f, choices: choices.map(&:to_f),
            normalize: Integer(normalize), mw2: mw2.to_f, start: start.to_f, stop: stop.to_f, reversed: !!reversed, rate: rate.to_f,
            tune: tune.to_f, level: level.to_f, max_len: Integer(max_len),
          }
          has_freq = !inputs[9].nil?
          sig = inputs.map { |x| Wavetable::KernelRuby.signal(x, count) }
          at = ->(k, i) { sig[k][1] ? sig[k][1][i] : sig[k][0] }

          nslots = slots.shape[0]
          rows = Array.new(nslots) { |k| slots[k, true].to_a }
          win = window.to_a
          seed = [rng[0].to_i]

          phase = state[PHASE]
          q = state[Q]
          playhead = state[PLAYHEAD]
          q = 1.0 unless q >= MIN_Q
          region = c[:stop] - c[:start]

          ls = Array.new(count)
          rs = Array.new(count)
          count.times do |i|
            if at.(0, i) > 0
              playhead = 0.0
              phase = 1.0
            end

            density = at.(1, i)
            if phase >= 1.0 - EPS
              phase = phase - 1.0
              phase = 0.0 if phase < 0
              phase = 0.0 if phase >= 1
              q = spawn(c, rows, seed, playhead, density, at.(2, i), at.(3, i), at.(4, i), at.(5, i), at.(6, i), at.(7, i), at.(8, i),
                        has_freq, at.(9, i), at.(11, i))
            end
            phase = phase + density / (c[:fs] * q) if density > 0
            sc = at.(10, i)
            if sc != 0
              playhead = playhead + sc * c[:rate] / region
              playhead = Wavetable::KernelRuby.fwrap(playhead, 1.0) if playhead < 0 || playhead >= 1
            end

            l = 0.0
            r = 0.0
            rows.each do |s|
              next if s[ACTIVE] == 0

              x = s[AGE] * s[WSTEP]
              ix = x.to_i
              ix = WINDOW - 1 if ix >= WINDOW
              f = x - ix.to_f
              w = win[ix] + (win[ix + 1] - win[ix]) * f

              p = s[POS]
              m = s[STEP].abs
              vl = Wavetable::KernelRuby.value(specs[0], p, m, 0.0, c[:mode]) * w
              vr = c[:nch] > 1 ? Wavetable::KernelRuby.value(specs[1], p, m, 0.0, c[:mode]) * w : vl
              l = l + vl * s[GL]
              r = r + vr * s[GR]

              s[POS] = p + s[STEP]
              s[AGE] = s[AGE] + 1
              s[ACTIVE] = 0.0 if s[AGE] >= s[LEN]
            end
            ls[i] = l
            rs[i] = r
          end

          state[PHASE] = phase
          state[Q] = q
          state[PLAYHEAD] = playhead
          rows.each_with_index { |row, k| slots[k, true] = row }
          rng[0] = seed[0]
          out_l[true] = ls
          out_r[true] = rs
          out_l
        end

        # See gr_spawn in granular.c; returns the next interval scale.
        def spawn(c, rows, seed, playhead, density, size, position, spread, pitch, pitch_spread, pan_spread, reverse, has_freq, freq, jitter)
          u1, u2, u3, u4, u5, u6 = Array.new(6) { Tone.noise_random(seed) }

          j = jitter
          j = 0.0 if j < 0
          j = 1.0 if j > 1
          nq = (1.0 - j) + j * -Math.log(1.0 - u6)
          nq = MIN_Q unless nq >= MIN_Q

          s = rows.find { |row| row[ACTIVE] == 0 }
          return nq unless s

          p = position + playhead
          p = Wavetable::KernelRuby.fwrap(p, 1.0) if p < 0 || p > 1
          p = p + spread * (2.0 * u1 - 1.0)
          p = 0.0 if p < 0
          p = 1.0 if p > 1

          semis = pitch + c[:tune]
          n = c[:choices].length
          if n > 0
            ci = (u2 * n.to_f).floor
            ci = n - 1 if ci >= n
            semis = semis + c[:choices][ci]
          end
          semis = semis + pitch_spread * (2.0 * u3 - 1.0)
          sp = 2.0**(semis / 12.0) * c[:rate]
          sp = sp * (freq / c[:root_hz]) if has_freq && c[:root_hz] > 0
          return nq unless sp > 1e-6 && sp.finite?

          ls = (size * c[:fs] + 0.5).floor.to_f
          ls = 2.0 unless ls >= 2
          ls = c[:max_len].to_f if ls > c[:max_len]
          len = c[:stop] - c[:start]
          span = (ls - 1.0) * sp
          if span > len - 1.0
            ls = ((len - 1.0) / sp).floor.to_f + 1.0
            span = (ls - 1.0) * sp
          end
          return nq if ls < 2

          center = c[:reversed] ? c[:stop] - p * len : c[:start] + p * len
          a = center - span * 0.5
          amax = c[:stop] - 1.0 - span
          a = amax if a > amax
          a = c[:start] if a < c[:start]

          dir = c[:reversed] ? -1.0 : 1.0
          dir = -dir if u5 < reverse

          pan = pan_spread * (2.0 * u4 - 1.0)
          pan = -1.0 if pan < -1
          pan = 1.0 if pan > 1
          ang = (pan + 1.0) * QUARTER_PI
          gl = Math.cos(ang) * SQRT2
          gr = Math.sin(ang) * SQRT2

          g = c[:level]
          if c[:normalize] != 0
            o = density * (ls / c[:fs]) * c[:mw2]
            g = c[:normalize] == 2 ? g / o : g / Math.sqrt(o) if o > 1
          end

          s[ACTIVE] = 1.0
          s[POS] = dir > 0 ? a : a + span
          s[STEP] = dir * sp
          s[AGE] = 0.0
          s[LEN] = ls
          s[WSTEP] = WINDOW.to_f / ls
          s[GL] = gl * g
          s[GR] = gr * g
          nq
        end
      end
    end
  end
end
