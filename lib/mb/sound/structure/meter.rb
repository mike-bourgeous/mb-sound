module MB
  module Sound
    module Structure
      # Downbeats and bar lengths from beats: a Viterbi over the position
      # in the bar, allowing short bars (a 2/4 gap bar, a dropped beat).
      module Meter
        module_function

        # Downbeat likelihood for each beat (beat i spans its time to the
        # next beat's; the last spans one median interval), in standard
        # deviations: the change in timbre (MFCC 1..13) and harmony (chroma
        # cosine distance) from the previous beat, energy rises, and half the
        # low band's onset at the beat (kicks, bass notes).
        #
        # +frames+ is a Frames, +beat_frames+ the beats' frame positions.
        def observations(frames, beat_frames)
          n = beat_frames.length
          return Numo::DFloat.zeros(n) if n < 2

          period = beat_frames.each_cons(2).map { |a, b| b - a }.sort[(n - 1) / 2]
          edges = beat_frames + [beat_frames.last + period]
          spans = edges.each_cons(2).map { |a, b|
            lo = a.round.clamp(0, frames.count - 1)
            hi = b.round.clamp(lo + 1, frames.count)
            lo...hi
          }

          mean_rows = ->(m) { Numo::DFloat.cast(spans.map { |r| m[r, true].mean(axis: 0).to_a }) }
          mf = mean_rows.(frames.mfcc)[true, 1..13]
          ch = mean_rows.(frames.chroma)
          energy = spans.map { |r| frames.energy[r].mean }
          low = frames.band_flux[0]
          low_onset = Numo::DFloat.cast(spans.map { |r| low[r.begin...[r.begin + 3, r.end].min].max })

          dt = Numo::DFloat.zeros(n)
          dc = Numo::DFloat.zeros(n)
          de = Numo::DFloat.zeros(n)
          (1...n).each do |i|
            dt[i] = Math.sqrt(((mf[i, true] - mf[i - 1, true])**2).sum)
            a = ch[i, true]
            b = ch[i - 1, true]
            dc[i] = 1 - (a * b).sum / (Math.sqrt((a * a).sum * (b * b).sum) + 1e-12)
            de[i] = [energy[i] - energy[i - 1], 0].max
          end

          zscore(dt) + zscore(dc) + zscore(de) + 0.5 * zscore(low_onset)
        end

        def zscore(x)
          sd = x.stddev
          sd > 0 ? (x - x.mean) / sd : x * 0
        end

        # Viterbi over the position in the bar (0 is the downbeat): the
        # position advances by one each beat, wrapping after +beats_per_bar+
        # beats; a bar may also end early after any of +short_bars+ beats,
        # at a cost of +penalty+ (in the observations' z units).  A penalty
        # of 15 found the night bus's 2/4 gap bar; 6 also accepted a false
        # 3-beat bar under its breakdown's one-beat highpass sweep.
        #
        # Returns the indices of the downbeats in +obs+ (beats before the
        # first one are a pickup).
        def downbeats(obs, beats_per_bar: 4, short_bars: [2, 3], penalty: 15.0)
          n = obs.size
          return [] if n == 0

          o = obs.to_a
          s = beats_per_bar
          short = short_bars.select { |b| b < s }
          neg = -Float::INFINITY
          score = Array.new(s) { |p| p == 0 ? o[0] : 0.0 }
          backs = []
          (1...n).each do |i|
            ns = Array.new(s, neg)
            bk = Array.new(s, 0)
            s.times do |p|
              q = (p + 1) % s
              if score[p] > ns[q]
                ns[q] = score[p]
                bk[q] = p
              end
              if short.include?(p + 1) && score[p] - penalty > ns[0]
                ns[0] = score[p] - penalty
                bk[0] = p
              end
            end
            ns[0] += o[i]
            backs << bk
            score = ns
          end

          p = score.each_index.max_by { |k| score[k] }
          path = [p]
          backs.reverse_each { |bk| p = bk[p]; path << p }
          path.reverse!
          path.each_index.select { |i| path[i] == 0 }
        end
      end
    end
  end
end
