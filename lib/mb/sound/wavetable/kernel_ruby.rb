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
        def oscillate(out, spec, freq, adv, g, off, state, tstate, phase_mod, width, scan, interp, remove_dc, rndadv = 0.0, noise = nil)
          count = out.length
          phi = state[0].to_f
          f_s, f_a = signal(freq, count)
          pm_s, pm_a = signal(phase_mod, count)
          warped = !width.nil?
          w_s, w_a = signal(warped ? width : 0.5, count)
          sc_s, sc_a = signal(scan, count)
          remove_dc &&= warped

          w = BandLimit.clamp_width(w_s)
          primed = tstate[2] != 0
          prev_pm = primed ? tstate[1].to_f : pm_s
          prev_e = tstate[3].to_f
          prev_inc = tstate[4].to_f
          corners = warped && spec[5][0].finite?
          pending = 0.0
          pending_d = 0.0
          rndadv = rndadv.to_f
          constant = f_a.nil? && rndadv == 0
          steps = 0.0
          values = Array.new(count)

          count.times do |i|
            fr = f_a ? f_a[i] : f_s
            pm = pm_a ? pm_a[i] : pm_s
            w = BandLimit.clamp_width(w_a[i]) if w_a
            sc = sc_a ? sc_a[i] : sc_s

            if rndadv != 0
              r = Tone.noise_random(noise) * rndadv
              a = adv + r
              inc = fr * a
            else
              inc = fr * adv
            end
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

            d = (rndadv != 0 ? fr * (adv + 0.5 * rndadv) : inc) + (pm - prev_pm) * INV_2PI
            m = d.abs * wf
            v = value(spec, u, m, sc, interp)

            if corners
              d_back = prev_inc + (pm - prev_pm) * INV_2PI
              if i > 0 && d_back == pending_d
                v = add(v, pending)
              elsif primed && (i > 0 || (wrap(prev_e + d_back - e + 0.5) - 0.5).abs < 1e-6)
                _before, after = corner_step(spec, prev_e, d_back, w, m, sc, interp)
                v = add(v, after)
              end

              if i + 1 < count
                next_pm = pm_a ? pm_a[i + 1] : pm
              else
                next_pm = pm + (pm - (i > 0 || primed ? prev_pm : pm))
              end
              d_fwd = inc + (next_pm - pm) * INV_2PI
              before, pending = corner_step(spec, e, d_fwd, w, m, sc, interp)
              v = add(v, before)
              pending_d = d_fwd
            end

            v = add(v, -half_mean(spec, sc) * (2.0 * w - 1.0)) if remove_dc

            values[i] = gain(v, g, off)
            prev_pm = pm
            prev_e = e
            prev_inc = inc
            primed = true
            steps += inc unless constant
          end

          steps = f_s * adv * count if constant
          state[0] = wrap(phi + steps)
          if count > 0
            tstate[1] = prev_pm
            tstate[2] = 1
            tstate[3] = prev_e
            tstate[4] = prev_inc
          end

          store(out, values)
        end

        # Adds the real and imaginary parts of +c+ (a Complex correction) to
        # +v+ as C does (separately; a real +v+ takes only the real part).
        def add(v, c)
          if v.is_a?(Complex)
            Complex(v.real + c.real, v.imag + c.imag)
          else
            v + c.real
          end
        end

        # [correction before, correction after] (Complex) for the warp
        # corners crossed moving from +e+ by +d+ (see wt_corner_step in C).
        def corner_step(spec, e, d, w, m, sc, interp)
          bre = bim = are = aim = 0.0
          [0.0, w].each_with_index do |b, j|
            f = crossing(e, d, b)
            next if f < 0

            k1 = 0.5 / w
            k2 = 0.5 / (1.0 - w)
            jump = (j == 0 ? k1 - k2 : k2 - k1) * d.abs
            u = j == 0 ? 0.0 : 0.5
            dre = [0.0, 0.0]
            dim = [0.0, 0.0]
            spectral_derivs(spec, u, select(spec, m, sc), 2, dre, dim)
            sre = dre[1]
            sim = dim[1]

            xa = f
            xb = 1.0 - f
            ca = xa * xa * xa / 6.0
            cb = xb * xb * xb / 6.0
            are += sre * jump * ca
            aim += sim * jump * ca
            bre += sre * jump * cb
            bim += sim * jump * cb
          end
          [Complex(bre, bim), Complex(are, aim)]
        end

        # See wt_crossing in C (and bl_crossing in fast_synth.c).
        def crossing(e, d, b)
          if d > 0
            dist = b - e
          elsif d < 0
            dist = e - b
          else
            return -1
          end
          dist += 1.0 if dist < 0
          dist = 1.0 if dist == 0

          ad = d.abs
          return -1 if ad >= 1.0 || dist > ad + BandLimit::EPS

          dist >= ad ? 1.0 : dist / ad
        end

        # Ruby version of FastWavetable.lookup (see Wavetable#lookup).
        # Samples the held peak of the phase change lasts (see FastWavetable.lookup).
        HOLD = 1024

        # Release factor per sample of the held peak.
        RELEASE = 0.995

        def lookup(out, spec, phase, increments, scan, interp, wrap_mode, lstate = nil)
          count = out.length
          ph_s, ph_a = signal(phase, count)
          automatic = increments.nil?
          inc_s, inc_a = automatic || increments.equal?(false) ? [0.0, nil] : signal(increments, count)
          sc_s, sc_a = signal(scan, count)

          if automatic
            raise ArgumentError, 'Lookup state must have four elements' unless lstate.is_a?(Array) && lstate.length == 4

            prev = lstate[0].to_f
            primed = lstate[1] != 0
            peak = lstate[2].to_f
            hold = lstate[3].to_i
          end

          values = Array.new(count) { |i|
            ph = ph_a ? ph_a[i] : ph_s
            inc = inc_a ? inc_a[i] : inc_s
            sc = sc_a ? sc_a[i] : sc_s

            if automatic
              d = 0.0
              if primed
                d = ph - prev
                if wrap_mode == 0
                  d -= (d + 0.5).floor
                elsif wrap_mode == 4
                  d *= 0.5
                end
                d = d.abs
              end
              if d >= peak
                peak = d
                hold = HOLD
              elsif hold > 0
                hold -= 1
              else
                r = peak * RELEASE
                peak = r > d ? r : d
              end
              prev = ph
              primed = true
              m = peak
            else
              m = inc.abs
            end

            case wrap_mode
            when 0
              u = wrap(ph)
            when 1
              b = ph - 2.0 * (ph / 2.0).floor
              u = b > 1 ? 2.0 - b : b
            when 2
              u = ph < 0 ? 0.0 : (ph > 1 ? 1.0 : ph)
            when 4
              u = (ph + 1.0) * 0.5
              u = u < 0 ? 0.0 : (u > 1 ? 1.0 : u)
            else
              next 0.0 if ph < 0 || ph >= 1

              u = ph
            end

            value(spec, u, m, sc, interp)
          }

          if automatic && count > 0
            lstate.replace([prev, 1, peak, hold])
          end

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

        TWO_PI = 2.0 * Math::PI

        # [k, two levels?, x, fa, fb, fs]: see wt_select in C.
        def select(spec, m, scan)
          fa, fb, fs = frames(spec[1], scan)
          n = spec[2].length
          k = 0
          if n > 1
            hi = spec[5]
            k += 1 while k < n - 1 && m > hi[k]
          end
          two = n > 1 && k < n - 1 && m > spec[6][k]
          x = two ? (m - spec[6][k]) / (spec[5][k] - spec[6][k]) : 0.0
          [k, two, x, fa, fb || -1, fs]
        end

        # See wt_harmonic_derivs in C: adds derivatives of orders
        # 1...+orders+ of frame +f+'s harmonics 1..+harmonics+ at +u+ times
        # +weight+ to +dre+/+dim+.
        def harmonic_derivs(spectra, f, harmonics, taper, u, orders, weight, dre, dim)
          cu = Math.cos(TWO_PI * u)
          su = Math.sin(TWO_PI * u)
          er = 1.0
          ei = 0.0
          sre = Array.new(orders, 0.0)
          sim = Array.new(orders, 0.0)

          (1..harmonics).each do |h|
            nr = er * cu - ei * su
            ni = er * su + ei * cu
            er = nr
            ei = ni

            c = spectra[f, h]
            cr = c.real
            ci = c.imag
            zr = cr * er - ci * ei
            zi = cr * ei + ci * er
            if taper
              x = Math::PI * h.to_f / (harmonics + 1).to_f
              g = Math.sin(x) / x
              zr *= g
              zi *= g
            end

            w = TWO_PI * h.to_f
            pr = 1.0
            pi = 0.0
            (1...orders).each do |o|
              qr = -pi * w
              qi = pr * w
              pr = qr
              pi = qi
              sre[o] += zr * pr - zi * pi
              sim[o] += zr * pi + zi * pr
            end
          end

          (1...orders).each do |o|
            dre[o] += sre[o] * weight
            dim[o] += sim[o] * weight
          end
        end

        # See wt_spectral_derivs in C.
        def spectral_derivs(spec, u, sel, orders, dre, dim)
          (1...orders).each { |o| dre[o] = 0.0; dim[o] = 0.0 }
          spectra = spec[15]
          return if spectra.nil?

          k, two, x, fa, fb, fs = sel
          cols = spectra.shape[1]
          taper = spec[17] != 0
          (two ? 2 : 1).times do |l|
            lw = two ? (l == 0 ? 1.0 - x : x) : 1.0
            h = [spec[16][k + l], cols - 1].min
            if fb < 0
              harmonic_derivs(spectra, fa, h, taper, u, orders, lw, dre, dim)
            else
              harmonic_derivs(spectra, fa, h, taper, u, orders, lw * (1.0 - fs), dre, dim)
              harmonic_derivs(spectra, fb, h, taper, u, orders, lw * fs, dre, dim)
            end
          end
        end

        # Ruby version of FastWavetable.sync (see Wavetable#sync).
        def sync(out, spec, freq, adv, g, off, sync_state, ring, pulses, soft, width, scan, interp, remove_dc, tables, os, taps, bl)
          count = out.length
          cs = spec[2][0].is_a?(Numo::SComplex) ? 2 : 1
          f_s, f_a = signal(freq, count)
          pu_s, pu_a = signal(pulses, count)
          pu_s = 0.0 unless pu_a
          warped = !width.nil?
          w_s, w_a = signal(warped ? width : 0.5, count)
          sc_s, sc_a = signal(scan, count)
          remove_dc &&= warped
          tables = tables.map(&:to_a)
          orders = tables.length
          acc = ring.to_a

          p, prev_inc, dir, pos, primed = sync_state
          p = p.to_f
          prev_inc = prev_inc.to_f
          dir = dir.to_f
          pos %= taps
          primed = primed != 0
          w = BandLimit.clamp_width(w_s)
          fr = f_s
          pulse = pu_s
          sc = sc_s

          shape = ->(ph, m) {
            u = w != 0.5 ? (ph < w ? ph * (0.5 / w) : 0.5 + (ph - w) * (0.5 / (1.0 - w))) : ph
            v = value(spec, u, m, sc, interp)
            v.is_a?(Complex) ? [v.real, v.imag] : [v, 0.0]
          }
          derivs = ->(ph, m) {
            v0 = shape.(ph, m)
            re = [v0[0]] + Array.new(orders - 1, 0.0)
            im = [v0[1]] + Array.new(orders - 1, 0.0)
            k = 1.0
            u = ph
            if w != 0.5
              k = ph < w ? 0.5 / w : 0.5 / (1.0 - w)
              u = ph < w ? ph * (0.5 / w) : 0.5 + (ph - w) * (0.5 / (1.0 - w))
            end
            spectral_derivs(spec, u, select(spec, m, sc), orders, re, im)
            kk = 1.0
            (1...orders).each do |o|
              kk *= k
              re[o] *= kk
              im[o] *= kk
            end
            [re, im]
          }
          event = ->(t, jre, jim) {
            any = (0...orders).any? { |o| jre[o] != 0 || (cs == 2 && jim[o] != 0) }
            next unless any

            taps.times do |j|
              tt = t + j
              k = (pos + j) % taps
              sre = 0.0
              sim = 0.0
              orders.times do |o|
                r = BandLimit.sync_table(tables[o], os, taps, tt)
                sre += jre[o] * r
                sim += jim[o] * r
              end
              acc[k] += sre
              acc[taps + k] += sim if cs == 2
            end
          }

          values = Array.new(count)
          count.times do |i|
            fr = f_a[i] if f_a
            pulse = pu_a[i] if pu_a
            w = BandLimit.clamp_width(w_a[i]) if w_a
            sc = sc_a[i] if sc_a

            wf = 1.0
            if w != 0.5
              k1 = 0.5 / w
              k2 = 0.5 / (1.0 - w)
              wf = k1 > k2 ? k1 : k2
            end
            m = (fr * adv).abs * wf

            if primed
              vel = dir * prev_inc

              if pulse != 0
                d = 1.0 - pulse.abs
                d = 0.0 if d < 0
                d = 1.0 if d > 1

                p = wrap(p + vel * (1.0 - d))
                d0re, d0im = derivs.(p, m) if bl
                if soft
                  dir = -dir
                  nvel = -vel
                  if bl
                    jre = []
                    jim = []
                    nk = 1.0
                    vk = 1.0
                    orders.times do |o|
                      jre << d0re[o] * (nk - vk)
                      jim << d0im[o] * (nk - vk)
                      nk *= nvel
                      vk *= vel
                    end
                  end
                else
                  dir = 1.0
                  nvel = prev_inc
                  p = 0.0
                  if bl
                    d1re, d1im = derivs.(p, m)
                    jre = []
                    jim = []
                    nk = 1.0
                    vk = 1.0
                    orders.times do |o|
                      jre << d1re[o] * nk - d0re[o] * vk
                      jim << d1im[o] * nk - d0im[o] * vk
                      nk *= nvel
                      vk *= vel
                    end
                  end
                end
                event.(d, jre, jim) if bl
                vel = nvel

                p = wrap(p + vel * d)
              else
                p = wrap(p + vel)
              end
            end

            re, im = shape.(p, m)
            re += acc[pos]
            acc[pos] = 0.0
            if cs == 2
              im += acc[taps + pos]
              acc[taps + pos] = 0.0
            end
            pos = (pos + 1) % taps

            re -= half_mean(spec, sc) * (2.0 * w - 1.0) if remove_dc

            values[i] = cs == 2 ? Complex(re * g + off, im * g) : re * g + off
            prev_inc = fr * adv
            primed = true
          end

          if count > 0
            sync_state.replace([p, prev_inc, dir, pos, 1])
            ring[0...(taps * cs)] = Numo::DFloat.cast(acc)
          end

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
