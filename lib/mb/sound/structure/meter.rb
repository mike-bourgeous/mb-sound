module MB
  module Sound
    module Structure
      # Downbeats and bar lengths from beats: a Viterbi over the position
      # in the bar, allowing short bars (a 2/4 gap bar, a dropped beat).
      module Meter
        module_function

        # Downbeat likelihood for each beat (beat i spans its time to the
        # next beat's; the last spans one median interval), in standard
        # deviations: the change in timbre (MFCC 1..13) from the previous
        # beat, the change in harmony (chroma cosine distance) between the
        # +harmony_beats+ beats before and from the beat (half a bar in 4/4,
        # so drum noise averages out and a kick on 3 doesn't look like a
        # chord change), the same for the bass chroma (55 to 300 Hz, the
        # roots; times BASS_WEIGHT), energy rises, and half the low band's
        # onset at the beat (kicks, bass notes).
        #
        # +frames+ is a Frames, +beat_frames+ the beats' frame positions.
        def observations(frames, beat_frames, harmony_beats: 2)
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
          bch = mean_rows.(frames.bass_chroma)
          energy = spans.map { |r| frames.energy[r].mean }
          low = frames.band_flux[0]
          low_onset = Numo::DFloat.cast(spans.map { |r| low[r.begin...[r.begin + 3, r.end].min].max })

          dt = Numo::DFloat.zeros(n)
          dc = Numo::DFloat.zeros(n)
          db = Numo::DFloat.zeros(n)
          de = Numo::DFloat.zeros(n)
          hb = harmony_beats
          edge = []
          (1...n).each do |i|
            dt[i] = Math.sqrt(((mf[i, true] - mf[i - 1, true])**2).sum)
            de[i] = [energy[i] - energy[i - 1], 0].max
            next edge << i if i < hb || i + hb > n

            dc[i] = window_change(ch, i, hb)
            db[i] = window_change(bch, i, hb)
          end
          # Nothing came before the first beat, and the harmony windows don't
          # fit at the ends: neutral values there, not "no change"
          inner = (0...n).to_a - edge - [0]
          [dc, db].each { |x| x[edge + [0]] = inner.empty? ? 0 : x[inner].mean }
          [dt, de].each { |x| x[0] = x[1..].mean }

          zscore(dt) + zscore(dc) + BASS_WEIGHT * zscore(db) + zscore(de) + 0.5 * zscore(low_onset)
        end

        # Weight of the bass chroma change in .observations.  1 found the
        # 2/4 bar in generated grooves with a bass line where 0 did not, and
        # kept the research spike's songs as they were; 2 added false 2-beat
        # bars in the night bus and drums_808.
        BASS_WEIGHT = 1.0

        # Cosine distance between the mean rows of +m+ over the +hb+ rows
        # before row +i+ and the +hb+ rows from it.
        def window_change(m, i, hb)
          a = m[i...(i + hb), true].mean(axis: 0)
          b = m[(i - hb)...i, true].mean(axis: 0)
          1 - (a * b).sum / (Math.sqrt((a * a).sum * (b * b).sum) + 1e-12)
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
