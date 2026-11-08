module MB
  module Sound
    module BarStats
      # Timing per band (Bands: low, mid, high): where each band's onsets
      # land against the grid, and how far one recording's bands sit from
      # another's, bar by bar.  Per band, never the whole mix only: the
      # 2026-11-08 lesson was a drum bus 66 ms late that whole-mix timing
      # missed.
      #
      # The onset function of a band: its amplitude envelope (the root of
      # the squared band smoothed by a centered triangular window twice
      # SMOOTH seconds wide) and how much it rises across SMOOTH, positive
      # part.  A beat's onset is the function's largest peak within WINDOW
      # of the beat (or an attack up to ATTACK_SPAN before it), less the
      # place a hard attack reads (#calibration: a tone starting on a
      # sample, per band and rate), so attacks on a beat read about 0 ms
      # (kicks and hats within 0.5 ms, spec'd).  Chords whose tones beat
      # read later (the energy keeps rising for a beat of their beating:
      # about 13 ms for a C major triad), so compare grid offsets between
      # recordings of the same parts; between recordings, #lags is exact.
      #
      # The coarse lag search reads the onset function at about 1 kHz
      # (#coarse_onsets: block mean squares).
      #
      # Between two recordings (#lags), per bar and band: the
      # cross-correlation of their onset functions within +-max_lag finds
      # the lag (several peaks within PEAK_TIE of the best: the one nearest
      # the band's whole-song lag), then the cross-correlation of the band
      # waveforms within +-REFINE of it, with a parabola through its peak,
      # gives the lag to a fraction of a sample (exactly N for a copy
      # delayed N samples).
      module Timing
        # Envelope width per band in seconds (a low band needs a few of
        # its cycles).
        SMOOTH = { low: 0.012, mid: 0.004, high: 0.0015 }.freeze

        # Calibration tones per band in Hz (see #calibration).
        CALIBRATION_HZ = { low: 70.0, mid: 550.0, high: 5500.0 }.freeze

        # A beat's onset window, as a fraction of the beat either side.
        WINDOW = 0.25

        # A beat's onset is the largest peak of the onset function in its
        # window, or the first peak reaching this share of it up to
        # ATTACK_SPAN seconds earlier (see #attack_peak).
        ATTACK_SHARE = 0.5
        ATTACK_SPAN = 0.02

        # A beat's onset in a band counts when its strength reaches this
        # share of the band's typical (75th percentile) beat onset.
        FLOOR = 0.2

        # A band whose typical onset is under this share of the strongest
        # band's (-40 dB) has no onsets of its own (leakage from the others).
        BAND_FLOOR = 0.01

        # Waveform refinement range in seconds around the onset lag.
        REFINE = 0.002

        # Onset-correlation peaks within this share of the best are ties.
        PEAK_TIE = 0.9

        # A waveform correlation under this keeps the onset lag (rounded to
        # a sample) instead of the waveform's.
        MIN_WAVE_CORRELATION = 0.3

        module_function

        # The onset function of band signal +x+ (a DFloat) named +band+.
        def onset_function(x, band, rate)
          w = [(SMOOTH.fetch(band) * rate).round, 1].max
          # (two passes: a triangular window, whose sidelobes leave little
          # of a low note's ripple)
          env = Numo::NMath.sqrt(moving_mean(moving_mean(x * x, w), w).clip(0, nil))
          o = Numo::DFloat.zeros(env.length)
          h = w / 2
          if env.length > w
            o[h...(env.length - (w - h))] = env[w..] - env[0...(env.length - w)]
          end
          o.clip(0, nil)
        end

        # Centered moving mean of +x+ over +w+ samples (shorter at the ends).
        def moving_mean(x, w)
          n = x.length
          c = Numo::DFloat.zeros(n + 1)
          c[1..] = x.cumsum
          idx = Numo::Int64.new(n).seq
          a = (idx - w / 2).clip(0, n)
          b = (idx - w / 2 + w).clip(0, n)
          (c[b] - c[a]) / (b - a).cast_to(Numo::DFloat).clip(1, nil)
        end

        # Seconds to subtract from a found onset in each band so a hard
        # attack reads 0 at +rate+: a sine at the band's CALIBRATION_HZ
        # starting on a sample and sustaining (measured once per rate).
        def calibration(rate)
          @calibration ||= {}
          @calibration[rate.to_f] ||= begin
            n = (rate * 0.5).round
            t0 = n / 4
            Bands::NAMES.to_h { |band|
              t = (Numo::DFloat.new(n).seq - t0) / rate.to_f
              x = Numo::NMath.sin(t * (2 * Math::PI * CALIBRATION_HZ.fetch(band))) * t.ge(0)
              o = onset_function(Bands.split(x, rate)[Bands::NAMES.index(band)], band, rate)
              [band, (attack_peak(o, rate) - t0) / rate.to_f]
            }.freeze
          end
        end

        # Onsets of mono +x+ at +rate+ near each beat of +grid+: per band an
        # Array (one entry per beat) of offsets in seconds from the beat
        # (positive: late), nil where the band has no onset within
        # +window+ of a beat (as a fraction of the beat) reaching FLOOR of
        # the band's typical beat onset.  Returns { band => [...] }.
        def grid_offsets(x, rate, grid, window: WINDOW)
          times = grid.beats.map(&:seconds)
          spans = grid.beat_spans
          return Bands::NAMES.to_h { |b| [b, []] } if times.empty?

          cal = calibration(rate)
          found = Bands::NAMES.to_h { |b| [b, Array.new(times.length)] }
          chunks(times.length, 16).each do |i0, i1|
            w0 = (spans[i0][1] - spans[i0][0]) * window
            w1 = (spans[i1 - 1][1] - spans[i1 - 1][0]) * window
            from = ((times[i0] - w0) * rate).floor
            to = ((times[i1 - 1] + w1) * rate).ceil + 1
            margin = (0.05 * rate).round
            bands = Bands.split(x, rate, from: from, to: to, margin: margin)
            base = from - margin
            Bands::NAMES.each_with_index do |band, bi|
              o = onset_function(bands[bi], band, rate)
              (i0...i1).each do |i|
                half = (spans[i][1] - spans[i][0]) * window
                a = ((times[i] - half) * rate).floor - base
                b = ((times[i] + half) * rate).ceil - base
                a = a.clamp(0, o.length)
                b = b.clamp(a, o.length)
                next if b <= a
                seg = o[a...b]
                k = attack_peak(seg, rate)
                next unless k
                strength = seg.max
                found[band][i] = [(a + k + base) / rate.to_f - times[i] - cal[band], strength]
              end
            end
          end

          typical = found.transform_values { |list|
            strengths = list.compact.map(&:last).sort
            strengths.empty? ? 0 : strengths[(strengths.length * 0.75).floor.clamp(0, strengths.length - 1)]
          }
          # (a band whose onsets stay BAND_FLOOR under the strongest band's
          # holds only leakage)
          loudest = typical.values.max || 0
          found.to_h { |band, list|
            t = typical[band]
            t = 0 if t < loudest * BAND_FLOOR
            [band, list.map { |e| e && t > 0 && e[1] >= FLOOR * t ? e[0] : nil }]
          }
        end

        # The attack in onset function +seg+: the largest peak, or the first
        # peak reaching ATTACK_SHARE of it within ATTACK_SPAN seconds before
        # it (a chord's attack rather than the beating of its tones just
        # after); nil for silence.
        def attack_peak(seg, rate)
          k = seg.max_index
          top = seg[k]
          return nil unless top > 0
          cut = top * ATTACK_SHARE
          from = [k - (ATTACK_SPAN * rate).round, 0].max
          (from...k).find { |i| seg[i] >= cut && (i == 0 || seg[i] > seg[i - 1]) && seg[i] >= seg[i + 1] } || k
        end

        # [first, last + 1) index ranges of +n+ items, +size+ at a time.
        def chunks(n, size)
          (0...n).step(size).map { |i| [i, [i + size, n].min] }
        end

        # Per band, the lag of mono +b+ behind mono +a+ (both at +rate+) in
        # each of +spans+ ([start, end] seconds of +a+, e.g. bars): {
        # band => [[lag samples (Float), correlation, onset lag samples], ...] },
        # nil entries where a band is silent in the span.  Positive lags
        # mean +b+ is late.  Lags are searched within +-+max_lag+ seconds.
        def lags(a, b, rate, spans, max_lag: 0.125)
          m = (max_lag * rate).round
          r = (REFINE * rate).round
          song = song_lags(a, b, rate, m)
          out = Bands::NAMES.to_h { |band| [band, []] }
          spans.each do |s, e|
            from = (s * rate).floor
            to = [(e * rate).ceil, from + 1].max
            margin = m + r + (0.05 * rate).round
            ba = Bands.split(a, rate, from: from, to: to, margin: margin)
            bb = Bands.split(b, rate, from: from, to: to, margin: margin)
            Bands::NAMES.each_with_index do |band, bi|
              out[band] << span_lag(ba[bi], bb[bi], band, rate, margin, to - from, m, r, song[band])
            end
          end
          out
        end

        # Each band's whole-song onset lag in samples (the tiebreak for
        # bars with several equal peaks), from onset functions at 1 kHz.
        def song_lags(a, b, rate, m)
          step = [(rate / 1000.0).round, 1].max
          oa = decimated_onsets(a, rate, step)
          ob = decimated_onsets(b, rate, step)
          Bands::NAMES.to_h { |band|
            c = xcorr(oa[band], ob[band], (m / step.to_f).ceil)
            [band, c.max > 0 ? (c.max_index - (c.length - 1) / 2) * step : 0]
          }
        end

        # Each band's onset function of mono +x+, the largest value of each
        # +step+ samples, computed in chunks (so a long song's bands are
        # never kept whole).  Returns { band => DFloat }.
        def decimated_onsets(x, rate, step)
          chunk = step * 10_000
          margin = (0.05 * rate).round
          parts = Bands::NAMES.to_h { |band| [band, []] }
          0.step(x.length - 1, chunk) do |from|
            to = [from + chunk, x.length].min
            bands = Bands.split(x, rate, from: from, to: to, margin: margin)
            Bands::NAMES.each_with_index do |band, i|
              parts[band] << coarse_onsets(bands[i][margin...(margin + to - from)], band, rate, step)
            end
          end
          parts.transform_values { |list| list.empty? ? Numo::DFloat[0] : Numo::DFloat.hstack(list) }
        end

        # The onset function of band signal +x+ at a +step+ times lower rate
        # (from the mean square of each block of +step+ samples), for
        # finding lags to about a block (#lags then refines them on the
        # waveform).
        def coarse_onsets(x, band, rate, step)
          n = x.length / step
          return Numo::DFloat.zeros(0) if n == 0
          e = x[0...(n * step)]
          blocks = (e * e).reshape(n, step).sum(axis: 1) / step
          w = [(SMOOTH.fetch(band) * rate / step).round, 1].max
          env = Numo::NMath.sqrt(moving_mean(moving_mean(blocks, w), w).clip(0, nil))
          o = Numo::DFloat.zeros(n)
          h = w / 2
          o[h...(n - (w - h))] = env[w..] - env[0...(n - w)] if n > w
          o.clip(0, nil)
        end

        # The largest value of each block of +step+ samples.
        def decimate_max(x, step)
          n = x.length / step
          return x if n == 0 || step == 1
          x[0...(n * step)].reshape(n, step).max(axis: 1)
        end

        # Cross-correlation c[lag] = sum(a[i] * b[i + lag]) for lag in
        # -m..m (2m + 1 values) by FFT (b zero outside its samples).
        def xcorr(a, b, m)
          n = 1
          n *= 2 while n < a.length + b.length + 2 * m
          fa = Numo::Pocketfft.rfft(Bands.pad(a, n))
          fb = Numo::Pocketfft.rfft(Bands.pad(b, n))
          full = Numo::Pocketfft.irfft(fa.conj * fb)
          # lags 0..m at the start, -m..-1 at the end
          Numo::DFloat.hstack([full[(n - m)...n], full[0..m]])
        end

        # The lag of one band in one span (see #lags): +xa+ and +xb+ hold
        # the span with +margin+ samples either side; +len+ is the span's
        # length; +m+ the search range, +r+ the refinement range, +hint+
        # the band's whole-song lag (samples).
        def span_lag(xa, xb, band, rate, margin, len, m, r, hint)
          body = xa[margin...(margin + len)]
          ea = (body * body).sum
          return nil if ea <= 0

          # Onset lag: onset functions at about 1 kHz (each block's peak)
          step = [(rate / 1000.0).round, 1].max
          md = (m / step.to_f).ceil
          oa = coarse_onsets(xa[margin...(margin + len)], band, rate, step)
          ob = coarse_onsets(xb[(margin - md * step)...(margin + len + md * step)], band, rate, step)
          coarse =
            if oa.max > 0 && ob.max > 0
              c = full_window_corr(oa, ob, md)
              best = c.max
              peaks = (1...(c.length - 1)).select { |i| c[i] >= c[i - 1] && c[i] >= c[i + 1] && c[i] >= best * PEAK_TIE }
              peaks = [c.max_index] if peaks.empty?
              (peaks.min_by { |i| ((i - md) * step - hint).abs } - md) * step
            else
              hint
            end
          coarse = coarse.clamp(-m, m)

          # Waveform lag within +-r of it (a dot product per lag)
          c = Numo::DFloat.zeros(2 * r + 1)
          (0..(2 * r)).each { |j| c[j] = body.dot(xb[(margin + coarse - r + j)...(margin + coarse - r + j + len)]) }
          k = c.max_index
          seg = xb[(margin + coarse - r + k)...(margin + coarse - r + k + len)]
          eb = (seg * seg).sum
          corr = eb > 0 ? c[k] / Math.sqrt(ea * eb) : 0.0
          return [coarse.to_f, corr.round(3), coarse] if corr < MIN_WAVE_CORRELATION

          frac = 0.0
          if k > 0 && k < c.length - 1
            den = c[k - 1] - 2 * c[k] + c[k + 1]
            frac = 0.5 * (c[k - 1] - c[k + 1]) / den if den < 0
          end
          [(coarse - r + k + frac).round(3), corr.round(3), coarse]
        end

        # c[j] = sum(a[i] * w[i + j]) for j in 0..2m, where +w+ is +a+'s
        # span with +m+ samples either side (so j = m is lag 0).
        def full_window_corr(a, w, m)
          n = 1
          n *= 2 while n < w.length + a.length
          fa = Numo::Pocketfft.rfft(Bands.pad(a, n))
          fw = Numo::Pocketfft.irfft(fa.conj * Numo::Pocketfft.rfft(Bands.pad(w, n)))
          fw[0..(2 * m)].dup
        end
      end
    end
  end
end
