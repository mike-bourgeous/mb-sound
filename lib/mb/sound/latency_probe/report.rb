module MB
  module Sound
    class LatencyProbe
      # The text summary and plots of a LatencyProbe run: percentiles,
      # counts over 1/5/10/20/50/80 ms, the top stalls with wall times,
      # periodicity (Periodicity), attribution of the Ruby ticker's stalls
      # (system, GC, YJIT, or the process: GVL holds), session dropouts
      # lined up with stalls, and System readings; plots of the per-second
      # series over time (minute boundaries marked), the latency histograms,
      # and stalls by second of the minute.
      class Report
        LIMITS_MS = [1, 5, 10, 20, 50, 80].freeze
        QUANTILES = [0.5, 0.9, 0.99, 0.999, 0.9999].freeze

        # +wall_ns+ as local "HH:MM:SS.mmm" (with +date+ "YYYY-MM-DD ").
        def self.clock(wall_ns, date: false)
          return '' unless wall_ns

          t = Time.at(wall_ns / 1_000_000_000, wall_ns % 1_000_000_000, :nsec)
          t.strftime(date ? '%Y-%m-%d %H:%M:%S.%L' : '%H:%M:%S.%L')
        end

        # Seconds as "1h02m03s" / "2m05s" / "4.2s".
        def self.duration(s)
          s = s.to_f
          return format('%.1fs', s) if s < 60

          h, rem = s.divmod(3600)
          m, sec = rem.divmod(60)
          h > 0 ? format('%dh%02dm%02ds', h, m, sec) : format('%dm%02ds', m, sec)
        end

        def initialize(probe)
          @probe = probe
          @rows = probe.seconds
          @episodes = probe.episodes.dup
          @ruby = probe.ruby_events.dup
          @session = probe.session_events.dup
          @stats = probe.stats
          @options = probe.options
        end

        # Ruby ticker stalls by likely cause: Hash of cause => [count,
        # total ms].  :system when a probe episode covers it (the probe saw
        # the machine stall too), else :gc when that second had GC time,
        # else :yjit when YJIT compiled then, else :process (the GVL held by
        # another thread, or anything else in this process).
        def ruby_causes
          by_second = @rows.to_h { |r| [r[:second], r] }
          causes = Hash.new { |h, k| h[k] = [0, 0.0] }
          @ruby.each do |e|
            c = cause_of(e, by_second)
            causes[c][0] += 1
            causes[c][1] += e[:late_ns] / 1e6
          end
          causes
        end

        # Session events (slow buffers, gaps, underruns) by what was
        # happening: :system (a probe episode within 0.25 s), :process (a
        # Ruby stall within 0.25 s), or :render (neither: the graph itself).
        def session_causes
          causes = Hash.new(0)
          @session.each do |e|
            causes[session_cause(e)] += 1
          end
          causes
        end

        def periodicity
          return nil if @episodes.empty?

          times = @episodes.map { |e| e[:worst_wall_ns] / 1e9 }
          start = @rows.first&.dig(:second)
          stop = @rows.last && @rows.last[:second] + 1
          Periodicity.detect(times, start: start, stop: stop)
        end

        def text
          out = []
          s = @stats
          o = @options
          first = @rows.first
          last = @rows.last
          span = first && last ? "#{Report.clock(first[:second] * 1_000_000_000, date: true)[0, 19]} .. #{Report.clock(last[:second] * 1_000_000_000)[0, 8]}" : 'no seconds yet'
          out << format('Latency probe: %s (%s), period %s, threshold %s', span, Report.duration(@probe.elapsed), ms_text(o[:period] * 1e3), ms_text(o[:threshold] * 1e3))
          out << "Probe thread: #{s[:priority]}#{s[:error] ? "; #{s[:error]}" : ''}; last on CPU #{s[:cpu]}#{s[:mlocked] ? '; buffers locked' : ''}"
          out << "Wake clock: #{FastLatency::WAKE_CLOCK}"
          work = []
          work << format('memory %s, %s per tick (baseline %s)', bytes(s[:memory_bytes]), bytes(s[:memory_touch]), us_text(s[:memory_base_ns])) if s[:memory_bytes] > 0
          work << format('CPU %d iterations (baseline %s)', s[:cpu_iterations], us_text(s[:cpu_base_ns])) if s[:cpu_iterations] > 0
          out << "Work probes: #{work.empty? ? 'none (wake lateness only)' : work.join('; ')}"
          out << format('Ticks %d (missed %d), over threshold %d, tick events %d (dropped %d), episodes %d, ring overflow %d',
            s[:ticks], s[:missed], s[:over], s[:events], s[:dropped], s[:episodes], s[:overflow])
          out << ''

          out << 'Percentiles (ms)    ' + QUANTILES.map { |q| format('%9s', "p#{(q * 100).to_s.sub(/\.0\z/, '')}") }.join + '      max'
          series.each do |name, h|
            next if h.empty?

            out << format('%-20s', name) + QUANTILES.map { |q| format('%9.3f', h.percentile(q) / 1e6) }.join + format('%9.3f', h.max_ns.to_f / 1e6)
          end
          out << ''

          out << 'Ticks at least      ' + LIMITS_MS.map { |l| format('%8s', "#{l} ms") }.join
          series.each do |name, h|
            next if h.empty?

            out << format('%-20s', name) + LIMITS_MS.map { |l| format('%8d', h.count_at_least(l * 1_000_000)) }.join
          end
          out << format('%-20s', 'episodes (stall)') + LIMITS_MS.map { |l| format('%8d', @episodes.count { |e| e[:stall_ns] >= l * 1_000_000 }) }.join
          out << ''

          top = @probe.top.sort_by { |e| -e[:stall_ns] }.first(10)
          if top.empty?
            out << 'No probe stall episodes.'
          else
            out << 'Top probe stall episodes (system):'
            out << '  worst at                  stall     late   memory      cpu  duration  ticks  over  missed'
            top.each do |e|
              out << format('  %s (%s) %8.2f %8.2f %8.3f %8.3f %9.1f %6d %5d %7d',
                Report.clock(e[:worst_wall_ns], date: true)[5..], second_of_minute(e[:worst_wall_ns]),
                e[:stall_ns] / 1e6, e[:late_ns] / 1e6, e[:mem_ns] / 1e6, e[:cpu_ns] / 1e6,
                e[:duration_ns] / 1e6, e[:ticks], e[:over], e[:missed])
            end
            base = s[:memory_base_ns]
            worst_mem = top.map { |e| e[:mem_ns] }.max
            if base && base > 0 && worst_mem > 0
              e = top.max_by { |x| x[:mem_ns] }
              cpu_share = e[:mem_thread_cpu_ns].to_i > 0 ? format(', thread CPU %.0f%% of it', 100.0 * e[:mem_thread_cpu_ns] / e[:mem_ns]) : ''
              out << format('  Slowest memory work: %.1fx its baseline%s (near 100%%: the CPU or memory was slow; low: the thread was descheduled)', worst_mem.to_f / base, cpu_share)
            end
          end
          out << ''

          per = periodicity
          if per
            out << "Periodicity: #{per}."
          elsif @episodes.length >= 4
            out << 'Periodicity: none found among the probe episodes.'
          end
          if @rows.length > 120
            flags = @rows.map { |r| r[:over].to_i > 0 || r[:ticks].to_i == 0 ? 1 : 0 }
            lag, r = Periodicity.best_lag(flags, [600, @rows.length / 3].min)
            out << format('Autocorrelation of seconds with stalls: best lag %d s (r %.2f)', lag, r) if lag && r > 0.2
          end
          out << ''

          unless @ruby.empty? && !@probe.options[:ruby]
            causes = ruby_causes
            out << format('Ruby ticker stalls over %s: %d', ms_text(@options[:threshold] * 1e3), @ruby.length)
            causes.sort_by { |_, (n, _)| -n }.each do |c, (n, total)|
              out << format('  %-8s %6d  (%.0f ms in all)', c, n, total)
            end
            worst = @ruby.max_by { |e| e[:late_ns] }
            out << format('  worst %.1f ms at %s (%s)', worst[:late_ns] / 1e6, Report.clock(worst[:wall_ns]), cause_of(worst, @rows.to_h { |r| [r[:second], r] })) if worst
            gc = @rows.sum { |r| r[:gc_count].to_i }
            major = @rows.sum { |r| r[:gc_major].to_i }
            gc_ms = @rows.sum { |r| r[:gc_ms].to_f }
            yjit_ms = @rows.sum { |r| r[:yjit_ms].to_f }
            out << format('  GC: %d runs (%d major), %.0f ms; YJIT compile %s', gc, major, gc_ms, @probe.yjit? ? format('%.0f ms', yjit_ms) : 'off')
            out << ''
          end

          if @probe.session_watch || !@session.empty? || @rows.any? { |r| r[:s_buffers] }
            buffers = @rows.sum { |r| r[:s_buffers].to_i }
            underruns = @rows.sum { |r| r[:s_underruns].to_i }
            slow = @rows.sum { |r| r[:s_slow].to_i }
            worst = @rows.map { |r| r[:s_render_max_ms].to_f }.max.to_f
            out << format('Session: %d buffers, %d slow, %d underruns, slowest render %.1f ms', buffers, slow, underruns, worst)
            sc = session_causes
            out << '  events near: ' + sc.map { |k, v| "#{k} #{v}" }.join(', ') unless sc.empty?
            out << ''
          end

          sys = system_summary
          unless sys.empty?
            out << 'System (per second): ' + sys.join('; ')
          end

          out.join("\n") + "\n"
        end

        # The plots as Plot Figures/Charts: { time:, histogram:, phase: }.
        def plots
          { time: time_figure, histogram: histogram_chart, phase: phase_chart }.compact
        end

        # Writes report.txt and each plot as .svg, .png, and .txt into
        # +dir+.  Returns a Hash of paths.
        def save(dir)
          paths = { report: File.join(dir, 'report.txt') }
          File.write(paths[:report], text)
          plots.each do |name, plot|
            base = File.join(dir, name.to_s)
            h = name == :time ? 1100 : 480
            plot.save("#{base}.svg", width: 1200, height: h)
            plot.save("#{base}.png", width: 1200, height: h)
            plot.save("#{base}.txt", width: 110, height: name == :time ? 56 : 26)
            paths[name] = "#{base}.svg"
          end
          paths
        end

        # Lifetime histograms by name, for the tables.
        def series
          out = {
            'wake late' => @probe.histogram(:late),
            'memory work' => @probe.histogram(:memory),
            'cpu work' => @probe.histogram(:cpu),
            'stall (probe)' => @probe.histogram(:stall),
          }
          out['ruby ticker'] = @probe.histogram(:ruby) if @probe.options[:ruby]
          out['session render'] = @probe.histogram(:session) unless @probe.histogram(:session).empty?
          out
        end

        def time_figure
          return nil if @rows.length < 2

          t0 = @rows.first[:second]
          minutes = Numo::DFloat.cast(@rows.map { |r| (r[:second] - t0) / 60.0 })
          col = ->(k, floor = nil) {
            Numo::DFloat.cast(@rows.map { |r|
              v = r[k]
              v.nil? ? Float::NAN : (floor ? [v.to_f, floor].max : v.to_f)
            })
          }
          span = minutes[-1]
          every = span <= 90 ? 1 : (span <= 600 ? 10 : 60)
          rules = (1..(span / every).floor).map { |k| ((t0 / 60 / every + k).floor * every * 60 - t0) / 60.0 }.select { |m| m > 0 && m < span }

          ep = @episodes.map { |e| [(e[:worst_wall_ns] / 1e9 - t0) / 60.0, [e[:stall_ns] / 1e6, 0.01].max] }
          ruby = @probe.options[:ruby]
          session = @rows.any? { |r| r[:s_buffers] }
          xlabel = "minutes from #{Report.clock(t0 * 1_000_000_000)[0, 8]}#{rules.empty? ? '' : " (rules: every #{every == 1 ? '' : "#{every} "}minute#{every == 1 ? '' : 's'} on the clock)"}"
          has_sys = @rows.any? { |r| r[:cpu_busy_pct] || r[:load1] }
          has_mem = @rows.any? { |r| r[:mem_available_mb] }
          has_load = @rows.any? { |r| r[:load1] }
          psi = @rows.any? { |r| r[:psi_mem_some_ms] }
          steal = @rows.any? { |r| r[:cpu_steal_pct] }

          Plot.figure(columns: 1) {
            chart(title: 'Worst stall per second (ms, log)') {
              x :linear, label: xlabel
              y :log
              line col.(:stall_max_ms, 0.01), x: minutes, label: 'probe max'
              line col.(:late_p99_ms, 0.01), x: minutes, label: 'probe wake p99'
              line col.(:r_late_max_ms, 0.01), x: minutes, label: 'ruby max' if ruby
              line col.(:s_render_max_ms, 0.01), x: minutes, label: 'session render max' if session
              points Numo::DFloat.cast(ep.map(&:last)), x: Numo::DFloat.cast(ep.map(&:first)), label: 'episodes' unless ep.empty?
              rules.each { |m| rule x: m }
            }
            if has_sys
              chart(title: 'CPU (%)') {
                x :linear, label: xlabel
                y 0..100
                line col.(:cpu_busy_pct), x: minutes, label: 'busy'
                line col.(:cpu_steal_pct), x: minutes, label: 'steal' if steal
                line col.(:psi_mem_some_ms) / 10, x: minutes, label: 'PSI memory some' if psi
                line col.(:psi_cpu_some_ms) / 10, x: minutes, label: 'PSI cpu some' if psi
                rules.each { |m| rule x: m }
              }
            end
            if has_load
              chart(title: 'Load average (1 min)') {
                x :linear, label: xlabel
                line col.(:load1), x: minutes, label: 'load1'
                rules.each { |m| rule x: m }
              }
            end
            if has_mem
              chart(title: 'Available memory (MB)') {
                x :linear, label: xlabel
                line col.(:mem_available_mb), x: minutes, label: 'MemAvailable'
                rules.each { |m| rule x: m }
              }
            end
          }
        end

        def histogram_chart
          hs = { 'wake late' => @probe.histogram(:late), 'stall (probe)' => @probe.histogram(:stall) }
          hs['memory work'] = @probe.histogram(:memory)
          hs['ruby ticker'] = @probe.histogram(:ruby) if @probe.options[:ruby]
          hs = hs.reject { |_, h| h.empty? }
          return nil if hs.empty?

          Plot.chart(title: 'Latency histograms (ticks per bucket, log-log)') {
            x :log, label: 'ms'
            y :log
            hs.each do |name, h|
              pairs = h.counts.each_with_index.filter_map { |c, i| [Histogram.value(i) / 1e6, c] if c > 0 && i >= Histogram::SUB }
              next if pairs.length < 2

              step Numo::DFloat.cast(pairs.map(&:last)), x: Numo::DFloat.cast(pairs.map(&:first)), label: name
            end
          }
        end

        def phase_chart
          return nil if @episodes.empty? && @ruby.empty?

          probe = Array.new(60, 0)
          @episodes.each { |e| probe[(e[:worst_wall_ns] / 1_000_000_000) % 60] += 1 }
          ruby = Array.new(60, 0)
          @ruby.each { |e| ruby[(e[:wall_ns] / 1_000_000_000) % 60] += 1 }
          has_ruby = ruby.sum > 0
          Plot.chart(title: 'Stalls by second of the wall-clock minute') {
            x 0..59, label: 'second of the minute'
            stems Numo::DFloat.cast(probe), label: 'probe episodes'
            line Numo::DFloat.cast(ruby), label: 'ruby ticker stalls' if has_ruby
          }
        end

        private

        def cause_of(e, by_second)
          from = e[:wall_ns] - e[:late_ns] - 2_000_000
          to = e[:wall_ns] + 2_000_000
          return :system if @episodes.any? { |x| x[:wall_ns] <= to && x[:wall_ns] + x[:duration_ns] >= from }

          row = by_second[e[:wall_ns] / 1_000_000_000]
          return :gc if row && row[:gc_ms].to_f > 0
          return :yjit if row && row[:yjit_ms].to_f > 0.5

          :process
        end

        def session_cause(e)
          t = e[:wall_ns]
          w = 250_000_000
          return :system if @episodes.any? { |x| x[:wall_ns] - w <= t && x[:wall_ns] + x[:duration_ns] + w >= t }
          return :process if @ruby.any? { |x| (x[:wall_ns] - t).abs <= w }

          :render
        end

        def system_summary
          out = []
          stat = ->(k) {
            v = @rows.filter_map { |r| r[k] }
            v.empty? ? nil : [v.sum / v.length.to_f, v.min, v.max]
          }
          if (m = stat.(:mem_available_mb))
            out << format('MemAvailable min %.0f MB (mean %.0f)', m[1], m[0])
          end
          if (l = stat.(:load1))
            out << format('load1 mean %.2f max %.2f', l[0], l[2])
          end
          if (c = stat.(:cpu_busy_pct))
            out << format('CPU busy mean %.1f%% max %.1f%%', c[0], c[2])
          end
          if (c = stat.(:cpu_steal_pct))
            out << format('steal mean %.2f%% max %.1f%%', c[0], c[2])
          end
          if (c = stat.(:psi_mem_some_ms))
            out << format('PSI memory some max %.0f ms/s', c[2])
          end
          if (c = stat.(:psi_cpu_some_ms))
            out << format('PSI cpu some max %.0f ms/s', c[2])
          end
          if (c = stat.(:major_faults))
            out << format('major faults max %d/s', c[2])
          end
          if (c = stat.(:compact_stalls)) && c[2] > 0
            out << format('compaction stalls max %d/s', c[2])
          end
          if (c = stat.(:cpu_mhz))
            out << format('CPU MHz %.0f..%.0f', c[1], c[2])
          end
          out
        end

        def second_of_minute(wall_ns)
          format(':%04.1f', (wall_ns / 1e9) % 60)
        end

        def ms_text(ms)
          ms >= 1 ? format('%g ms', ms.round(3)) : format('%g us', (ms * 1000).round(1))
        end

        def us_text(ns)
          ns ? format('%.1f us', ns / 1e3) : 'calibrating'
        end

        def bytes(n)
          n >= 1 << 20 ? format('%g MiB', (n / 1048576.0).round(1)) : format('%g KiB', (n / 1024.0).round(1))
        end
      end
    end
  end
end
