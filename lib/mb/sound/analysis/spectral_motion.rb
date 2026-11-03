module MB
  module Sound
    module Analysis
      # Moving parts of the spectrum that the band envelopes only hint at:
      # a resonant peak that moves across the note (a filter envelope on a
      # resonant filter, a noise layer through a falling bandpass) and
      # comb teeth (a flanger, a comb filter, a short echo).  Both read
      # 2048-point frames every 10 ms over the body of the sound (frames
      # inside the sound within BODY_DB of the loudest).
      #
      # Resonance: each frame's power spectrum is smoothed over ±1/12
      # octave (and over at least ±1.5 f0 for pitched sounds, so harmonics
      # blend into an envelope), read on a 48-per-octave grid from
      # RESONANCE_LOW to the band, and compared with its own average over
      # ±2/3 octave; the most prominent point at least PROMINENCE dB over
      # its surroundings is the frame's peak.  A track of peaks on at least
      # TRACKED of the body's frames that moves at least half an octave in
      # one direction (|r| >= 0.7 against time) is a sweep; one within a
      # fifth of an octave is a static resonance.
      #
      # Comb: each frame's log spectrum from COMB_LOW to the band, minus
      # its own ±1.5 kHz average, is searched for equally spaced ripple (a
      # cepstrum: the peak quefrency between COMB_DELAYS, a delay whose
      # teeth are 1/delay apart) standing COMB_STRENGTH times over the
      # cepstrum's mean power.  Pitched sounds skip quefrencies near
      # multiples of their period (harmonics are combs too).  The delay
      # track then slides (a sweep), holds (a static comb), or wanders (an
      # LFO: its rate).  Phasers (unequally spaced notches) don't show
      # here; BandEnvelopes' top-band fluctuation and the images do.
      #
      # Both are heuristics for the report and for looking: "a reason to
      # look", checked on synthetic sweeps and combs (specs), not tuned on
      # recordings.
      #
      #     sm = Analysis::SpectralMotion.new(sound)
      #     sm.resonance   # => Resonance from 4.0 kHz to 1.0 kHz (a sweep), or nil
      #     sm.comb        # => Comb delay 1.0 -> 5.0 ms (sliding), or nil
      class SpectralMotion
        N_FFT = 2048
        HOP = 480
        BODY_DB = 30.0
        TRACKED = 0.4

        RESONANCE_LOW = 250.0
        GRID_PER_OCTAVE = 48
        PROMINENCE = 6.0

        COMB_LOW = 500.0
        COMB_DELAYS = 0.0004..0.010
        COMB_STRENGTH = 12.0

        # A resonant peak: +from+ and +to+ (Pitches: the medians of the
        # first and last five peak frames), +start+ and +stop+
        # (Length::Seconds), +prominence+ (median dB over its
        # surroundings), +motion+ (:falling, :rising, or :static), +times+
        # and +hz+ (the track, Numo::DFloat).
        Resonance = Data.define(:from, :to, :start, :stop, :prominence, :motion, :times, :hz) do
          def octaves = Math.log2(to.frequency / from.frequency)
          def to_h = { from_hz: from.frequency, to_hz: to.frequency, start: start.to_f, stop: stop.to_f, prominence_db: prominence, motion: motion }
          def to_s
            when_ = "#{Analysis.seconds_label(start.to_f)}-#{Analysis.seconds_label(stop.to_f)}"
            if motion == :static
              "a resonant peak at #{Analysis.hz_label(from.frequency)} (#{format('%.0f', prominence)} dB over its surroundings, #{when_})"
            else
              "a resonant peak #{motion} from #{Analysis.hz_label(from.frequency)} to #{Analysis.hz_label(to.frequency)} " \
                "(#{format('%.0f', prominence)} dB over its surroundings, #{when_})"
            end
          end
          def inspect = "#<SpectralMotion::Resonance #{self}>"
        end

        # Comb teeth: +delay_from+ and +delay_to+ (Length::Seconds; teeth
        # 1/delay apart), +start+ and +stop+, +motion+ (:sliding_down when
        # the delay grows, :sliding_up, :static, or :wandering), +rate+ (a
        # Pitch for :wandering when the delay swings periodically, else
        # nil), +times+ and +delays+ (the track).
        Comb = Data.define(:delay_from, :delay_to, :start, :stop, :motion, :rate, :times, :delays) do
          def to_h = { delay_from: delay_from.to_f, delay_to: delay_to.to_f, start: start.to_f, stop: stop.to_f, motion: motion, rate_hz: rate&.frequency }
          def to_s
            d = ->(s) { "#{format('%.2f', s.to_f * 1000)} ms" }
            sp = ->(s) { Analysis.hz_label(1 / s.to_f) }
            when_ = "#{Analysis.seconds_label(start.to_f)}-#{Analysis.seconds_label(stop.to_f)}"
            case motion
            when :static
              "comb teeth every #{sp.(delay_from)} (delay #{d.(delay_from)}, #{when_})"
            when :wandering
              "comb teeth wandering, delay #{d.(delay_from)}-#{d.(delay_to)}#{rate ? " at #{Analysis.rate_label(rate.frequency)}" : ''} (#{when_}; a flanger LFO?)"
            else
              "comb teeth #{motion.to_s.tr('_', ' ')}: delay #{d.(delay_from)} -> #{d.(delay_to)} " \
                "(teeth every #{sp.(delay_from)} -> #{sp.(delay_to)}, #{when_}; a flanger sweep?)"
            end
          end
          def inspect = "#<SpectralMotion::Comb #{self}>"
        end

        attr_reader :signal, :band

        # A Resonance, or nil.
        attr_reader :resonance

        # A Comb, or nil.
        attr_reader :comb

        # Measures +sound+ (anything Signal.from takes) up to +band:+ Hz
        # (default the sound's own band).
        def initialize(sound, band: nil)
          @signal = Signal.from(sound)
          @band = (band || @signal.band).to_f
          mag = @signal.stft(N_FFT, HOP)
          @power = mag**2
          total = DSP.db(@power.sum(axis: 1), 1e-20)
          full = [[(@signal.length - N_FFT) / HOP + 1, 0].max, total.length].min
          total = total[0...full]
          @body = full > 0 ? total.ge(total.max - BODY_DB).where : Numo::Int32[]
          @times = (Numo::DFloat.new(mag.shape[0]).seq * HOP + N_FFT / 2) / Signal::RATE.to_f
          pc = @signal.pitch_contour
          @f0 = pc.median && pc.voiced >= 0.5 ? pc.median.frequency : nil
          @resonance = @body.size >= 10 ? find_resonance : nil
          @comb = @body.size >= 10 ? find_comb : nil
          @power = nil
        end

        def lines
          out = []
          out << (@resonance ? @resonance.to_s : 'no moving or standing resonant peak')
          out << (@comb ? @comb.to_s : 'no comb teeth')
          out
        end

        def to_s = lines.join('; ')

        def inspect = "#<#{self.class.name.sub('MB::Sound::', '')} #{self}>"

        private

        def df = Signal::RATE.to_f / N_FFT

        def find_resonance
          p = @power[@body, true]
          bins = p.shape[1]
          k = Numo::DFloat.new(bins).seq
          half = k * (2**(1 / 12.0) - 1)
          half = Numo::DFloat.maximum(half, 1.5 * @f0 / df) if @f0
          half = half.clip(2, nil).ceil.cast_to(Numo::Int64)
          ki = Numo::Int64.new(bins).seq
          lo = (ki - half).clip(0, bins - 1)
          hi = (ki + half).clip(0, bins - 1)
          c = Numo::DFloat.zeros(p.shape[0], bins + 1)
          c[true, 1..-1] = p.cumsum(axis: 1)
          s = (c[true, hi + 1] - c[true, lo]) / (hi - lo + 1).cast_to(Numo::DFloat)

          top = [@band, Signal::RATE * 0.45].min
          return nil if top <= RESONANCE_LOW * 2
          count = (Math.log2(top / RESONANCE_LOW) * GRID_PER_OCTAVE).floor + 1
          freqs = RESONANCE_LOW * 2**(Numo::DFloat.new(count).seq / GRID_PER_OCTAVE)
          gi = (freqs / df).round.cast_to(Numo::Int64)
          l = DSP.db(s[true, gi], 1e-20)
          prom = prominence(l)

          edge = GRID_PER_OCTAVE / 12
          track = []
          prom.shape[0].times do |f|
            row = prom[f, edge...(count - edge)]
            j = row.max_index
            track << [@times[@body[f]], freqs[j + edge], row[j]] if row[j] >= PROMINENCE
          end
          return nil if track.length < 10 || track.length < TRACKED * @body.size

          t = Numo::DFloat.cast(track.map(&:first))
          oct = Numo::DFloat.cast(track.map { |r| Math.log2(r[1]) })
          from = 2**DSP.median(oct.to_a.first(5))
          to = 2**DSP.median(oct.to_a.last(5))
          r = correlation(t, oct)
          span = Math.log2(to / from)
          motion =
            if span.abs >= 0.5 && r.abs >= 0.7 then span < 0 ? :falling : :rising
            elsif oct.stddev <= 0.2 then :static
            end
          return nil unless motion
          from = to = 2**DSP.median(oct.to_a) if motion == :static
          Resonance.new(from: from.hz, to: to.hz, start: t[0].seconds, stop: t[-1].seconds, prominence: DSP.median(track.map(&:last)),
                        motion: motion, times: t.freeze, hz: Numo::DFloat.cast(track.map { |q| q[1] }).freeze)
        end

        def find_comb
          a = (COMB_LOW / df).ceil
          b = ([@band, Signal::RATE * 0.45].min / df).floor
          m = b - a + 1
          return nil if m < 64
          l = DSP.db(@power[@body, a..b], 1e-20)
          l = l - DSP.smooth_rows(l.transpose.dup, (1500.0 / df).round).transpose
          w = DSP.hann(m)
          npad = 1
          npad *= 2 while npad < 4 * m
          # quefrency index j <-> delay j / (npad * df)
          jlo = (COMB_DELAYS.begin * npad * df).ceil
          jhi = [(COMB_DELAYS.end * npad * df).floor, npad / 2].min
          excluded = []
          if @f0
            (1..8).each { |h| excluded << (((h / @f0) * 0.94)..((h / @f0) * 1.06)) }
          end
          track = []
          buf = Numo::DFloat.zeros(npad)
          l.shape[0].times do |f|
            buf.fill(0)
            buf[0...m] = l[f, true] * w
            cep = Numo::Pocketfft.rfft(buf).abs[jlo..jhi]**2
            mean = cep.mean
            next if mean <= 0
            order = cep.sort_index.to_a.reverse
            j = order.find { |i| excluded.none? { |r| r.cover?((i + jlo) / (npad * df)) } }
            next unless j && cep[j] >= COMB_STRENGTH * mean
            # parabolic refinement
            frac = 0.0
            if j > 0 && j < cep.length - 1
              y0, y1, y2 = cep[j - 1], cep[j], cep[j + 1]
              den = y0 - 2 * y1 + y2
              frac = (0.5 * (y0 - y2) / den).clamp(-0.5, 0.5) if den.abs > 1e-20
            end
            track << [@times[@body[f]], (j + jlo + frac) / (npad * df)]
          end
          return nil if track.length < 10 || track.length < TRACKED * @body.size

          t = Numo::DFloat.cast(track.map(&:first))
          oct = Numo::DFloat.cast(track.map { |q| Math.log2(q[1]) })
          from = 2**DSP.median(oct.to_a.first(5))
          to = 2**DSP.median(oct.to_a.last(5))
          r = correlation(t, oct)
          span = Math.log2(to / from)
          rate = nil
          motion =
            if span.abs >= 0.4 && r.abs >= 0.7 then span > 0 ? :sliding_down : :sliding_up
            elsif oct.stddev <= 0.15 then :static
            else :wandering
            end
          case motion
          when :static
            from = to = 2**DSP.median(oct.to_a)
          when :wandering
            s = oct.to_a.sort
            from = 2**s[(s.length * 0.1).floor]
            to = 2**s[(s.length * 0.9).floor]
            spec = DSP.slow_spectrum(oct, Signal::RATE / HOP.to_f)
            hz, _, share = DSP.sine_peak(spec, [0.1, 1.5 / (t[-1] - t[0] + 1e-9)].max, 20.0)
            rate = hz.hz if hz && share >= 0.3
          end
          Comb.new(delay_from: from.seconds, delay_to: to.seconds, start: t[0].seconds, stop: t[-1].seconds, motion: motion, rate: rate,
                   times: t.freeze, delays: Numo::DFloat.cast(track.map(&:last)).freeze)
        end

        # Each grid point's level over the higher of its two sides' mean
        # levels (from 1/6 to 2/3 octave away on each side; the side that
        # runs off the grid doesn't count), so a spectrum's edge or slope
        # isn't a peak.
        def prominence(l)
          g = GRID_PER_OCTAVE
          near = g / 6
          far = (g * 2 / 3.0).round
          count = l.shape[1]
          c = Numo::DFloat.zeros(l.shape[0], count + 1)
          c[true, 1..-1] = l.cumsum(axis: 1)
          i = Numo::Int64.new(count).seq
          side = ->(a, b) {
            a = a.clip(0, count)
            b = b.clip(0, count)
            n = (b - a).cast_to(Numo::DFloat)
            mean = (c[true, b] - c[true, a]) / n.clip(1, nil)
            mean[true, n.lt(far - near).where] = -Float::INFINITY if n.lt(far - near).count_true > 0
            mean
          }
          left = side.(i - far, i - near + 1)
          right = side.(i + near, i + far + 1)
          l - Numo::DFloat.maximum(left, right)
        end

        def correlation(a, b)
          da = a - a.mean
          db = b - b.mean
          den = Math.sqrt((da**2).sum * (db**2).sum)
          den > 0 ? (da * db).sum / den : 0.0
        end
      end
    end
  end
end
