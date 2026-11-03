module MB
  module Sound
    module Analysis
      # The fundamental frequency over time: YIN (de Cheveigné and Kawahara
      # 2002: the cumulative mean normalized difference, first dip under
      # THRESHOLD, parabolic refinement) over WINDOW-sample windows every
      # HOP samples (10 ms), the difference function computed by FFT.
      # Frames whose aperiodicity (the dip's depth, 0 for a perfect period)
      # is under VOICED count as pitched.
      #
      # Round 3 read vibrato and pitch dips from these contours where the
      # maintainer's notes guessed rates by ear (his directions were right,
      # his rates 2-2.5x low: "maybe 2 Hz" measured ~5 Hz).  Pitch
      # modulation did not rank his Bench picks better than chance, so it
      # is a reading, not a Comparison term.
      #
      #     pc = Analysis::PitchContour.new(sound)
      #     pc.median        # => #<MB::Sound::Pitch 220.3 Hz>
      #     pc.cents         # cents around the median every 10 ms (NaN unvoiced)
      #     pc.vibrato       # => Vibrato rate 5.5.hz, depth 18.cents (or nil)
      #     pc.sweep         # => Sweep from 250 Hz to 61 Hz (a kick), or nil
      class PitchContour
        HOP = 480
        WINDOW = 1920
        LOW = 40.0
        HIGH = 1500.0
        THRESHOLD = 0.15
        VOICED = 0.3

        # Frames below this level (mean square) are unvoiced without
        # searching.
        SILENCE = 1e-8

        # Vibrato: the contour's strongest rate between VIBRATO_RATES (at
        # least 1.5 cycles inside the voiced span; refined by least-squares
        # sinusoid fits, its depth corrected for the window's averaging),
        # kept if it swings at least MIN_VIBRATO cents and holds MIN_SHARE
        # of the contour's fluctuation in that range.
        VIBRATO_RATES = 0.5..20.0
        MIN_VIBRATO = 3.0
        MIN_SHARE = 0.3

        # A sweep: the first and last voiced tenths differ by at least
        # MIN_SWEEP cents.
        MIN_SWEEP = 100.0

        # A periodic pitch swing: +rate+ a Pitch (`rate.lfo` plays it),
        # +depth+ an Interval (±cents, peak), +share+ of the contour's
        # fluctuation at that rate (0..1), +rate_error+ (Hz, about two
        # standard errors).
        Vibrato = Data.define(:rate, :depth, :share, :rate_error) do
          def to_h = { rate_hz: rate.frequency, rate_error_hz: rate_error, depth_cents: depth.to_cents.to_f, share: share }
          def to_s = "vibrato #{Analysis.rate_label(rate.frequency)} (rate ±#{Analysis.rate_label(rate_error).sub(' Hz', '')}), ±#{depth.to_cents.round} cents"
          def inspect = "#<PitchContour::Vibrato #{self}, #{(share * 100).round}% of the fluctuation>"
        end

        # A pitch that moves on (a kick's drop, a glide): from +from+ to +to+
        # (Pitches, the medians of the first and last voiced tenths) between
        # +start+ and +stop+ (Length::Seconds).
        Sweep = Data.define(:from, :to, :start, :stop) do
          def cents = 1200 * Math.log2(to.frequency / from.frequency)
          def to_h = { from_hz: from.frequency, to_hz: to.frequency, start: start.to_f, stop: stop.to_f, cents: cents }
          def to_s
            "pitch #{cents < 0 ? 'falls' : 'rises'} from #{Analysis.hz_label(from.frequency)} to #{Analysis.hz_label(to.frequency)} " \
              "(#{Analysis.seconds_label(start.to_f)}-#{Analysis.seconds_label(stop.to_f)})"
          end
          def inspect = "#<PitchContour::Sweep #{self}>"
        end

        # The Signal measured.
        attr_reader :signal

        # Frame times (seconds, window centers), f0 in Hz (NaN where
        # unvoiced), and each frame's aperiodicity (0..1; 1 for silence).
        attr_reader :times, :hz, :aperiodicity

        # The share of frames that are voiced (0..1).
        attr_reader :voiced

        # The median voiced f0 (a Pitch), or nil if no frame is voiced.
        attr_reader :median

        # Cents around #median per frame, folded into ±600 (YIN's octave
        # jumps), NaN where unvoiced.
        attr_reader :cents

        # A Vibrato, or nil.
        attr_reader :vibrato

        # A Sweep, or nil.
        attr_reader :sweep

        # Tracks +sound+ (anything Signal.from takes).  Prefer
        # Signal#pitch_contour, which keeps the result.
        def initialize(sound)
          @signal = Signal.from(sound)
          track = yin(@signal.data)
          @times = Numo::DFloat.cast(track.each_index.map { |i| (i * HOP + WINDOW / 2.0) / Signal::RATE }).freeze
          @aperiodicity = Numo::DFloat.cast(track.map(&:last)).freeze
          @hz = Numo::DFloat.cast(track.map { |f, ap| f && ap < VOICED ? f : Float::NAN }).freeze
          ok = track.each_index.select { |i| !@hz[i].nan? }
          @voiced = track.empty? ? 0.0 : ok.length / track.length.to_f
          med = DSP.median(ok.map { |i| @hz[i] })
          @median = med&.hz
          @cents = Numo::DFloat.cast(track.each_index.map { |i|
            next Float::NAN if @hz[i].nan?
            c = 1200 * Math.log2(@hz[i] / med)
            c -= 1200 while c > 600
            c += 1200 while c < -600
            c
          }).freeze
          @sweep = find_sweep(ok)
          @vibrato = @sweep ? nil : find_vibrato(ok)
        end

        # A Note-name reading of the median ("A3 +3 cents"), or nil.
        def note_label
          @median && Analysis.note_label(@median.frequency)
        end

        def lines
          return ['no pitch (no voiced frames)'] unless @median
          out = ["pitch #{note_label} (#{Analysis.hz_label(@median.frequency)}), voiced #{(@voiced * 100).round}%"]
          out << @sweep.to_s if @sweep
          out << (@vibrato ? @vibrato.to_s : 'no vibrato') unless @sweep
          out
        end

        def to_s = lines.join(', ')

        def inspect = "#<#{self.class.name.sub('MB::Sound::', '')} #{@times.length} frames: #{self}>"

        private

        # [[hz or nil, aperiodicity]] per frame.
        def yin(x)
          rate = Signal::RATE
          w = WINDOW
          tmax = (rate / LOW).ceil
          tmin = (rate / HIGH).floor
          seg_n = w + tmax + 1
          nfft = 1
          nfft *= 2 while nfft < seg_n + w
          ts = Numo::DFloat.new(tmax).seq + 1
          out = []
          i = 0
          while i + seg_n <= x.length
            seg = x[i...(i + seg_n)]
            if (seg**2).mean < SILENCE
              out << [nil, 1.0]
              i += HOP
              next
            end
            a = Numo::DFloat.zeros(nfft)
            a[0...w] = seg[0...w]
            b = Numo::DFloat.zeros(nfft)
            b[0...seg_n] = seg
            corr = Numo::Pocketfft.irfft(Numo::Pocketfft.rfft(b) * Numo::Pocketfft.rfft(a).conj)[0..tmax]
            sq = Numo::DFloat.zeros(seg_n + 1)
            sq[1..-1] = (seg**2).cumsum
            et = sq[w...(w + tmax + 1)] - sq[0...(tmax + 1)]
            d = et + sq[w] - corr * 2
            d[0] = 0
            cs = d.cumsum
            cm = Numo::DFloat.ones(tmax + 1)
            cm[1..-1] = d[1..-1] * ts / (cs[1..-1] + 1e-20)

            # The first local minimum under THRESHOLD from tmin, else the
            # global minimum; then down to its local minimum
            mid = cm[tmin...tmax]
            dips = (mid.lt(THRESHOLD) & mid.le(cm[(tmin - 1)...(tmax - 1)]) & mid.le(cm[(tmin + 1)...(tmax + 1)])).where
            t = dips.size > 0 ? tmin + dips[0] : tmin + mid.min_index
            t += 1 while t + 1 < tmax && cm[t + 1] < cm[t]
            y0, y1, y2 = cm[t - 1], cm[t], cm[t + 1]
            den = y0 - 2 * y1 + y2
            frac = den.abs > 1e-12 ? (0.5 * (y0 - y2) / den).clamp(-1.0, 1.0) : 0.0
            out << [rate / (t + frac), y1.clamp(0.0, 1.0)]
            i += HOP
          end
          out
        end

        def find_sweep(ok)
          return nil if ok.length < 10
          tenth = [ok.length / 10, 2].max
          first = ok.first(tenth)
          last = ok.last(tenth)
          a = DSP.median(first.map { |i| @hz[i] })
          b = DSP.median(last.map { |i| @hz[i] })
          return nil if (1200 * Math.log2(b / a)).abs < MIN_SWEEP
          Sweep.new(from: a.hz, to: b.hz, start: @times[ok.first].seconds, stop: @times[ok.last].seconds)
        end

        def find_vibrato(ok)
          return nil if ok.length < 16
          span = ok.first..ok.last
          c = @cents[span].to_a
          # Gaps (unvoiced frames inside the span) are filled linearly
          known = c.each_index.reject { |i| c[i].nan? }
          c = c.each_index.map { |i|
            next c[i] unless c[i].nan?
            l = known.select { |k| k < i }.last
            r = known.find { |k| k > i }
            l && r ? c[l] + (c[r] - c[l]) * (i - l) / (r - l).to_f : c[l || r]
          }
          frame_rate = Signal::RATE / HOP.to_f
          dur = c.length / frame_rate
          lo = [VIBRATO_RATES.begin, 1.5 / dur].max
          return nil if lo >= VIBRATO_RATES.end
          spec = DSP.slow_spectrum(Numo::DFloat.cast(c), frame_rate)
          rate, _, share = DSP.sine_peak(spec, lo, VIBRATO_RATES.end)
          return nil unless rate && share >= MIN_SHARE
          rate, depth, err = DSP.sine_fit(Numo::DFloat.cast(c), frame_rate, rate)
          # Each frame's period averages the pitch over the window, which
          # shrinks a swing at +rate+ like a boxcar does (6 Hz: by 9%)
          x = Math::PI * rate * WINDOW / Signal::RATE
          depth /= Math.sin(x) / x if x > 1e-6 && x < 2.5
          return nil unless depth >= MIN_VIBRATO
          Vibrato.new(rate: rate.hz, depth: depth.round.cents, share: share, rate_error: err)
        end
      end
    end
  end
end
