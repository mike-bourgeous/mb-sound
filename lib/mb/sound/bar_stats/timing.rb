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
      # cross-correlation of their onset functions within +-max_lag gives
      # candidate lags (peaks within PEAK_TIE of the best, at most
      # MAX_CANDIDATES, nearest the band's whole-song lag first); each is
      # refined on the band waveforms within +-REFINE with a parabola
      # through the peak (exactly N for a copy delayed N samples), and the
      # best waveform correlation wins unless a candidate nearer the
      # whole-song lag comes within WAVE_TIE of it (a periodic pattern, a
      # stutter fill, correlates about as well a repeat away).  Copies whose waveforms differ but
      # whose hits line up (an MP3's top band against a render's) keep the
      # onset lag when the onsets correlate (Lag#reliable?).  Lag#on_time
      # says how much of the band still lines up at 0 beside a late part,
      # which tells a late bus filling every band from a file offset.
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

        # A waveform correlation under this keeps the onset lag (to about a
        # millisecond) instead of the waveform's.
        MIN_WAVE_CORRELATION = 0.3

        # A lag whose waveform correlation is under MIN_WAVE_CORRELATION
        # still counts when its onset correlation reaches this (lossy or
        # re-rendered copies whose waveforms differ but whose hits line
        # up: an MP3's top band against a render's).
        MIN_ONSET_CORRELATION = 0.25

        # Lags farther than this (seconds) from 0 also read how much of the
        # band lines up at 0 (Lag#on_time).
        ON_TIME_GAP = 0.002

        # Lags (seconds, either sign) whose waveform correlation says what
        # an unrelated lag gives by chance (#on_time).
        ON_TIME_PROBES = [0.003, 0.005, 0.007, 0.011].freeze

        # A waveform correlation at or over this is an exact copy: its lag
        # is the whole sample.
        EXACT_CORRELATION = 0.99999

        # Spans shorter than this (seconds) get no lag.
        MIN_SPAN = 0.05

        # Onset-correlation peaks refined on the waveform per span.
        MAX_CANDIDATES = 4

        # Waveform correlations within this of the best are ties, won by
        # the candidate nearest the band's whole-song lag (omnibus19: a
        # kick stem's stutter fill, 16 hits of a 64th at 140 BPM, read
        # +107 ms, four hits away: its hits sat a rounding apart in the
        # conversion, so lag 0 correlated 0.74 and a repeat 0.77).  Kept
        # small: a chord's partials repeat too (66 against 81 ms, where the
        # best waveform is right and the song lag isn't; see bar_stats.md).
        WAVE_TIE = 0.05

        # One band's lag in one span: +samples+ (B behind A; Float), +wave+
        # (the waveform correlation there), +onset+ (the onset functions'
        # correlation), and +on_time+ (the waveform correlation at lag 0
        # when that is a peak of its own: content lined up beside a late
        # part; 0 otherwise or for lags near 0).
        Lag = Data.define(:samples, :wave, :onset, :on_time) do
          # True if the waveform or the onsets agree well enough to trust.
          def reliable? = wave >= MIN_WAVE_CORRELATION || onset >= MIN_ONSET_CORRELATION

          # :wave (refined on the waveform) or :onset (onset lag only).
          def by = wave >= MIN_WAVE_CORRELATION ? :wave : :onset

          # The lag in milliseconds at +rate+.
          def ms(rate = RATE) = (samples * 1000.0 / rate).round(3)
        end

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
            from = frame_floor(times[i0] - w0, rate)
            to = frame_ceil(times[i1 - 1] + w1, rate) + 1
            margin = (0.05 * rate).round
            bands = Bands.split(x, rate, from: from, to: to, margin: margin)
            base = from - margin
            Bands::NAMES.each_with_index do |band, bi|
              o = onset_function(bands[bi], band, rate)
              (i0...i1).each do |i|
                half = (spans[i][1] - spans[i][0]) * window
                a = frame_floor(times[i] - half, rate) - base
                b = frame_ceil(times[i] + half, rate) - base
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

        # The sample at or before (#frame_floor) or at or after
        # (#frame_ceil) +seconds+ (Float seconds of an analysis window, not
        # a render's frame count).
        def frame_floor(seconds, rate) = (seconds * rate).floor
        def frame_ceil(seconds, rate) = (seconds * rate).ceil

        # [first, last + 1) index ranges of +n+ items, +size+ at a time.
        def chunks(n, size)
          (0...n).step(size).map { |i| [i, [i + size, n].min] }
        end

        # Per band, the lag of mono +b+ behind mono +a+ (both at +rate+) in
        # each of +spans+ ([start, end] seconds of +a+, e.g. bars): { band
        # => [Lag, ...] }, nil entries where a band is silent in the span.
        # Positive lags mean +b+ is late.  Lags are searched within
        # +-+max_lag+ seconds.
        def lags(a, b, rate, spans, max_lag: 0.125)
          m = (max_lag * rate).round
          r = (REFINE * rate).round
          song = song_lags(a, b, rate, m)
          out = Bands::NAMES.to_h { |band| [band, []] }
          spans.each do |s, e|
            from = frame_floor(s, rate)
            to = [frame_ceil(e, rate), from + 1].max
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
          # (spans shorter than a few onset blocks have no lag to find)
          step = [(rate / 1000.0).round, 1].max
          return nil if len < MIN_SPAN * rate || len < 4 * step
          body = xa[margin...(margin + len)]
          ea = (body * body).sum
          return nil if ea <= 0

          # Onset lag candidates: onset functions at about 1 kHz (block
          # mean squares), peaks within PEAK_TIE of the best (a chord's
          # beating or a 16th-note pattern gives several)
          md = (m / step.to_f).ceil
          oa = coarse_onsets(xa[margin...(margin + len)], band, rate, step)
          ob = coarse_onsets(xb[(margin - md * step)...(margin + len + md * step)], band, rate, step)
          candidates = [[hint.clamp(-m, m), 0.0]]
          if oa.size > 0 && ob.size > 0 && oa.max > 0 && ob.max > 0
            # (normalized by each window's energy, so louder hits next to
            # the span can't outweigh the span itself: a recording compared
            # with itself peaks at 0)
            raw = full_window_corr(oa, ob, md)
            cs = Numo::DFloat.zeros(ob.length + 1)
            cs[1..] = (ob * ob).cumsum
            idx = Numo::Int64.new(raw.length).seq
            energy = (cs[(idx + oa.length).clip(0, ob.length)] - cs[idx.clip(0, ob.length)]).clip(0, nil)
            ea_o = (oa * oa).sum
            c = raw / Numo::NMath.sqrt(energy * ea_o + 1e-300)
            best = c.max
            peaks = (1...(c.length - 1)).select { |i| c[i] >= c[i - 1] && c[i] >= c[i + 1] && c[i] >= best * PEAK_TIE }
            peaks = [c.max_index] if peaks.empty?
            peaks = peaks.max_by(MAX_CANDIDATES) { |i| c[i] }.sort_by { |i| ((i - md) * step - hint).abs }
            candidates = peaks.map { |i| [((i - md) * step).clamp(-m, m), c[i]] }
            # (the band's whole-song lag is always tried too)
            candidates << [hint.clamp(-m, m), 0.0] unless candidates.any? { |l, _| (l - hint).abs <= step }
          end

          # Each candidate refined on the waveform within +-r (a dot product
          # per lag); the best waveform correlation wins, else the first
          # candidate (nearest the whole-song lag) keeps its onset lag
          tried = candidates.map { |coarse, onset|
            wave = Numo::DFloat.zeros(2 * r + 1)
            (0..(2 * r)).each { |j| wave[j] = body.dot(xb[(margin + coarse - r + j)...(margin + coarse - r + j + len)]) }
            k = wave.max_index
            [coarse, onset, wave, k, window_corr(body, ea, xb, margin + coarse - r + k, wave[k])]
          }
          pick = tried.max_by { |t| t[4] }
          pick = tried.first if pick[4] < MIN_WAVE_CORRELATION
          # (candidates are nearest the whole-song lag first)
          pick = tried.find { |t| t[4] >= pick[4] - WAVE_TIE } if pick[4] >= MIN_WAVE_CORRELATION
          coarse, onset, wave, k, corr = pick
          lag =
            if corr < MIN_WAVE_CORRELATION
              coarse.to_f
            else
              frac = 0.0
              # (an exact copy correlates 1 on a whole sample: no parabola,
              # whose sides the samples next to the span tilt)
              if k > 0 && k < wave.length - 1 && corr < EXACT_CORRELATION
                den = wave[k - 1] - 2 * wave[k] + wave[k + 1]
                frac = 0.5 * (wave[k - 1] - wave[k + 1]) / den if den < 0
              end
              (coarse - r + k + frac).round(3)
            end

          Lag.new(samples: lag, wave: corr.round(3), onset: onset.round(3), on_time: on_time(body, ea, xb, margin, lag, rate).round(3))
        end

        # How much of a band lines up with no lag at all beside a part at
        # +lag+ samples (content on time beside a late part): the waveform
        # correlation within 2 samples of 0 less twice its typical size at
        # ON_TIME_PROBES (what any lag gives by chance), at least 0; 0 for
        # lags within ON_TIME_GAP of 0.
        def on_time(body, ea, xb, margin, lag, rate)
          return 0.0 if lag.abs <= ON_TIME_GAP * rate
          len = body.length
          at = ->(j) { window_corr(body, ea, xb, margin + j, body.dot(xb[(margin + j)...(margin + j + len)])) }
          zero = (-2..2).map { |j| at.(j) }.max
          probes = ON_TIME_PROBES.flat_map { |t| [(t * rate).round, -(t * rate).round] }.reject { |j| (j - lag).abs < 0.002 * rate }
          chance = Analysis::DSP.median(probes.map { |j| at.(j).abs }) || 0.0
          [zero - 2 * chance, 0.0].max
        end

        # The normalized correlation +dot+ of +body+ (energy +ea+) with
        # +xb+'s samples from +start+.
        def window_corr(body, ea, xb, start, dot)
          seg = xb[start...(start + body.length)]
          eb = (seg * seg).sum
          eb > 0 ? dot / Math.sqrt(ea * eb) : 0.0
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
