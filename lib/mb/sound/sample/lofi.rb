module MB
  module Sound
    class Sample
      # Offline character edits for samples (Sample#bits, #lofi, #stretch),
      # baked into new audio so they cost nothing per voice.
      module Lofi
        # Classic samplers' converters, roughly: sample rate (Hz), bits, an
        # input (anti-alias) filter at 45% of the rate, and an output filter
        # (Hz or nil).  Not emulations: the rates and depths of the
        # machines' usual settings, aliasing from a zero-order hold, and
        # their filters as simple lowpasses.
        PRESETS = {
          # Akai S950: 12 bits, variable rate (31.25 kHz here, a jungle
          # favourite for longer breaks), a filtered output
          s950: { rate: 31_250, bits: 12, input_filter: true, filter: 13_000 },
          # E-mu SP-1200: 12 bits at 26.04 kHz, no anti-alias filter on the
          # way in, the gritty unfiltered outputs
          sp1200: { rate: 26_040, bits: 12, input_filter: false, filter: nil },
          # Akai MPC60: 12 bits (stored nonlinearly) at 40 kHz, filtered
          mpc60: { rate: 40_000, bits: 12, input_filter: true, filter: 16_000 },
        }.freeze

        # How voices read each preset's output unless told otherwise
        # (Sample::READ_STYLES): the MPC60, the cleanest converter, reads
        # clean (band-limited, interpolated); the S950 and SP-1200 read
        # drop-sample with no levels, aliasing as hits pitch up like the
        # hardware (maintainer's Bench verdicts, 2026-10-13).
        PRESET_READS = { s950: :drop, sp1200: :drop, mpc60: :clean }.freeze

        module_function

        # +data+ rounded to 2^(bits - 1) steps per unit.
        def bits(data, bits)
          raise ArgumentError, "Bits must be 1 to 24 (got #{bits.inspect})" unless bits.is_a?(Numeric) && bits >= 1 && bits <= 24
          q = 2.0**(bits - 1)
          (Numo::DFloat.cast(data) * q).round / q
        end

        # The settings for +preset+ (a PRESETS name or nil) with +options+
        # (rate:, bits:, input_filter:, filter:) changed.
        def settings(preset = nil, **options)
          base = preset ? PRESETS.fetch(preset.to_sym) { raise ArgumentError, "Unknown lofi preset #{preset.inspect} (#{PRESETS.keys.join(', ')})" } : {}
          bad = options.keys - [:rate, :bits, :input_filter, :filter]
          raise ArgumentError, "Unknown lofi options #{bad.inspect}" unless bad.empty?
          s = { rate: nil, bits: nil, input_filter: true, filter: nil }.merge(base).merge(options)
          raise ArgumentError, 'Give a lofi preset or rate:/bits:' if s[:rate].nil? && s[:bits].nil?
          s
        end

        # +data+ (a 1D NArray at +sample_rate+) through an input filter, a
        # zero-order hold at +rate+, +bits+, and an output +filter+.
        def process(data, sample_rate:, rate: nil, bits: nil, input_filter: true, filter: nil)
          x = Numo::DFloat.cast(data)
          fs = sample_rate.to_f
          if rate && rate < fs
            x = lowpass(x, fs, rate * 0.45) if input_filter
            x = hold(x, fs, rate.to_f)
          end
          x = Lofi.bits(x, bits) if bits
          x = lowpass(x, fs, filter.to_f) if filter && filter < fs / 2
          Numo::SFloat.cast(x)
        end

        # A zero-order hold: each output sample takes the input at the last
        # tick of a +rate+ Hz clock (so a 26 kHz hold aliases like a sampler
        # with no reconstruction filter).
        def hold(x, fs, rate)
          n = x.length
          i = Numo::DFloat.new(n).seq
          ticks = (i * (rate / fs) + 1e-9).floor
          idx = (ticks * (fs / rate)).ceil.clip(0, n - 1)
          x[Numo::Int64.cast(idx)]
        end

        # Two passes of a Butterworth-Q biquad lowpass at +cutoff+ (a 4-pole
        # rolloff).
        def lowpass(x, fs, cutoff)
          2.times do
            f = MB::Sound::Filter::Cookbook.new(:lowpass, fs, cutoff, quality: Math.sqrt(0.5))
            x = Numo::DFloat.cast(f.process(x))
          end
          x
        end

        # Ways Sample#stretch picks its cycles (+fit+): :auto (the default
        # since sampler-3) snaps each cycle to the local period near the
        # asked length (autocorrelation), starts each cycle where the sound
        # best matches what would have followed the last one (the
        # S950-style "cycle fudging"), and cuts at rising zero crossings;
        # :fixed plays cycles of exactly the asked length from where the
        # clock says, cut anywhere (the plain cyclic stretch).
        #
        # :fixed retunes tones whose period doesn't divide the cycle: each
        # harmonic h × f0 becomes partials at h × f0 / ratio + m / cycle,
        # the strongest within 1 / (2 × cycle) of h × f0.  A 55 Hz bass
        # stretched 2x with 30 ms cycles measured partials at 60.8 Hz (+1.8
        # semitones) and 27.5 Hz, 88.3 Hz, 149 Hz between them: a
        # periodicity near 30 Hz, about an octave low (maintainer's Bench
        # note "the fixed version tunes lower"); :auto measured 55.0 Hz.
        FITS = [:auto, :fixed].freeze

        # +fit+ as a FITS name (nil and false mean :fixed, the plain
        # stretch they meant before :auto became the default).
        def fit_name(fit)
          fit = (fit.nil? || fit == false) ? :fixed : fit.to_sym
          raise ArgumentError, "Unknown stretch fit #{fit.inspect} (#{FITS.map(&:inspect).join(', ')})" unless FITS.include?(fit)
          fit
        end

        # How far :auto looks for a matching period or splice, as a
        # fraction of the cycle (so periods up to half a cycle are found).
        FIT_SEARCH = 0.25

        # The correlation a period must reach to set the cycle length (else
        # the asked length plays), and a splice to move from where the
        # clock says.
        FIT_PERIOD_MIN = 0.7
        FIT_SPLICE_MIN = 0.3

        # How far (seconds) :auto moves a cut to reach a rising zero
        # crossing.
        FIT_ZERO_CROSSING = 0.0005

        # Cyclic timestretch (see Sample#stretch): output cycles of about
        # +cycle+ samples, each playing the input from where output time /
        # +ratio+ says and crossfading into the next over +crossfade+
        # samples (#crossfade_gains; 0 cuts, at rising zero crossings with
        # :auto).  +fit+ (see FITS) :auto plans the cycles from +guide+ (the
        # channels' mix, so every channel cuts in the same places; +data+ by
        # default) with Lofi.fit_plan.
        def stretch(data, ratio, cycle, crossfade, fit: :auto, guide: nil, sample_rate: 48000)
          raise ArgumentError, "Stretch ratios are positive (got #{ratio})" unless ratio > 0
          raise ArgumentError, 'The stretch cycle must be at least 16 samples' unless cycle >= 16
          fit = fit_name(fit)

          x = Numo::DFloat.cast(data)
          out_len = (x.length * ratio).round
          plan = fit == :auto ? fit_plan(guide || x, ratio, cycle, sample_rate: sample_rate, crossfade: crossfade) : fixed_plan(x.length, ratio, cycle)
          play_plan(x, plan, out_len, crossfade)
        end

        # [output start, input start, length] of each cycle of the plain
        # cyclic stretch: cycle k at k × +cycle+ plays the input from
        # k × +cycle+ / +ratio+ (the last ones from a cycle before the end,
        # so the output doesn't run out early).
        def fixed_plan(n, ratio, cycle)
          out_len = (n * ratio).round
          plan = []
          k = 0
          while k * cycle < out_len
            o = k * cycle
            src = MB::M.max(0, MB::M.min((o / ratio).round, n - cycle))
            break if src >= n
            plan << [o, src, cycle]
            k += 1
          end
          plan
        end

        # The cycles of the fitted stretch (fit: :auto) of +x+ (a 1D
        # array), as for #fixed_plan: each cycle is a whole number
        # of the sound's local periods (#local_period, followed from cycle
        # to cycle so the count and the period don't jump), the multiple
        # nearest +cycle+, or +cycle+ itself where nothing repeats
        # (FIT_PERIOD_MIN); the next cycle starts where the input best
        # matches what follows the last one's end (FIT_SPLICE_MIN), within
        # FIT_SEARCH cycles of where output time / +ratio+ says, so the
        # output keeps time.  Without a +crossfade+ (hard cuts) each end
        # moves to a rising zero crossing within FIT_ZERO_CROSSING first.
        def fit_plan(x, ratio, cycle, sample_rate: 48000, crossfade: 0)
          x = Numo::DFloat.cast(x)
          n = x.length
          out_len = (n * ratio).round
          radius = MB::M.max(2, (cycle * FIT_SEARCH).round)
          win = MB::M.max(8, cycle / 2)
          zc = crossfade == 0 ? (FIT_ZERO_CROSSING * sample_rate).round : 0
          min_lag = MB::M.max(2, (sample_rate / FIT_MAX_PITCH).round)
          max_lag = MB::M.max(min_lag + 2, (cycle * (1 + FIT_SEARCH)).round)
          pwin = MB::M.max(win, max_lag)
          pad = Numo::DFloat.zeros(n + 3 * cycle + 2 * radius + 2 * pwin + max_lag + 2)
          pad[0...n] = x
          energy = Numo::DFloat.zeros(pad.length + 1)
          energy[1..] = (pad * pad).cumsum

          plan = []
          o = 0
          src = 0
          period = nil
          misses = 0
          while o < out_len && src < n
            # (near the end, where the window would run into the padding:
            # the last period)
            found = src + max_lag + pwin <= n ? local_period(pad, energy, src, min_lag, max_lag, pwin, period) : period
            # (a period lost for a cycle or two is kept: a quiet moment
            # doesn't make the cycle length jump)
            misses = found ? 0 : misses + 1
            period = found || (misses <= FIT_PERIOD_HOLD ? period : nil)
            len = period ? (period * MB::M.max(1, (cycle / period).round)).round : cycle
            if zc > 0
              cut = zero_crossing(pad, src + len, zc, n)
              len = cut - src if cut > src + 15
            end
            plan << [o, src, len]

            o += len
            # (whole cycles at the end: the last starts a cycle before it)
            ideal = MB::M.max(0, MB::M.min((o / ratio).round, n - cycle))
            nxt = ideal
            if src + len < n
              # (at least ± half a period, so a periodic sound always has
              # its matching phase in reach)
              r = period ? MB::M.max(radius, (period * 0.55).ceil) : radius
              m, score = best_match(pad, energy, src + len, ideal - r, MB::M.min(ideal + r, n - cycle), win)
              nxt = m if score >= FIT_SPLICE_MIN
            end
            src = nxt
          end
          plan
        end

        # The highest pitch (Hz) Lofi.fit_plan looks for a period of.
        FIT_MAX_PITCH = 2000

        # How many cycles in a row Lofi.fit_plan keeps the last period
        # when it finds none.
        FIT_PERIOD_HOLD = 2

        # The sound's period (fractional samples) at +src+ in +x+: the
        # shortest lag in +min_lag+..+max_lag+ whose normalized
        # autocorrelation (over +win+ samples) is a local peak within 10%
        # of the best one there, once the correlation has dipped below
        # zero (so a lowpassed sound's high correlation at short lags
        # isn't taken for a period), refined by a parabola through the
        # peak; nil when the best peak is below FIT_PERIOD_MIN.  With
        # +previous+ (the last cycle's period), a peak within 6% of it
        # wins when it's within 10% of the best, so the period follows
        # glides and doesn't jump between multiples.
        def local_period(x, energy, src, min_lag, max_lag, win, previous)
          lo, score = match_scores(x, energy, src, src + 1, src + max_lag + 1, win)
          return nil if score.nil?
          s = score.to_a
          # (s[i] is lag i + 1)
          dip = s.index { |v| v < 0 }
          return nil if dip.nil?
          peaks = ((MB::M.max(dip, min_lag - 1) + 1)...(s.length - 1)).select { |i| s[i] >= s[i - 1] && s[i] > s[i + 1] }
          return nil if peaks.empty?
          best = peaks.map { |i| s[i] }.max
          return nil if best < FIT_PERIOD_MIN

          good = peaks.select { |i| s[i] >= best - 0.1 }
          i = (previous && good.find { |j| ((j + 1) / previous - 1).abs < 0.06 }) || good.first
          a, b, c = s[i - 1], s[i], s[i + 1]
          den = a - 2 * b + c
          frac = den.abs > 1e-12 ? 0.5 * (a - c) / den : 0.0
          i + 1 + MB::M.clamp(frac, -0.5, 0.5)
        end

        # Correlations this close to the best count as ties in #best_match.
        MATCH_TIE = 0.002

        # The position in lo..hi where +win+ samples of +x+ best match the
        # +win+ samples at +ref+ (the highest normalized correlation; the
        # one nearest the middle of the range on ties) and that
        # correlation, from +energy+ (the cumulative sum of x², with a 0
        # first).  [the middle, 0] for silence.
        def best_match(x, energy, ref, lo, hi, win)
          lo = MB::M.max(0, lo)
          hi = MB::M.min(x.length - win, hi)
          mid = (lo + hi) / 2
          lo, score = match_scores(x, energy, ref, lo, hi, win)
          return [MB::M.max(0, mid), 0.0] if score.nil?

          best = score.max
          # (peaks within MATCH_TIE of the best, like a steady tone's every
          # period, and exact ties: the one nearest the middle, where the
          # clock says)
          near = score.ge(best - MATCH_TIE).where.to_a
          last = score.length - 1
          peaks = near.select { |i| (i == 0 || score[i] >= score[i - 1]) && (i == last || score[i] >= score[i + 1]) }
          k = peaks.min_by { |i| ((lo + i) - mid).abs }
          [lo + k, score[k].to_f]
        end

        # [lo, the normalized correlations of the +win+ samples of +x+ at
        # each position lo..hi with those at +ref+] (an FFT correlation;
        # +energy+ as for #best_match), or [lo, nil] for silence or an
        # empty range.
        def match_scores(x, energy, ref, lo, hi, win)
          lo = MB::M.max(0, lo)
          hi = MB::M.min(x.length - win, hi)
          return [lo, nil] if hi < lo || ref + win > x.length

          a = x[ref...(ref + win)]
          ea = energy[ref + win] - energy[ref]
          return [lo, nil] if ea <= 1e-12

          span = hi - lo + 1
          size = 1 << Math.log2(span + 2 * win).ceil
          fa = Numo::DFloat.zeros(size)
          fa[0...win] = a
          fb = Numo::DFloat.zeros(size)
          fb[0...(span + win - 1)] = x[lo...(hi + win)]
          corr = Numo::Pocketfft.irfft(Numo::Pocketfft.rfft(fa).conj * Numo::Pocketfft.rfft(fb))[0...span]
          eb = energy[(lo + win)..(hi + win)] - energy[lo..hi]
          [lo, corr / Numo::NMath.sqrt(eb * ea + 1e-20)]
        end

        # The rising zero crossing (x[t - 1] < 0 <= x[t]) nearest +pos+
        # within +radius+ samples (and inside 1...+n+), or +pos+.
        def zero_crossing(x, pos, radius, n)
          return pos if radius <= 0
          (0..radius).each do |d|
            [pos - d, pos + d].uniq.each do |t|
              next if t < 1 || t >= n
              return t if x[t - 1] < 0 && x[t] >= 0
            end
          end
          pos
        end

        # The output of +plan+ ([output start, input start, length] cycles)
        # over +x+, +out_len+ samples long, each cycle running +crossfade+
        # samples past its length into the next one's start (see
        # #crossfade_gains).
        def play_plan(x, plan, out_len, crossfade)
          n = x.length
          longest = plan.map { |c| c[2] }.max || 0
          out = Numo::DFloat.zeros(out_len + longest + crossfade)
          plan = preroll(plan, n, crossfade) if crossfade > 0
          fade_in = nil
          plan.each_with_index do |(o, src, cycle), k|
            break if o >= out_len
            nxt = plan[k + 1]
            f = 0
            if crossfade > 0 && nxt && nxt[0] < out_len
              f = MB::M.max(0, [crossfade, n - src - cycle, n - nxt[1], nxt[2]].min)
            end
            len = MB::M.min(cycle + f, n - src)
            if len > 0
              seg = x[src...(src + len)].dup
              seg[0...fade_in.length] *= fade_in if fade_in
              if f > 0
                g_out, fade_in = crossfade_gains(x[(src + cycle)...(src + cycle + f)], x[nxt[1]...(nxt[1] + f)])
                seg[cycle...(cycle + f)] *= g_out
              else
                fade_in = nil
              end
              out[o...(o + len)] += seg
            else
              fade_in = nil
            end
          end
          Numo::SFloat.cast(out[0...out_len])
        end

        # +plan+ with each splice moved earlier where the input ends too soon
        # after a cycle to run on for +crossfade+ samples: the next cycle
        # starts that much sooner in the output and the input (so it fades
        # in before its own start), the cycle before ends sooner.
        def preroll(plan, n, crossfade)
          plan = plan.map(&:dup)
          plan.each_cons(2) do |a, b|
            pre = [a[1] + a[2] + crossfade - n, b[1], a[2] / 2].min
            next unless pre > 0
            a[2] -= pre
            b[0] -= pre
            b[1] -= pre
            b[2] += pre
          end
          plan
        end

        # Gains [out, in] for crossfading +tail+ (what would have followed
        # the cut) into +head+ (the next cycle's start), as many as their
        # length: raised-cosine fades divided by sqrt(a² + b² + 2ρab), where
        # ρ is the two segments' normalized correlation (clamped to 0..1),
        # so the expected level stays flat: equal-gain (a + b = 1) when they
        # match, equal-power when they're unrelated (drum hits, noise).
        def crossfade_gains(tail, head)
          f = tail.length
          t = (Numo::DFloat.new(f).seq + 0.5) / f
          b = (1 - Numo::NMath.cos(t * Math::PI)) * 0.5
          a = 1 - b
          den = Math.sqrt((tail * tail).sum * (head * head).sum)
          rho = den > 1e-20 ? MB::M.clamp((tail * head).sum / den, 0.0, 1.0) : 1.0
          norm = Numo::NMath.sqrt(a * a + b * b + a * b * (2 * rho))
          [a / norm, b / norm]
        end
      end
    end
  end
end
