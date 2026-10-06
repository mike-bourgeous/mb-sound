module MB
  module Sound
    class Wavetable
      # Ruby mirrors of the MB::Sound::FastWavetable kernels (see
      # ext/mb/sound/fast_wavetable/fast_wavetable.c), sample by sample with
      # the same arithmetic in the same order, so specs can require exactly
      # equal output.  Signal inputs given as NArrays are read as 32-bit
      # floats, as in C.  +spec+ is Wavetable#kernel_spec.
      module KernelRuby
        INV_2PI = 1.0 / (2.0 * Math::PI)

        # Olli Niemitalo's optimal 4-point, 4th-order interpolator for 4x
        # oversampled data, z-form (even and odd coefficient pairs for c0..c4;
        # see the Wavetable class description).
        OPTIMAL = [
          [0.46567255120778489, 0.03432729708429672],
          [0.53743830753560162, 0.15429462557307461],
          [-0.251942101340217441, 0.25194744935939062],
          [-0.46896069955075126, 0.15578800670302476],
          [0.00986988334359864, -0.00989340017126506],
        ].freeze

        # Taps on each side of the center for sinc interpolation.
        SINC_HALF = DelayLine::SINC_HALF

        module_function

        # Ruby version of FastWavetable.oscillate (see Wavetable#oscillate).
        def oscillate(out, spec, freq, adv, g, off, state, tstate, phase_mod, width, scan, interp, remove_dc)
          count = out.length
          phi = state[0].to_f
          f_s, f_a = signal(freq, count)
          pm_s, pm_a = signal(phase_mod, count)
          warped = !width.nil?
          w_s, w_a = signal(warped ? width : 0.5, count)
          sc_s, sc_a = signal(scan, count)
          remove_dc &&= warped

          w = BandLimit.clamp_width(w_s)
          prev_pm = tstate[2] != 0 ? tstate[1].to_f : pm_s
          constant = f_a.nil?
          steps = 0.0
          values = Array.new(count)

          count.times do |i|
            fr = f_a ? f_a[i] : f_s
            pm = pm_a ? pm_a[i] : pm_s
            w = BandLimit.clamp_width(w_a[i]) if w_a
            sc = sc_a ? sc_a[i] : sc_s

            inc = fr * adv
            steps = inc * i if constant

            e = wrap(phi + steps)
            e = wrap(e + pm * INV_2PI) if pm != 0

            if w != 0.5
              k1 = 0.5 / w
              k2 = 0.5 / (1.0 - w)
              u = e < w ? e * k1 : 0.5 + (e - w) * k2
              wf = k1 > k2 ? k1 : k2
            else
              u = e
              wf = 1.0
            end

            d = inc + (pm - prev_pm) * INV_2PI
            v = value(spec, u, d.abs * wf, sc, interp)
            v -= half_mean(spec, sc) * (2.0 * w - 1.0) if remove_dc

            values[i] = gain(v, g, off)
            prev_pm = pm
            steps += inc unless constant
          end

          steps = f_s * adv * count if constant
          state[0] = wrap(phi + steps)
          if count > 0
            tstate[1] = prev_pm
            tstate[2] = 1
          end

          store(out, values)
        end

        # Ruby version of FastWavetable.lookup (see Wavetable#lookup).
        def lookup(out, spec, phase, increments, scan, interp, wrap_mode)
          count = out.length
          ph_s, ph_a = signal(phase, count)
          inc_s, inc_a = signal(increments, count)
          sc_s, sc_a = signal(scan, count)

          values = Array.new(count) { |i|
            ph = ph_a ? ph_a[i] : ph_s
            inc = inc_a ? inc_a[i] : inc_s
            sc = sc_a ? sc_a[i] : sc_s

            case wrap_mode
            when 0
              u = wrap(ph)
            when 1
              b = ph - 2.0 * (ph / 2.0).floor
              u = b > 1 ? 2.0 - b : b
            when 2
              u = ph < 0 ? 0.0 : (ph > 1 ? 1.0 : ph)
            else
              next 0.0 if ph < 0 || ph >= 1

              u = ph
            end

            value(spec, u, inc.abs, sc, interp)
          }

          store(out, values)
        end

        # Ruby version of FastWavetable.play (see Wavetable#play).
        def play(out, spec, freq, adv, speed, g, off, state, tstate, interp)
          count = out.length
          phi = state[0].to_f
          pos = tstate[0].to_f
          f_s, f_a = signal(freq, count)
          looped = !spec[8].nil?
          ls = spec[11]
          le = spec[12]
          len = le - ls

          constant = f_a.nil?
          steps = 0.0
          psteps = 0.0
          values = Array.new(count)

          count.times do |i|
            fr = f_a ? f_a[i] : f_s
            inc = fr * adv
            sp = fr * speed
            if constant
              steps = inc * i
              psteps = sp * i
            end

            p = pos + psteps
            p = ls + fwrap(p - ls, len) if looped && p >= le

            values[i] = gain(value(spec, p, sp.abs, 0.0, interp), g, off)

            unless constant
              steps += inc
              psteps += sp
            end
          end

          if constant
            steps = f_s * adv * count
            psteps = f_s * speed * count
          end
          state[0] = wrap(phi + steps)
          p = pos + psteps
          p = ls + fwrap(p - ls, len) if looped && p >= le
          tstate[0] = p
          tstate[2] = 1 if count > 0

          store(out, values)
        end

        # The table's value at +u+ (cycles, or source samples in sample mode)
        # moving +m+ per sample (picking levels), at +scan+.
        def value(spec, u, m, scan, interp)
          datas = spec[2]
          n = datas.length
          fa, fb, fs = frames(spec[1], scan)
          return level(spec, 0, u, fa, fb, fs, interp) if n == 1

          hi = spec[5]
          lo = spec[6]
          k = 0
          k += 1 while k < n - 1 && m > hi[k]

          if k < n - 1 && m > lo[k]
            t = (m - lo[k]) / (hi[k] - lo[k])
            v1 = level(spec, k, u, fa, fb, fs, interp)
            v2 = level(spec, k + 1, u, fa, fb, fs, interp)
            v1 + (v2 - v1) * t
          else
            level(spec, k, u, fa, fb, fs, interp)
          end
        end

        # Level +k+'s value at +u+.
        def level(spec, k, u, fa, fb, fs, interp)
          guard = spec[14]

          if spec[0] == 0
            return interpolate(spec[2][k], fa, fb, fs, u * spec[4][k], interp, guard)
          end

          if spec[8] && u >= spec[11]
            return interpolate(spec[8][k], 0, nil, 0.0, (u - spec[11]) * spec[10][k], interp, guard)
          end

          q = u * spec[4][k]
          i = q.floor
          return 0.0 if i < -(guard - SINC_HALF) || i > spec[3][k] + guard - SINC_HALF - 1

          interpolate(spec[2][k], 0, nil, 0.0, q, interp, guard)
        end

        # Interpolates rows +fa+ and +fb+ (blended by +fs+; +fb+ nil for one
        # row) of +data+ at +q+ samples past the guard.
        def interpolate(data, fa, fb, fs, q, interp, guard)
          i = q.floor
          t = q - i
          base = guard + i

          row = if fb
                  ->(j) {
                    ya = data[fa, j]
                    ya + (data[fb, j] - ya) * fs
                  }
                else
                  ->(j) { data[fa, j] }
                end

          case interp
          when 0
            row.(base)

          when 1
            y0 = row.(base)
            y1 = row.(base + 1)
            y0 + (y1 - y0) * t

          when 2
            ym1 = row.(base - 1)
            y0 = row.(base)
            y1 = row.(base + 1)
            y2 = row.(base + 2)
            c0 = y0
            c1 = 0.5 * (y1 - ym1)
            c2 = ym1 - 2.5 * y0 + 2.0 * y1 - 0.5 * y2
            c3 = 0.5 * (y2 - ym1) + 1.5 * (y0 - y1)
            ((c3 * t + c2) * t + c1) * t + c0

          when 3
            ym1 = row.(base - 1)
            y0 = row.(base)
            y1 = row.(base + 1)
            y2 = row.(base + 2)
            z = t - 0.5
            even1 = y1 + y0
            odd1 = y1 - y0
            even2 = y2 + ym1
            odd2 = y2 - ym1
            c0 = even1 * OPTIMAL[0][0] + even2 * OPTIMAL[0][1]
            c1 = odd1 * OPTIMAL[1][0] + odd2 * OPTIMAL[1][1]
            c2 = even1 * OPTIMAL[2][0] + even2 * OPTIMAL[2][1]
            c3 = odd1 * OPTIMAL[3][0] + odd2 * OPTIMAL[3][1]
            c4 = even1 * OPTIMAL[4][0] + even2 * OPTIMAL[4][1]
            (((c4 * z + c3) * z + c2) * z + c1) * z + c0

          else
            return row.(base) if t == 0

            sum = 0.0
            wsum = 0.0
            ((q - SINC_HALF).ceil..(q + SINC_HALF).floor).each do |kk|
              w = sinc_weight((kk - q).abs)
              sum += row.(guard + kk) * w
              wsum += w
            end
            wsum != 0 ? sum / wsum : 0.0
          end
        end

        # The sinc kernel's weight at +x+ samples from its center (see
        # Wavetable::SINC_KERNEL; the same as DelayLine#sinc_weight).
        def sinc_weight(x)
          table = SINC_KERNEL[0]
          u = x * SINC_KERNEL[2]
          j = u.to_i
          return 0.0 if j + 1 >= table.length

          f = u - j
          table[j] + (table[j + 1] - table[j]) * f
        end

        # [first frame, second frame or nil, blend] for +scan+ (0..1,
        # clamped) across +count+ frames.
        def frames(count, scan)
          return [0, nil, 0.0] if count == 1

          f = scan * (count - 1)
          f = 0.0 unless f >= 0
          f = (count - 1).to_f if f > count - 1
          fa = f.floor
          fa = count - 2 if fa > count - 2
          [fa, fa + 1, f - fa]
        end

        # The half mean (see Builder.half_means) at +scan+.
        def half_mean(spec, scan)
          hm = spec[7]
          fa, fb, fs = frames(spec[1], scan)
          return hm[fa] unless fb

          hm[fa] + (hm[fb] - hm[fa]) * fs
        end

        # Applies the output gain and offset (the offset to the real part).
        def gain(v, g, off)
          v.is_a?(Complex) ? Complex(v.real * g + off, v.imag * g) : v * g + off
        end

        # [scalar, Array or nil] for a kernel input: a Numeric (or nil, 0) as
        # a Float, or an NArray's real parts as 32-bit floats.
        def signal(input, count)
          case input
          when Numo::NArray
            raise ArgumentError, 'Input array length does not match sample buffer length' unless input.length == count

            a = Numo::SComplex.cast(input).real.to_a
            [a[0] || 0.0, a]
          when nil
            [0.0, nil]
          else
            [input.to_f, nil]
          end
        end

        def wrap(x)
          x - x.floor
        end

        # x wrapped to 0...y (like Ruby's %, as mb_wrap in C).
        def fwrap(x, y)
          x - y * (x / y).floor
        end

        def store(out, values)
          if out.is_a?(Numo::SComplex) || out.is_a?(Numo::DComplex)
            out[true] = values.map { |v| v.is_a?(Complex) ? v : Complex(v, 0) }
          else
            out[true] = values.map { |v| v.is_a?(Complex) ? v.real : v }
          end
          out
        end
      end
    end
  end
end
