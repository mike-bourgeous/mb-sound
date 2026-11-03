module MB
  module Sound
    module Analysis
      # Small array helpers shared by the sound-matching analyzers
      # (ModulationSpectrum, PitchContour, Attack, BandEnvelopes,
      # SpectralMotion, Bleed, Comparison): band powers from a magnitude
      # STFT, octave band edges, detrending, the spectrum of a slow
      # envelope, brick-wall filtering and resampling in the FFT domain.
      # Pure functions of Numo arrays; nothing here keeps state.
      module DSP
        module_function

        # Power (or any positive value) in dB, floored at +floor+ (a power).
        def db(power, floor = 1e-12)
          Numo::NMath.log10(power + floor) * 10
        end

        # [lo, hi] Hz pairs from +lo+ up to +hi+, +per_octave+ bands per
        # octave (the last band ends at or under +hi+).  With +partial:+, a
        # last, narrower band from there to +hi+ when at least a third of
        # an octave is left over.
        def octave_bands(lo, hi, per_octave = 1, partial: false)
          out = []
          f = lo.to_f
          r = 2.0**(1.0 / per_octave)
          while f * r <= hi * 1.001
            out << [f, f * r].freeze
            f *= r
          end
          out << [f, hi.to_f].freeze if partial && hi >= f * 2**(1 / 3.0)
          out.freeze
        end

        # Band powers [frames, bands] from a magnitude STFT +mag+ ([frames,
        # n_fft / 2 + 1]) of size +n_fft+ at +rate+, +bands+ as [lo, hi] Hz
        # pairs (each band sums the bins from lo's to hi's, inclusive).
        def band_power(mag, n_fft, bands, rate)
          p = mag**2
          cols = bands.map do |lo, hi|
            a = (lo * n_fft / rate.to_f).floor
            b = [(hi * n_fft / rate.to_f).ceil, p.shape[1] - 1].min
            a = [a, b].min
            p[true, a..b].sum(axis: 1)
          end
          Numo::DFloat.hstack(cols.map { |c| c.reshape(c.length, 1) })
        end

        # A periodic Hann window (as Analysis::STFT.hann), cached by length.
        def hann(n)
          @hann ||= {}
          @hann[n] ||= STFT.hann(n).freeze
        end

        # +e+ minus its least-squares line (a decay or a glide is not
        # modulation).
        def detrend(e)
          n = e.length
          return e - e.mean if n < 2
          t = Numo::DFloat.new(n).seq
          tm = t.mean
          em = e.mean
          slope = ((t - tm) * (e - em)).sum / [((t - tm)**2).sum, 1e-9].max
          e - em - slope * (t - tm)
        end

        # The least-squares slope of +e+ per frame.
        def slope(e)
          n = e.length
          return 0.0 if n < 2
          t = Numo::DFloat.new(n).seq
          tm = t.mean
          ((t - tm) * (e - e.mean)).sum / ((t - tm)**2).sum
        end

        # The spectrum of a slow signal +e+ (an envelope in dB, a pitch
        # contour in cents) sampled at +rate+ frames per second: detrended,
        # Hann-windowed, zero-padded to at least 4x its length.  Returns a
        # Hash with :hz (bin frequencies), :mag (|X|), :window_sum,
        # :window_power, :nfft, and :frames, so callers can read band variances (#band_rms) and
        # sinusoid amplitudes (#sine_peak).
        def slow_spectrum(e, rate)
          frames = e.length
          nfft = 1
          nfft *= 2 while nfft < frames * 4
          w = hann(frames)
          buf = Numo::DFloat.zeros(nfft)
          buf[0...frames] = detrend(e) * w
          mag = Numo::Pocketfft.rfft(buf).abs
          { hz: Numo::DFloat.new(mag.length).seq * (rate.to_f / nfft), mag: mag, window_sum: w.sum, window_power: (w**2).sum, nfft: nfft, frames: frames }
        end

        # The RMS (in +e+'s units) of the part of a #slow_spectrum between
        # +lo+ and +hi+ Hz (by Parseval, window power normalized).
        def band_rms(spec, lo, hi)
          m = spec[:hz].ge(lo) & spec[:hz].lt(hi)
          return 0.0 if m.count_true == 0
          Math.sqrt(2 * (spec[:mag][m]**2).sum / (spec[:nfft] * spec[:window_power]))
        end

        # The strongest component of a #slow_spectrum between +lo+ and +hi+
        # Hz: [rate Hz (parabolic interpolation on the log magnitude), peak
        # amplitude of a sinusoid at that rate (in the signal's units),
        # share of the signal's variance between +lo+ and +hi+ that lies
        # within the window's main lobe around it], or nil if the range
        # has no bins.
        def sine_peak(spec, lo, hi)
          hz = spec[:hz]
          mag = spec[:mag]
          idx = (hz.ge(lo) & hz.le(hi)).where
          return nil if idx.size < 3
          k = idx[mag[idx].max_index]
          return nil if mag[k] <= 0
          frac = 0.0
          if k > 0 && k < mag.length - 1
            a, b, c = [mag[k - 1], mag[k], mag[k + 1]].map { |v| Math.log(v + 1e-300) }
            den = a - 2 * b + c
            frac = (0.5 * (a - c) / den).clamp(-0.5, 0.5) if den.abs > 1e-12
          end
          df = hz[1] - hz[0]
          # The main lobe of a Hann window spans +-2 bins of the unpadded
          # length, which is nfft / frames padded bins each
          lobe = (2.0 * spec[:nfft] / spec[:frames]).ceil
          lobe_idx = idx.to_a.select { |i| (i - k).abs <= lobe }
          total = (mag[idx]**2).sum
          share = total > 0 ? lobe_idx.sum { |i| mag[i]**2 } / total : 0.0
          [(k + frac) * df, 2 * mag[k] / spec[:window_sum], share]
        end

        # Refines a sinusoid in +e+ (frames at +rate+ per second) near +hz+:
        # least-squares fits of a line plus a sinusoid at STEPS rates across
        # ±+span+ of +hz+, then a finer pass around the best.  A window's
        # spectrum peak reads rates of sounds only two or three cycles long
        # several percent low (detrending and the window's edges); the fit
        # doesn't.  Returns [rate Hz, amplitude (in e's units), rate
        # uncertainty Hz]: twice the Cramér-Rao bound of a sinusoid's
        # frequency in noise (Rife and Boorstyn 1974) with the fit's
        # residual as the noise, so a modulation that isn't a clean
        # sinusoid reads less certain; at least 1% of the rate.
        def sine_fit(e, rate, hz, span: 0.2, steps: 21)
          n = e.length
          t = Numo::DFloat.new(n).seq / rate.to_f
          t -= t.mean
          best = nil
          2.times do
            lo = hz * (1 - span)
            hi = hz * (1 + span)
            steps.times do |i|
              f = lo + (hi - lo) * i / (steps - 1).to_f
              fit = fit_at(e, t, f)
              best = [f, *fit] if best.nil? || fit[1] < best[2]
            end
            hz = best[0]
            span *= 2.0 / steps
          end
          f, amp, rss = best
          noise = rss / [n - 4, 1].max
          sigma = amp > 0 && n > 2 ? Math.sqrt(12 * noise / (amp**2 * n * (n**2 - 1.0))) * rate / (2 * Math::PI) : f
          [f, amp, [2 * sigma, 0.01 * f].max]
        end

        # [amplitude, residual sum of squares] of e ~ a + b t + c cos + d sin
        # at +f+ Hz.
        def fit_at(e, t, f)
          w = t * (2 * Math::PI * f)
          cols = [Numo::DFloat.ones(t.length), t, Numo::NMath.cos(w), Numo::NMath.sin(w)]
          ata = cols.map { |a| cols.map { |b| (a * b).sum } }
          atb = cols.map { |a| (a * e).sum }
          coef = solve(ata, atb)
          return [0.0, (e**2).sum] unless coef
          fitted = cols.each_with_index.sum(Numo::DFloat.zeros(t.length)) { |c, i| c * coef[i] }
          [Math.sqrt(coef[2]**2 + coef[3]**2), ((e - fitted)**2).sum]
        end

        # Solves the small system +a+ x = +b+ (Arrays) by Gaussian
        # elimination with partial pivoting; nil if singular.
        def solve(a, b)
          n = b.length
          m = a.each_with_index.map { |row, i| row.dup << b[i] }
          n.times do |c|
            p = (c...n).max_by { |r| m[r][c].abs }
            return nil if m[p][c].abs < 1e-12
            m[c], m[p] = m[p], m[c]
            (c + 1...n).each do |r|
              k = m[r][c] / m[c][c]
              (c..n).each { |j| m[r][j] -= k * m[c][j] }
            end
          end
          x = Array.new(n, 0.0)
          (n - 1).downto(0) { |r| x[r] = (m[r][n] - ((r + 1)...n).sum { |j| m[r][j] * x[j] }) / m[r][r] }
          x
        end

        # +x+ with everything above +high+ Hz (and, with +low:+, at and below
        # +low+ Hz) zeroed in the FFT domain, +pad+ zeros added first so a
        # signal cut off at full level doesn't wrap its edge into its start.
        def brickwall(x, rate, high, low: nil, pad: 4096)
          n = x.length + pad
          n += 1 if n.odd?
          xx = Numo::DFloat.zeros(n)
          xx[0...x.length] = x
          spec = Numo::Pocketfft.rfft(xx)
          if high
            cut = (high * n / rate.to_f).floor + 1
            spec[cut..] = 0 if cut < spec.length
          end
          spec[0..(low * n / rate.to_f).floor] = 0 if low
          Numo::Pocketfft.irfft(spec)[0...x.length].dup
        end

        # Band-limited resampling of +x+ from +from+ to +to+ Hz by
        # truncating or zero-padding its spectrum (+pad+ zeros added first,
        # as in #brickwall).  Returns a DFloat of the input's length at the
        # new rate.
        def resample(x, from, to, pad: 4096)
          keep = (x.length * to.to_f / from).round
          n = x.length + pad
          n += 1 if n.odd?
          xx = Numo::DFloat.zeros(n)
          xx[0...x.length] = x
          m = (n * to.to_f / from).round
          m += 1 if m.odd?
          spec = Numo::Pocketfft.rfft(xx)
          out = Numo::DComplex.zeros(m / 2 + 1)
          k = [spec.length, out.length].min
          out[0...k] = spec[0...k]
          out[k - 1] = out[k - 1].real if k == out.length
          (Numo::Pocketfft.irfft(out) * (m.to_f / n))[0...[keep, m].min].dup
        end

        # Moving average of the rows of +a+ ([frames, cols]) over +k+ frames
        # either side (fewer at the ends).
        def smooth_rows(a, k)
          f = a.shape[0]
          c = Numo::DFloat.zeros(f + 1, a.shape[1])
          c[1..-1, true] = a.cumsum(axis: 0)
          lo = (Numo::Int64.new(f).seq - k).clip(0, f)
          hi = (Numo::Int64.new(f).seq + k + 1).clip(0, f)
          (c[hi, true] - c[lo, true]) / (hi - lo).cast_to(Numo::DFloat).reshape(f, 1)
        end

        # The median of an Array of numbers (nil if empty).
        def median(values)
          return nil if values.empty?
          s = values.sort
          s.length.odd? ? s[s.length / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2.0
        end
      end
    end
  end
end
