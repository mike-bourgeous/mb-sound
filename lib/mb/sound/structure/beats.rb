module MB
  module Sound
    module Structure
      # Beat trackers working on onset envelopes (see Frames).  Times here
      # are in frames (Floats); the analysis converts them to seconds.
      module Beats
        # Bins of the phase histogram used by .grid.
        PHASE_BINS = 100

        module_function

        # Constant-tempo beat grid, for machine-timed music (our renders,
        # most electronic music): the beat period within +-+range+
        # (relative, in steps of +step+) of +bpm+ whose fold of +onset+ (a
        # PHASE_BINS phase histogram, circularly smoothed) has the sharpest
        # peak, and the phase where +phase_onset+ folds to its peak (with
        # the low band weighted up, kicks beat offbeat hats).  Beats run
        # through the whole envelope, then the silent ends are trimmed (see
        # .active).
        #
        # Returns [beat frames (Floats), bpm].
        def grid(onset, phase_onset, bpm, fps, range: 0.01, step: 0.0002)
          p0 = 60 * fps / bpm
          period = if range > 0
            (-range).step(range, step).map { |d| p0 * (1 + d) }.max_by { |p| fold(onset, p).max }
          else
            p0
          end

          h = fold(phase_onset, period).to_a
          nb = PHASE_BINS
          k = h.each_index.max_by { |i| h[i] }
          a, b, c = h[(k - 1) % nb], h[k], h[(k + 1) % nb]
          den = a - 2 * b + c
          frac = den != 0 ? 0.5 * (a - c) / den : 0
          phase = (k + frac) / nb * period
          phase -= period if phase > 0.75 * period # a beat just before frame 0 (detection runs a little early)

          count = ((onset.size - 1 - phase) / period).floor + 1
          frames = Array.new(count) { |i| phase + i * period }
          [active(onset, frames, period), 60 * fps / period]
        end

        # Folds +env+ (Numo array) at +period+ frames into a PHASE_BINS
        # histogram (linear interpolation between bins, then a [1, 2, 1] / 4
        # circular smoothing).  Returns a Numo::DFloat.
        def fold(env, period)
          nb = PHASE_BINS
          t = Numo::DFloat.new(env.size).seq
          x = (t % period) / period * nb
          i = x.floor
          w = x - i
          ii = Numo::Int32.cast(i) % nb
          h = ii.bincount(env * (1 - w), minlength: nb) + ((ii + 1) % nb).bincount(env * w, minlength: nb)
          h = h[0...nb]
          prev = Numo::DFloat.hstack([h[-1..-1], h[0...-1]])
          nxt = Numo::DFloat.hstack([h[1..-1], h[0..0]])
          0.25 * prev + 0.5 * h + 0.25 * nxt
        end

        # The beats of +frames+ (Floats) from the first to the last one with
        # onsets nearby: a beat's local onset (the maximum within a quarter
        # period) must reach half the RMS of all beats' local onsets.
        def active(env, frames, period)
          return frames if frames.empty?
          ea = env.to_a
          half = (period / 4).round
          local = frames.map { |f|
            c = f.round
            lo = (c - half).clamp(0, ea.length)
            hi = (c + half).clamp(-1, ea.length - 1)
            hi >= lo ? ea[lo..hi].max || 0.0 : 0.0
          }
          rms = Math.sqrt(local.sum { |v| v * v } / local.length)
          first = local.index { |v| v >= 0.5 * rms } || 0
          last = local.rindex { |v| v >= 0.5 * rms } || local.length - 1
          frames[first..last]
        end

        # Ellis (2007) dynamic-programming beat tracker, for music with a
        # moving tempo: each frame scores its (smoothed) onset strength plus
        # the best earlier beat's score, penalized by +tightness+ times the
        # squared log ratio of the interval to the period.  Silent ends are
        # trimmed (beats under half the RMS of the beats' onsets).
        #
        # In the research spike it drifted to the offbeat hats in the night
        # bus's breakdown and outro, so the grid is the default.
        #
        # Returns beat frames (Floats, refined to the onset peak within 2
        # frames).
        def dp(onset, bpm, fps, tightness: 100)
          period = 60 * fps / bpm
          sigma = period / 32
          kern = (-4..4).map { |i| Math.exp(-0.5 * (i / sigma)**2) }
          oa = onset.to_a
          n = oa.length
          local = Array.new(n) { |t| (-4..4).sum { |i| (u = t + i) >= 0 && u < n ? oa[u] * kern[i + 4] : 0 } }

          dmin = [(period / 2).round, 1].max
          dmax = (2 * period).round
          pen = (0..dmax).map { |d| d < dmin ? nil : -tightness * Math.log(d / period)**2 }
          score = Array.new(n, 0.0)
          back = Array.new(n, -1)
          n.times do |t|
            best = nil
            bi = -1
            d = dmin
            while d <= dmax && (u = t - d) >= 0
              v = score[u] + pen[d]
              if best.nil? || v > best
                best = v
                bi = u
              end
              d += 1
            end
            score[t] = local[t] + (best || 0)
            back[t] = bi
          end

          t = ([n - period.round, 0].max...n).max_by { |i| score[i] }
          beats = []
          while t >= 0
            beats << t
            t = back[t]
          end
          beats.reverse!

          vals = beats.map { |b| local[b] }
          rms = Math.sqrt(vals.sum { |v| v * v } / vals.length)
          beats.shift while beats.any? && local[beats.first] < 0.5 * rms
          beats.pop while beats.any? && local[beats.last] < 0.5 * rms
          refine(beats, oa)
        end

        # Moves each beat frame to the onset peak within 2 frames (parabolic
        # interpolation).
        def refine(beats, oa)
          beats.map { |b|
            lo = [b - 2, 1].max
            hi = [b + 2, oa.length - 2].min
            next b.to_f if hi < lo
            p = (lo..hi).max_by { |i| oa[i] }
            a, c, d = oa[p - 1], oa[p], oa[p + 1]
            den = a - 2 * c + d
            frac = den != 0 ? (0.5 * (a - d) / den).clamp(-0.5, 0.5) : 0
            p + frac
          }
        end

        # Tempo fitted to beat times (any unit): the median interval, then a
        # least-squares line through the beats at their nearest grid
        # indices.  Returns the period in the same unit.
        def fit_period(times)
          return nil if times.length < 2
          diffs = times.each_cons(2).map { |a, b| b - a }.sort
          period = diffs[diffs.length / 2]
          t0 = times.first
          idx = times.map { |t| ((t - t0) / period).round }
          2.times do
            n = idx.length.to_f
            sx = idx.sum.to_f
            sy = times.sum
            sxx = idx.sum { |i| i * i }.to_f
            sxy = idx.zip(times).sum { |i, t| i * t }
            den = n * sxx - sx * sx
            break if den == 0
            period = (n * sxy - sx * sy) / den
            t0 = (sy - period * sx) / n
            idx = times.map { |t| ((t - t0) / period).round }
          end
          period
        end
      end
    end
  end
end
