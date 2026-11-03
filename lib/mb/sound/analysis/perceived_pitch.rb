module MB
  module Sound
    module Analysis
      # The pitch a listener would name for a stretch of sound, by
      # subharmonic summation (Hermes 1988): for every candidate f0 on an
      # eighth-semitone grid from MIDI LOW_NOTE to HIGH_NOTE, the sum of
      # the log spectrum's peaks at its first HARMONICS harmonics
      # (weighted 1/sqrt(h)) minus INTER times the peaks halfway between
      # them, so a subharmonic (f0 / 2, whose odd multiples fall between
      # the real harmonics) loses to the real f0.  It follows what a
      # listener calls the pitch of stacked octaves better than a period
      # does (round 2's octave stacks), and reading it over the attack and
      # the body separately shows attacks that sound at another pitch.
      #
      # The best candidate is the middle of the highest-scoring stretch of
      # the grid, its frequency then refined from its harmonics' peaks.
      # The octave neighbors of the best candidate are kept as
      # #candidates with their scores (octave scouting): a close score an
      # octave away means the call is ambiguous, as stacks often are.
      #
      #     pp = Analysis::PerceivedPitch.new(segment)   # a Signal or data
      #     pp.pitch       # => #<MB::Sound::Pitch 220.0 Hz>
      #     pp.candidates  # best, its octaves, and the next peaks, with scores
      class PerceivedPitch
        N_FFT = 8192
        LOW_NOTE = 28.0
        HIGH_NOTE = 95.0
        STEP = 0.125
        HARMONICS = 8
        INTER = 0.7

        # The log spectrum's range (dB under its peak) the scores read.
        RANGE_DB = 50.0

        # A candidate pitch: +midi+ (a Float MIDI note), +pitch+ (a Pitch),
        # +score+ (higher is better; the best has 1.0, others relative),
        # +why+ (:best, :octave_up, :octave_down, :peak).
        Candidate = Data.define(:midi, :pitch, :score, :why) do
          def to_s = "#{Analysis.note_label(pitch.frequency)} #{format('%.2f', score)}#{why == :best ? '' : " (#{why.to_s.tr('_', ' ')})"}"
          def inspect = "#<PerceivedPitch::Candidate #{self}>"
        end

        # The best Candidate's Pitch, or nil for silence.
        attr_reader :pitch

        # Candidates: the best, its octave neighbors, and up to two other
        # local maxima, best first.
        attr_reader :candidates

        # Scores the first N_FFT samples of +sound+ (anything Signal.from
        # takes; a Hann window over its length if shorter).
        def initialize(sound)
          data = sound.is_a?(Signal) ? sound.data : Signal.from(sound).data
          @candidates = score(data).freeze
          @pitch = @candidates.first&.pitch
        end

        # The best candidate's note ("A3 +3 cents"), or nil.
        def note_label = @pitch && Analysis.note_label(@pitch.frequency)

        def to_s
          return 'no pitch' unless @pitch
          rest = @candidates.drop(1).select { |c| c.why != :peak }.map(&:to_s)
          "#{note_label}#{rest.empty? ? '' : " (#{rest.join(', ')})"}"
        end

        def inspect = "#<#{self.class.name.sub('MB::Sound::', '')} #{self}>"

        private

        def score(seg)
          rate = Signal::RATE
          buf = Numo::DFloat.zeros(N_FFT)
          len = [seg.length, N_FFT].min
          return [] if len < 64
          buf[0...len] = seg[0...len] * DSP.hann(len)
          mag = Numo::Pocketfft.rfft(buf).abs
          top = mag.max
          return [] if top <= 0
          lm = ((Numo::NMath.log10(mag / top + 1e-300) * 20 + RANGE_DB) / RANGE_DB).clip(0, 1)
          # The max of each bin and its two neighbors
          wide = lm.dup
          wide[1..-2] = Numo::DFloat.maximum(Numo::DFloat.maximum(lm[0..-3], lm[1..-2]), lm[2..-1])

          grid = Numo::DFloat.new(((HIGH_NOTE - LOW_NOTE) / STEP).round + 1).seq * STEP + LOW_NOTE
          f = 440.0 * 2**((grid - 69) / 12.0)
          total = Numo::DFloat.zeros(grid.length)
          limit = mag.length - 2
          (1..HARMONICS).each do |h|
            b = (f * (h * N_FFT / rate.to_f)).round.cast_to(Numo::Int64)
            bh = (f * ((h - 0.5) * N_FFT / rate.to_f)).round.cast_to(Numo::Int64)
            # (a harmonic past the spectrum ends that candidate's sum, as
            # the study's loop did)
            alive = Numo::Bit.cast(b.lt(limit))
            v = (wide[b.clip(0, limit)] - wide[bh.clip(0, limit)] * INTER) / Math.sqrt(h)
            total += v * alive
            break if alive.count_true == 0
          end

          # The middle of the best plateau (a sine's main lobe scores the
          # same over several grid points)
          bestv = total.max
          top = total.ge(bestv - 1e-9 * bestv.abs).where
          best = top[top.size / 2]
          norm = bestv.abs > 1e-12 ? bestv : 1.0
          cand = ->(i, why) {
            hz = refine(mag, lm, f[i], rate)
            Candidate.new(midi: 69 + 12 * Math.log2(hz / 440.0), pitch: hz.hz, score: total[i] / norm, why: why)
          }
          out = [cand.(best, :best)]
          oct = (12 / STEP).round
          out << cand.(best + oct, :octave_up) if best + oct < grid.length
          out << cand.(best - oct, :octave_down) if best - oct >= 0
          # Other local maxima (two at most), skipping the ones above
          peaks = (1...(grid.length - 1)).select { |i| total[i] >= total[i - 1] && total[i] > total[i + 1] && total[i] > 0 }
          peaks.reject! { |i| [best, best + oct, best - oct].any? { |j| (i - j).abs <= 8 } }
          peaks.sort_by { |i| -total[i] }.first(2).each { |i| out << cand.(i, :peak) }
          out
        end

        # +f+ refined from the harmonics' spectral peaks: each harmonic's
        # peak within ±2 bins of h * f (parabolic interpolation on the log
        # magnitude) gives an estimate peak / h, weighted by its level in
        # the scored range; +f+ itself if no harmonic has a peak there.
        def refine(mag, lm, f, rate)
          bin = rate.to_f / N_FFT
          sum = 0.0
          wsum = 0.0
          (1..HARMONICS).each do |h|
            c = (h * f / bin).round
            break if c + 3 >= mag.length
            lo = [c - 2, 1].max
            k = lo + mag[lo..(c + 2)].max_index
            next if lm[k] <= 0 || k <= 0 || k >= mag.length - 1
            a, b, d = [mag[k - 1], mag[k], mag[k + 1]].map { |v| Math.log(v + 1e-300) }
            den = a - 2 * b + d
            frac = den.abs > 1e-12 ? (0.5 * (a - d) / den).clamp(-0.5, 0.5) : 0.0
            est = (k + frac) * bin / h
            next if (est / f - 1).abs > 0.03
            sum += est * lm[k]
            wsum += lm[k]
          end
          wsum > 0 ? sum / wsum : f
        end
      end
    end
  end
end
