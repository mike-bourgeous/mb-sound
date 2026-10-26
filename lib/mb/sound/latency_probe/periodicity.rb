module MB
  module Sound
    class LatencyProbe
      # Finds stalls that repeat on a clock, like the Mac Docker VM's stall
      # at the top of every wall-clock minute (scene-jit-1, 2026-10-24).
      #
      # Event times (wall-clock seconds since the epoch) closer together
      # than +merge+ seconds count once.  For each candidate period, the
      # densest phase window (5% of the period, at least a second wide)
      # gives the phase the events cluster at and the share of events in
      # it, plus the coverage: the share of whole cycles in the run with an
      # event in the window.  The period with the best share x coverage
      # wins if the window holds more events than chance would put there:
      # a Poisson tail under uniform times for a window as wide as the
      # cluster really is (at least MIN_WIDTH), times the number of such
      # windows in a period (a scan correction: the window was placed where
      # the events are).  So three big stalls within a few ms of :00.2 in a
      # five-minute run count (omnibus14: probe-20261026-052506 reported
      # none found with 4 needed), while three random times rarely fall
      # that close.  Phases are against the epoch,
      # so periods that divide an hour read as wall-clock positions
      # (":59.9 of each minute").  A densest window rather than a circular
      # mean, since a few stalls at other times pull a mean phase away.
      module Periodicity
        PERIODS = [1, 2, 5, 10, 15, 20, 30, 60, 120, 300, 600, 900, 1800, 3600].freeze

        # The narrowest cluster width (seconds) the chance estimate uses:
        # tighter clusters count as this wide (the VM's minute stalls wander
        # by a few hundred ms).
        MIN_WIDTH = 0.5

        Result = Data.define(:period, :phase, :share, :coverage, :clusters, :cycles, :hits, :p_value) do
          # The phase as a wall-clock position: ":59.9" for minutes,
          # "4:59.9" in 5-minute cycles, else seconds into the cycle.
          def phase_label
            Periodicity.phase_label(phase, period)
          end

          def to_s
            every = Periodicity.period_label(period)
            format('stalls cluster at %s of each %s (%d%% of stall episodes; in %d of %d %s)',
              phase_label, every, (100 * share).round, hits, cycles, period == 60 ? 'minutes' : 'cycles')
          end
        end

        module_function

        # Detects the best period for +times+ (Floats, wall seconds) in a
        # run from +start+ to +stop+ (default the first and last times), or
        # returns nil.  +periods+ are candidates in seconds.
        def detect(times, start: nil, stop: nil, periods: PERIODS, merge: 1.0, min_clusters: 3, min_share: 0.3, min_coverage: 0.4, max_p: 0.001)
          clusters = merge_times(times.sort, merge)
          return nil if clusters.length < min_clusters

          start ||= clusters.first
          stop ||= clusters.last
          span = stop - start

          candidates = periods.filter_map { |p|
            next if span < 3 * p || p < 4 * merge

            score(clusters, p, start, stop)
          }
          good = candidates.select { |c| c.share >= min_share && c.coverage >= min_coverage && c.p_value <= max_p }
          good.max_by { |c| [c.share * c.coverage, c.period] }
        end

        # The densest phase window of +clusters+ at period +p+, its share of
        # the events, and its coverage of the run's cycles.
        def score(clusters, p, start, stop)
          half = [0.025 * p, 0.5].max
          phases = clusters.map { |t| t % p }
          dist = ->(a, b) { d = (a - b).abs % p; d > p / 2.0 ? p - d : d }

          best = phases.max_by { |c| phases.count { |x| dist.(x, c) <= half } }
          inside = phases.select { |x| dist.(x, best) <= half }
          # (the window's center: the inside phases' mean, unwrapped around best)
          phase = (inside.sum { |x| best + ((x - best + p / 2.0) % p) - p / 2.0 } / inside.length) % p
          near = phases.select { |x| dist.(x, phase) <= half }
          inside = near.length
          # How wide the cluster really is, for the chance estimate
          width = [2 * near.map { |x| dist.(x, phase) }.max.to_f, [MIN_WIDTH, 2 * half].min].max

          first = ((start - phase) / p).ceil
          last = ((stop - phase) / p).floor
          hits = 0
          cycles = 0
          if last >= first
            cycles = last - first + 1
            hit_cycles = {}
            clusters.each do |t|
              k = ((t - phase) / p).round
              hit_cycles[k] = true if k.between?(first, last) && (t - (phase + k * p)).abs <= half
            end
            hits = hit_cycles.length
          end

          n = clusters.length
          Result.new(
            period: p, phase: phase, share: inside.to_f / n, coverage: cycles > 0 ? hits.to_f / cycles : 0.0,
            clusters: n, cycles: cycles, hits: hits, p_value: [poisson_tail(inside, n * [width / p, 1.0].min) * p / width, 1.0].min,
          )
        end

        # P(X >= k) for a Poisson variable with mean +lambda+.
        def poisson_tail(k, lambda)
          return 1.0 if k <= 0

          term = Math.exp(-lambda)
          below = 0.0
          k.times do |i|
            below += term
            term *= lambda / (i + 1)
          end
          [1.0 - below, 0.0].max
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
