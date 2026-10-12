module MB
  module Sound
    module Structure
      # Global tempo estimation from an onset envelope.
      module Tempo
        module_function

        # Estimates one tempo for the whole onset envelope +onset+ (a Numo
        # array at +fps+ frames per second) from its autocorrelation.
        #
        # Each candidate lag (quarter-frame steps between +min_bpm+ and
        # +max_bpm+) scores the mean autocorrelation at its first
        # +multiples+ multiples (a beat period whose multiples also repeat),
        # weighted by a log-normal prior around +center+ BPM, +octaves+ wide.
        # The best lag is refined with a parabola through its neighbors.
        #
        # Why four multiples: Ellis's TPS2 (lag plus twice the lag) picked 84
        # BPM for the 126 BPM night bus, whose dotted-eighth delays and
        # offbeat hats repeat every 1.5 beats; four multiples found every
        # song in the research spike within 0.02 %.
        #
        # Returns [bpm, curve], the curve an Array of [bpm, score].
        def estimate(onset, fps, min_bpm: 50, max_bpm: 220, center: 120, octaves: 1.0, multiples: 4)
          n = onset.size
          raise ArgumentError, 'Too little audio to estimate a tempo' if n < 4

          size = 1
          size *= 2 while size < 2 * n
          padded = Numo::DFloat.zeros(size)
          padded[0...n] = onset - onset.mean
          spec = Numo::Pocketfft.rfft(padded)
          ac = Numo::Pocketfft.irfft((spec * spec.conj).real)

          max_lag = [(60 * fps / min_bpm).ceil * multiples + 2, n - 1].min
          ac = ac[0..max_lag] / (Numo::DFloat.new(max_lag + 1).seq * -1 + n) # unbiased
          ac = ac / ac[0] if ac[0] > 0
          aca = ac.to_a
          acf = ->(lag) {
            i = lag.floor
            next 0.0 if i + 1 > max_lag
            w = lag - i
            aca[i] * (1 - w) + aca[i + 1] * w
          }

          lag0 = 60 * fps / center
          lo = (60 * fps / max_bpm).floor
          hi = (60 * fps / min_bpm).ceil
          curve = lo.to_f.step(hi, 0.25).map { |lag|
            weight = Math.exp(-0.5 * (Math.log2(lag / lag0) / octaves)**2)
            [lag, weight * (1..multiples).sum { |k| acf.(k * lag) } / multiples]
          }

          k = curve.each_index.max_by { |i| curve[i][1] }
          lag = curve[k][0].to_f
          if k > 0 && k < curve.length - 1
            a, b, c = curve[k - 1][1], curve[k][1], curve[k + 1][1]
            denom = a - 2 * b + c
            lag += 0.25 * 0.5 * (a - c) / denom if denom != 0
          end

          [60 * fps / lag, curve.map { |l, s| [60 * fps / l, s] }]
        end
      end
    end
  end
end
