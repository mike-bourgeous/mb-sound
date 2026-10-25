module MB
  module Sound
    class LatencyProbe
      # Finds stalls that repeat on a clock, like the Mac Docker VM's stall
      # at the top of every wall-clock minute (scene-jit-1, 2026-10-24).
      #
      # Event times (wall-clock seconds since the epoch) closer together
      # than +merge+ seconds count once.  For each candidate period, the
      # events' phases (time mod period) give a circular mean (the phase
      # they cluster at) and its resultant length R (1: every event at the
      # same phase; near 0: spread out), plus the coverage: the share of
      # whole cycles in the run with an event near that phase.  The period
      # with the best R x coverage wins if R and the Rayleigh test (p about
      # exp(-n R^2)) say it isn't chance.  Phases are against the epoch, so
      # periods that divide an hour read as wall-clock positions (":59.9 of
      # each minute").
      module Periodicity
        PERIODS = [1, 2, 5, 10, 15, 20, 30, 60, 120, 300, 600, 900, 1800, 3600].freeze

        Result = Data.define(:period, :phase, :r, :coverage, :clusters, :cycles, :hits, :p_value) do
          # The phase as a wall-clock position: ":59.9" for minutes,
          # "4:59.9" in 5-minute cycles, else seconds into the cycle.
          def phase_label
            Periodicity.phase_label(phase, period)
          end

          def to_s
            every = Periodicity.period_label(period)
            format('stalls cluster at %s of each %s (R %.2f; in %d of %d %s)',
              phase_label, every, r, hits, cycles, period == 60 ? 'minutes' : 'cycles')
          end
        end

        module_function

        # Detects the best period for +times+ (Floats, wall seconds) in a
        # run from +start+ to +stop+ (default the first and last times), or
        # returns nil.  +periods+ are candidates in seconds.
        def detect(times, start: nil, stop: nil, periods: PERIODS, merge: 1.0, min_clusters: 4, min_r: 0.6, min_coverage: 0.4, max_p: 0.01)
          clusters = merge_times(times.sort, merge)
          return nil if clusters.length < min_clusters

          start ||= clusters.first
          stop ||= clusters.last
          span = stop - start

          candidates = periods.filter_map { |p|
            next if span < 3 * p || p < 2 * merge

            score(clusters, p, start, stop)
          }
          good = candidates.select { |c| c.r >= min_r && c.coverage >= min_coverage && c.p_value <= max_p }
          good.max_by { |c| [c.r * c.coverage, c.period] }
        end

        # The phase, R, and coverage of +clusters+ at period +p+.
        def score(clusters, p, start, stop)
          sx = 0.0
          sy = 0.0
          clusters.each do |t|
            a = 2 * Math::PI * (t % p) / p
            sx += Math.cos(a)
            sy += Math.sin(a)
          end
          n = clusters.length
          r = Math.sqrt(sx * sx + sy * sy) / n
          phase = (Math.atan2(sy, sx) / (2 * Math::PI) * p) % p

          # Cycles whose window around the phase lies inside the run, and
          # how many of them hold an event within the window
          window = [0.05 * p, 1.0].max
          first = ((start - phase) / p).ceil
          last = ((stop - phase) / p).floor
          hits = 0
          cycles = 0
          if last >= first
            cycles = last - first + 1
            hit_cycles = {}
            clusters.each do |t|
              k = ((t - phase) / p).round
              hit_cycles[k] = true if k.between?(first, last) && (t - (phase + k * p)).abs <= window
            end
            hits = hit_cycles.length
          end
          coverage = cycles > 0 ? hits.to_f / cycles : 0.0
          p_value = Math.exp(-n * r * r)

          Result.new(period: p, phase: phase, r: r, coverage: coverage, clusters: n, cycles: cycles, hits: hits, p_value: p_value)
        end

        # Times with gaps of at most +merge+ seconds count as one, at the
        # first time.
        def merge_times(sorted, merge)
          out = []
          last = nil
          sorted.each do |t|
            out << t if last.nil? || t - last > merge
            last = t
          end
          out
        end

        # Autocorrelation of a per-second series (e.g. 1 for seconds with a
        # stall, else 0) at lags 1..max_lag: Array of [lag, r].
        def autocorrelation(series, max_lag)
          x = series.map(&:to_f)
          n = x.length
          mean = x.sum / n
          d = x.map { |v| v - mean }
          var = d.sum { |v| v * v }
          return [] if var == 0

          (1..[max_lag, n - 2].min).map { |lag|
            s = 0.0
            (n - lag).times { |i| s += d[i] * d[i + lag] }
            [lag, s / var]
          }
        end

        # The lag with the highest autocorrelation past lag +min_lag+, as
        # [lag, r], or nil.
        def best_lag(series, max_lag, min_lag: 2)
          autocorrelation(series, max_lag).select { |lag, _| lag >= min_lag }.max_by { |_, r| r }
        end

        def phase_label(phase, period)
          if period == 60
            format(':%04.1f', phase)
          elsif period % 60 == 0 && 3600 % period == 0
            format('%d:%04.1f', (phase / 60).floor, phase % 60)
          else
            format('%.1f s', phase)
          end
        end

        def period_label(period)
          case period
          when 60 then 'minute'
          when 3600 then 'hour'
          else
            period % 60 == 0 ? "#{period / 60} minutes" : "#{period} s"
          end
        end
      end
    end
  end
end
