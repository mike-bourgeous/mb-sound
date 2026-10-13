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
        # +ratio+ says, overlapping the next by +crossfade+ samples with
        # linear fades.  +fit+ (see FITS) :auto plans the cycles from
        # +guide+ (the channels' mix, so every channel cuts in the same
        # places; +data+ by default) with Lofi.fit_plan.
        def stretch(data, ratio, cycle, crossfade, fit: :auto, guide: nil, sample_rate: 48000)
          raise ArgumentError, "Stretch ratios are positive (got #{ratio})" unless ratio > 0
          raise ArgumentError, 'The stretch cycle must be at least 16 samples' unless cycle >= 16
          fit = fit_name(fit)

          x = Numo::DFloat.cast(data)
          out_len = (x.length * ratio).round
          plan = fit == :auto ? fit_plan(guide || x, ratio, cycle, sample_rate: sample_rate) : fixed_plan(x.length, ratio, cycle)
          play_plan(x, plan, out_len, crossfade)
        end

        # [output start, input start, length] of each cycle of the plain
        # cyclic stretch: cycle k at k × +cycle+ plays the input from
        # k × +cycle+ / +ratio+.
        def fixed_plan(n, ratio, cycle)
          out_len = (n * ratio).round
          plan = []
          k = 0
          while k * cycle < out_len
            o = k * cycle
            src = (o / ratio).round
            break if src >= n
            plan << [o, src, cycle]
            k += 1
          end
          plan
        end

        # The cycles of the fitted stretch (fit: :auto) of +x+ (a 1D
        # array), as for #fixed_plan: each cycle's length is the multiple of
        # the local period nearest +cycle+ (when the sound repeats closely
        # enough near it: FIT_PERIOD_MIN), its end moved to a rising zero
        # crossing nearby; the next cycle starts where the input best
        # matches what follows that end (FIT_SPLICE_MIN), within
        # FIT_SEARCH cycles of where output time / +ratio+ says, then at
        # the nearest rising zero crossing.  The output keeps time: each
        # start is searched around the clock's position for the output
        # written so far.
        def fit_plan(x, ratio, cycle, sample_rate: 48000)
          x = Numo::DFloat.cast(x)
          n = x.length
          out_len = (n * ratio).round
          radius = MB::M.max(2, (cycle * FIT_SEARCH).round)
          win = MB::M.max(8, cycle / 2)
          zc = (FIT_ZERO_CROSSING * sample_rate).round
          pad = Numo::DFloat.zeros(n + cycle + 2 * radius + win + 2)
          pad[0...n] = x
          energy = Numo::DFloat.zeros(pad.length + 1)
          energy[1..] = (pad * pad).cumsum

          plan = []
          o = 0
          src = 0
          while o < out_len && src < n
            # The cycle: a whole number of periods near the asked length
            len = cycle
            lag, score = best_match(pad, energy, src, src + cycle - radius, src + cycle + radius, win)
            len = lag - src if score >= FIT_PERIOD_MIN
            cut = zero_crossing(pad, src + len, zc, n)
            len = cut - src if cut > src + 15
            plan << [o, src, len]

            o += len
            # (whole cycles at the end: the last starts a cycle before it)
            ideal = MB::M.max(0, MB::M.min((o / ratio).round, n - cycle))
            nxt = ideal
            if src + len < n
              m, score = best_match(pad, energy, src + len, ideal - radius, MB::M.min(ideal + radius, n - cycle), win)
              nxt = m if score >= FIT_SPLICE_MIN
            end
            src = zero_crossing(pad, nxt, zc, n)
          end
          plan
        end

        # The position in lo..hi where +win+ samples of +x+ best match the
        # +win+ samples at +ref+ (the highest normalized correlation; the
        # one nearest the middle of the range on ties) and that
        # correlation, from +energy+ (the cumulative sum of x², with a 0
        # first).  [the middle, 0] for silence.
        def best_match(x, energy, ref, lo, hi, win)
          lo = MB::M.max(0, lo)
          hi = MB::M.min(x.length - win, hi)
          mid = (lo + hi) / 2
          return [MB::M.max(0, mid), 0.0] if hi < lo || ref + win > x.length

          a = x[ref...(ref + win)]
          ea = energy[ref + win] - energy[ref]
          return [mid, 0.0] if ea <= 1e-12

          span = hi - lo + 1
          size = 1 << Math.log2(span + 2 * win).ceil
          fa = Numo::DFloat.zeros(size)
          fa[0...win] = a
          fb = Numo::DFloat.zeros(size)
          fb[0...(span + win - 1)] = x[lo...(hi + win)]
          corr = Numo::Pocketfft.irfft(Numo::Pocketfft.rfft(fa).conj * Numo::Pocketfft.rfft(fb))[0...span]
          eb = energy[(lo + win)..(hi + win)] - energy[lo..hi]
          score = corr / Numo::NMath.sqrt(eb * ea + 1e-20)
          best = score.max
          # (ties and near-ties within 1e-9: the candidate nearest the middle)
          near = (score.ge(best - 1e-9)).where
          k = near.to_a.min_by { |i| ((lo + i) - mid).abs }
          [lo + k, score[k].to_f]
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
        # samples past its length with linear fades (in after the first).
        def play_plan(x, plan, out_len, crossfade)
          n = x.length
          longest = plan.map { |c| c[2] }.max || 0
          out = Numo::DFloat.zeros(out_len + longest + crossfade)
          plan.each_with_index do |(o, src, cycle), k|
            break if o >= out_len
            len = MB::M.min(cycle + crossfade, n - src)
            next if len <= 0
            seg = x[src...(src + len)].dup
            if crossfade > 0
              f = MB::M.min(crossfade, len)
              seg[0...f] *= Numo::DFloat.linspace(0, 1, f + 1)[1..] if k > 0
              seg[-f..] *= Numo::DFloat.linspace(1, 0, f + 1)[0...-1] if len > cycle
            end
            out[o...(o + len)] += seg
          end
          Numo::SFloat.cast(out[0...out_len])
        end
      end
    end
  end
end
