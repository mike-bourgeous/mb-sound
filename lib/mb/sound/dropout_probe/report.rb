module MB
  module Sound
    class DropoutProbe
      # The dropout probe's report: text (counts by cause, the worst 10
      # with their context, run-wide render thread, GC, YJIT, device, queue,
      # and system numbers), the JSON log (#to_h), and a CSV of dropouts.
      class Report
        CSV_COLUMNS = %w[
          n wall t_s cause short_ms queue_ms late_ms window_ms away_ms cpu_ms gc_ms gc_majors gvl_ms lock_ms os_wake_ms
          unaccounted_ms yjit_ms episode_ms after_shrink load1 cpu_busy_pct mem_available_mb detail
        ].freeze

        # Writes kept in each dropout's JSON context: these many before the
        # gap and 2 after.
        CONTEXT_WRITES = 12

        # Seconds after a mark in which its dropout must start.
        MARK_WINDOW = 1.0

        # One line for a dropout as it is analyzed.
        def self.live_line(d, probe)
          g = d[:gap]
          r = d[:result]
          rate = probe.totals[:rate]
          format('dropout %d at %s (+%s): %.1f ms short, queue %d ms: %s (%s)',
            d[:n], clock(g[:start], probe.totals[:offset]), elapsed(g[:start] - probe.totals[:started_mono]),
            g[:short] * 1000.0 / rate, (g[:limit] * 1000.0 / rate).round, r[:cause], r[:detail])
        end

        def self.clock(mono_ns, offset)
          LatencyProbe::Report.clock(mono_ns + offset)
        end

        def self.elapsed(ns)
          s = ns / 1e9
          m, sec = s.divmod(60)
          format('%d:%06.3f', m, sec)
        end

        def initialize(probe)
          @probe = probe
          @totals = probe.totals
          @meta = probe.meta
          @rate = @totals[:rate].to_f
          @dropouts = probe.dropouts
          @rows = probe.latency_probe ? probe.latency_probe.seconds.to_h { |r| [r[:second], r] } : {}
        end

        # Dropouts by cause: {cause => count}, in Analysis::CAUSES order.
        def causes
          counts = @dropouts.map { |d| d[:result][:cause] }.tally
          Analysis::CAUSES.filter_map { |c| [c, counts[c]] if counts[c] }.to_h
        end

        def text
          m = @meta
          t = @totals
          out = []
          out << format('Dropout probe: %s for %s; %s', m[:name], LatencyProbe::Report.duration(m[:seconds]), m[:output])
          if m[:traced]
            out << format('Output: %s %s at %d Hz (writes at %d Hz), buffer %d, period %s, queue %s ms%s, concealment %s',
              m[:backend], m[:device].inspect, @rate.round, m[:sample_rate].to_f.round, m[:buffer].to_i, m[:period].inspect, m[:base_queue_ms], m[:adaptive] ? ' (adaptive)' : '', m[:conceal])
          else
            out << 'Output: no dropout trace (not a DeviceOutput: no underruns to see)'
          end
          out << format('GC %s; YJIT %s; %s', m[:gc_quiet] ? 'quiet (majors held off)' : 'normal', m[:yjit] ? 'on' : 'off', m[:ruby])
          out << ''

          total = @dropouts.length
          out << format('Dropouts: %d (underruns traced %d; %d idle gaps, the writer having stopped, not counted)', total, t[:underruns], t[:idle])
          unless total == 0
            out << 'Likely causes:'
            causes.each do |c, n|
              short = @dropouts.select { |d| d[:result][:cause] == c }.sum { |d| short_ms(d) }
              out << format('  %-13s %4d  %3d%%  %8.1f ms short  %s', c, n, (100.0 * n / total).round, short, Analysis::LABELS[c])
            end
            shrink = @dropouts.count { |d| d[:result][:after_shrink] }
            out << format('  (%d within %d s after the queue was lowered)', shrink, Analysis::SHRINK_RECENT.round) if shrink > 0
          end
          out << ''

          h = t[:hist]
          out << format('Render thread: %d writes; write to write %s; its CPU %s; woke after room %s; GVL back after a write %s',
            t[:writes], pct(h[:render]), pct(h[:render_cpu]), pct(h[:wake]), pct(h[:gvl_back]))
          gw = h[:gvl_wait]
          holders = t[:gvl_by].sort_by { |_, v| -v }.map { |k, v| format('%s %.0f ms', k, v / 1e6) }.join(', ')
          out << format('  GVL waits of 1 ms or more: %d, %s%s', gw.total, pct(gw), holders.empty? ? '' : "; held by #{holders}")
          unless t[:gvl_top].empty?
            top = t[:gvl_top].map { |ns, at, holder| format('%.1f ms at +%s (%s)', ns / 1e6, self.class.elapsed(at - t[:started_mono]), holder) }
            out << "  longest: #{top.join(', ')}"
          end
          gc_threads = t[:gc_by].sort_by { |_, v| -v }.map { |k, v| format('%s %.0f ms', k, v / 1e6) }.join(', ')
          out << format('GC: %d collections (%d major), %d steps of 0.1 ms or more, %.0f ms in all, longest step %.1f ms%s',
            t[:gc_collections], t[:gc_majors], t[:log][:gc_steps].to_i, t[:log][:gc_ns].to_i / 1e6, t[:log][:gc_max_ns].to_i / 1e6, gc_threads.empty? ? '' : " (#{gc_threads})")
          out << format('YJIT: %s', t[:yjit_ms] ? format('%.0f ms compiling', t[:yjit_ms]) : 'off')
          if (tr = t[:trace])
            out << format('Device: %d pulls, %d late (more than twice the period %.2f ms after the one before), longest between two %.1f ms; records lost %d writes, %d gaps, %d log',
              tr[:pulls], tr[:late_pulls], tr[:period_ns] / 1e6, tr[:max_pull_gap_ns] / 1e6, tr[:write_lost], tr[:gap_lost], t[:log][:lost].to_i)
          end
          unless t[:queue_changes].empty?
            changes = t[:queue_changes].map { |at, from, to| format('%s %d -> %d ms', self.class.elapsed(at - t[:started_mono]), ms_frames(from), ms_frames(to)) }
            out << "Queue changes (#{changes.length}): #{changes.first(12).join(', ')}#{changes.length > 12 ? ', ...' : ''}"
          end
          if @probe.latency_probe
            w = t[:worst_episode]
            out << format('System probe: %d episodes%s; %s', t[:episodes].to_i,
              w ? format(', worst %.1f ms at %s', w[:stall_ns] / 1e6, LatencyProbe::Report.clock(w[:worst_wall_ns])) : '', @meta.dig(:system_probe, :priority))
          end
          out << format("Probe's own thread: %.0f ms CPU over %d polls taking %s", t[:probe_cpu_ms], t[:polls], pct(h[:poll]))

          unless (m = matched_marks).empty?
            out << ''
            hits = m.count { |x| x[:cause] == x[:label].to_sym }
            out << format('Marks (things done on purpose): %d, %d with a dropout of their own kind after them', m.length, hits)
            m.group_by { |x| x[:label] }.each do |label, xs|
              got = xs.map { |x| x[:cause] || 'no dropout' }.tally.map { |k, v| "#{k} #{v}" }.join(', ')
              out << format('  %-8s %3d: %s', label, xs.length, got)
            end
          end

          unless @dropouts.empty?
            out << ''
            out << 'Worst 10 dropouts (by audio missing):'
            @dropouts.sort_by { |d| -d[:gap][:short] }.first(10).each { |d| out.concat(describe(d)) }
          end
          out.join("\n")
        end

        # Lines for one dropout.
        def describe(d)
          g = d[:gap]
          r = d[:result]
          c = r[:components]
          t = @totals
          lines = []
          a = adapt(d)
          lines << format('  #%d %s (+%s): %.1f ms short over %d pulls, queue %d ms%s, next write %s: %s, %s',
            d[:n], self.class.clock(g[:start], t[:offset]), self.class.elapsed(g[:start] - t[:started_mono]), short_ms(d), g[:pulls],
            ms_frames(g[:limit]), a ? format(' (shrink wait %g s, last change %s)', a[:shrink_wait].to_f.round(1), a[:last_adapt] || 'none') : '',
            r[:late_ms] ? format('%.1f ms after', r[:late_ms]) : 'none', r[:cause], r[:detail])
          unless c.empty?
            by = c[:gvl_by].map { |k, v| "#{k} #{v.round(1)}" }.join(', ')
            lines << format('     window %.1f ms, away %.1f: cpu %.1f (GC %.1f here, %.1f elsewhere%s), GVL %.1f%s, blocked %.1f, woke late %.1f, not running %.1f, YJIT %.1f; probe stall %.1f ms%s',
              r[:window_ms], c[:away_ms], c[:cpu_ms], c[:gc_render_ms], c[:gc_other_ms], c[:gc_majors] > 0 ? ", #{c[:gc_majors]} major" : '',
              c[:gvl_ms], by.empty? ? '' : " (#{by})", c[:lock_ms], c[:os_wake_ms], c[:unaccounted_ms], c[:yjit_ms], c[:episode_ms],
              (s = system_row(g)) ? format('; load %.2f, CPU %.0f%%, %.0f MB free', s[:load1].to_f, s[:cpu_busy_pct].to_f, s[:mem_available_mb].to_f) : '')
          end
          ws = context_writes(d).last(6).map { |w|
            format('%+.1f: %.1f ms (cpu %.1f) then waited %.1f, %d ms queued', w[:at_ms], w[:render_ms].to_f, w[:cpu_ms].to_f, w[:wait_ms], w[:queued_ms])
          }
          lines << "     writes (ms from the gap): #{ws.join('; ')}" unless ws.empty?
          lines
        end

        # Each mark (DropoutProbe#marks) with the first dropout starting
        # within MARK_WINDOW seconds after it: Hashes of :t_s, :label,
        # :dropout (its n), :cause.
        def matched_marks
          @probe.marks.map { |at, label|
            d = @dropouts.find { |x| x[:gap][:start] >= at && x[:gap][:start] <= at + MARK_WINDOW * 1e9 }
            { t_s: ((at - @totals[:started_mono]) / 1e9).round(3), label: label.to_s, dropout: d&.dig(:n), cause: d&.dig(:result, :cause) }
          }
        end

        # The JSON log.
        def to_h
          t = @totals
          h = t[:hist]
          {
            meta: @meta,
            summary: {
              dropouts: @dropouts.length,
              underruns_traced: t[:underruns],
              idle_gaps: t[:idle],
              causes: causes,
              short_ms: @dropouts.sum { |d| short_ms(d) }.round(3),
              writes: t[:writes],
              render_ms: hist_h(h[:render]),
              render_cpu_ms: hist_h(h[:render_cpu]),
              wake_ms: hist_h(h[:wake]),
              gvl_back_ms: hist_h(h[:gvl_back]),
              gvl_waits: hist_h(h[:gvl_wait]).merge(by: t[:gvl_by].transform_values { |v| (v / 1e6).round(3) },
                longest: t[:gvl_top].map { |ns, at, holder| { ms: (ns / 1e6).round(3), t_s: ((at - t[:started_mono]) / 1e9).round(3), holder: holder } }),
              gc: { collections: t[:gc_collections], majors: t[:gc_majors], steps: t[:log][:gc_steps], ms: (t[:log][:gc_ns].to_i / 1e6).round(3),
                    longest_ms: (t[:log][:gc_max_ns].to_i / 1e6).round(3), by: t[:gc_by].transform_values { |v| (v / 1e6).round(3) } },
              yjit_ms: t[:yjit_ms]&.round(3),
              device: t[:trace],
              log: t[:log],
              queue_changes: t[:queue_changes].map { |at, from, to| { t_s: ((at - t[:started_mono]) / 1e9).round(3), from_ms: ms_frames(from), to_ms: ms_frames(to) } },
              system: @probe.latency_probe && { episodes: t[:episodes], worst_ms: t[:worst_episode] && (t[:worst_episode][:stall_ns] / 1e6).round(3) },
              probe_cpu_ms: t[:probe_cpu_ms].round(1),
              poll_ms: hist_h(h[:poll]),
            },
            marks: matched_marks,
            dropouts: @dropouts.map { |d| dropout_h(d) },
          }
        end

        def csv
          lines = [CSV_COLUMNS.join(',')]
          @dropouts.each do |d|
            g = d[:gap]
            r = d[:result]
            c = r[:components]
            s = system_row(g) || {}
            row = [
              d[:n], LatencyProbe::Report.clock(g[:start] + @totals[:offset], date: true), ((g[:start] - @totals[:started_mono]) / 1e9).round(3), r[:cause],
              short_ms(d).round(3), ms_frames(g[:limit]), r[:late_ms]&.round(3), r[:window_ms].round(3),
              c[:away_ms], c[:cpu_ms], c[:gc_ms], c[:gc_majors], c[:gvl_ms], c[:lock_ms], c[:os_wake_ms], c[:unaccounted_ms], c[:yjit_ms], c[:episode_ms],
              r[:after_shrink], s[:load1], s[:cpu_busy_pct], s[:mem_available_mb], r[:detail],
            ]
            lines << row.map { |v| v.is_a?(String) && (v.include?(',') || v.include?('"')) ? "\"#{v.gsub('"', '""')}\"" : v.to_s }.join(',')
          end
          lines.join("\n") + "\n"
        end

        private

        def dropout_h(d)
          g = d[:gap]
          r = d[:result]
          t0 = g[:start]
          ctx = d[:ctx]
          rel = ->(ns) { ns.to_i > 0 ? ((ns - t0) / 1e6).round(3) : nil }
          {
            n: d[:n],
            wall: LatencyProbe::Report.clock(t0 + @totals[:offset], date: true),
            t_s: ((t0 - @totals[:started_mono]) / 1e9).round(3),
            underrun: g[:underrun],
            short_ms: short_ms(d).round(3),
            pulls: g[:pulls],
            frames: g[:frames],
            available: g[:available],
            device_late_ms: r[:device_late_ms]&.round(3),
            queue_ms: ms_frames(g[:limit]),
            adapt: adapt(d),
            cause: r[:cause],
            label: Analysis::LABELS[r[:cause]],
            detail: r[:detail],
            after_shrink: r[:after_shrink],
            late_ms: r[:late_ms]&.round(3),
            window_ms: r[:window_ms].round(3),
            components: r[:components],
            system: system_row(g)&.slice(:load1, :cpu_busy_pct, :cpu_steal_pct, :mem_available_mb, :psi_cpu_some_ms, :psi_mem_some_ms),
            context: {
              writes: context_writes(d),
              threads: ctx[:threads].map { |e| { thread: e[:thread], holder: e[:holder], off_ms: rel.(e[:a]), ready_ms: rel.(e[:b]), resumed_ms: rel.(e[:c]) } },
              gc: ctx[:gc].map { |x| { thread: x[:thread], at_ms: rel.(x[:a]), ms: ((x[:b] - x[:a]) / 1e6).round(3), major: x[:major] } },
              episodes: ctx[:episodes].select { |e| (e[:start] - t0).abs < 2_000_000_000 }.map { |e| { at_ms: rel.(e[:start]), ms: (e[:duration] / 1e6).round(3), stall_ms: (e[:stall] / 1e6).round(3) } },
              samples: ctx[:samples].map { |s| { at_ms: rel.(s[:mono]), gc_count: s[:gc_count], majors: s[:majors], queue_ms: s[:limit] && ms_frames(s[:limit]), shrink_wait: s[:shrink_wait], last_adapt: s[:last_adapt], load: s[:load]&.round(4) } },
            },
          }
        end

        # A dropout's writes, times in ms from the gap: when each started
        # (at_ms), the time since the one before returned (render_ms) and
        # its CPU (cpu_ms), its wait for room, the wake after room, the GVL
        # back, and the queue at its start.
        def context_writes(d)
          t0 = d[:gap][:start]
          ws = d[:ctx][:writes]
          after = ws.index { |w| w[:enter] > t0 } || ws.length
          from = [after - CONTEXT_WRITES, 0].max
          ws.each_with_index.select { |_, i| i >= from && i < after + 2 }.map { |w, i|
            prev = i > 0 ? ws[i - 1] : nil
            {
              at_ms: ((w[:enter] - t0) / 1e6).round(3),
              render_ms: prev && ((w[:enter] - prev[:exit]) / 1e6).round(3),
              cpu_ms: prev && w[:cpu_enter] >= 0 ? ((w[:cpu_enter] - prev[:cpu_exit]) / 1e6).round(3) : nil,
              wait_ms: (w[:wait] / 1e6).round(3),
              wake_ms: w[:room] > 0 && w[:pull] > 0 ? ((w[:room] - w[:pull]) / 1e6).round(3) : nil,
              gvl_back_ms: w[:room] > 0 ? ((w[:back] - w[:room]) / 1e6).round(3) : nil,
              queued_ms: ms_frames(w[:queued]),
              limit_ms: ms_frames(w[:limit]),
            }
          }
        end

        # The adaptive queue's backoff state just before the dropout.
        def adapt(d)
          s = d[:ctx][:samples].reverse_each.find { |x| x[:mono] <= d[:gap][:start] && x[:shrink_wait] }
          s && { shrink_wait: s[:shrink_wait], last_adapt: s[:last_adapt] }
        end

        def system_row(g)
          return nil if @rows.empty?

          @rows[(g[:start] + @totals[:offset]) / 1_000_000_000]
        end

        def short_ms(d)
          d[:gap][:short] * 1000.0 / @rate
        end

        def ms_frames(frames)
          (frames.to_i * 1000.0 / @rate).round
        end

        def pct(hist)
          return 'none' if hist.empty?

          q = ->(x) { [hist.percentile(x), hist.max_ns].min / 1e6 }
          format('p50 %.2f p99 %.2f p99.9 %.2f max %.2f ms', q.(0.5), q.(0.99), q.(0.999), hist.max_ns.to_f / 1e6)
        end

        def hist_h(hist)
          return { count: 0 } if hist.empty?

          q = ->(x) { ([hist.percentile(x), hist.max_ns].min / 1e6).round(3) }
          { count: hist.total, p50: q.(0.5), p99: q.(0.99), p999: q.(0.999), max: (hist.max_ns.to_f / 1e6).round(3) }
        end
      end
    end
  end
end
