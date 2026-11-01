module MB
  module Sound
    class DropoutProbe
      # Tells what made one dropout (DropoutProbe; dropout-probe-1): a
      # function of the records around it, so specs can feed it synthetic
      # ones.
      #
      # The device ran dry at the gap's start T.  The writer (the Session's
      # render thread) keeps the queue full by waiting in #write for room,
      # so a dry queue means it spent the window before T (the queue's
      # length plus a buffer) away from that wait for too long.  The window
      # is split into what the render thread was doing then:
      # - waiting in #write for room (not away: the device was slow to make
      #   room, or the queue held enough),
      # - waking after room appeared (os_wake: room until the wait noticed
      #   it; the writer's thread wasn't scheduled),
      # - waiting for the GVL (gvl, by the thread that held it when the
      #   render thread became ready),
      # - blocked off the GVL outside #write (lock: the render lock held by
      #   another thread, a sleep, IO),
      # - running (cpu: rendering, including GC and YJIT compiles it ran
      #   itself),
      # - and the rest (unaccounted: runnable but not running, so the
      #   operating system or the VM didn't run it).
      # GC steps overlapping the window (the render thread's own, inside
      # cpu; other threads', inside its GVL waits) and YJIT compile time
      # (sampled every poll) are taken out of cpu and gvl, and probe
      # episodes (LatencyProbe's thread outside the GVL) mark system stalls.
      module Analysis
        # Causes, in the order reports list them.
        CAUSES = %i[gc render gvl lock system yjit device queue_shrink startup unexplained].freeze

        LABELS = {
          gc: 'GC (a collection stopped the render thread)',
          render: 'render overrun (the render thread was busy rendering)',
          gvl: 'render thread starved (waiting for the GVL)',
          lock: 'render thread blocked (render lock, sleep, or IO)',
          system: 'system stall (the render thread was not running, or the probe saw the machine stall)',
          yjit: 'YJIT compiling',
          device: 'device side (the writer was waiting for room; the device took more than the queue held)',
          queue_shrink: 'queue shrink (the queue before the last shrink would have covered it)',
          startup: 'startup (the first seconds of playback)',
          unexplained: 'unexplained (no part of the window stands out)',
        }.freeze

        # A component must be at least this share of the time away to be the
        # cause.
        DOMINANT = 0.4

        # Probe episodes count as a system stall when their worst stall is
        # at least this share of the time away (the VM's minute stall slows
        # the CPU itself, so the render thread shows as busy).
        SYSTEM_SHARE = 0.25

        # A device pull at least this many seconds (and half the window)
        # after the one before means the device thread itself was stalled.
        DEVICE_LATE = 0.02

        # Dropouts within this many seconds of the first write are :startup.
        STARTUP = 2.0

        # A queue limit lowered within this many seconds before a dropout
        # is a recent shrink.
        SHRINK_RECENT = 30.0

        module_function

        # Overlap in ns of [a, b] with [lo, hi].
        def overlap(a, b, lo, hi)
          return 0 if a.nil? || b.nil? || b <= a

          [[b, hi].min - [a, lo].max, 0].max
        end

        # Classifies a dropout.  +ctx+:
        # - :gap (DropoutProbe::GAP_FIELDS as a Hash; times ns)
        # - :writes (Hashes of DropoutProbe::WRITE_FIELDS, oldest first),
        #   covering the window and a write after it if there was one
        # - :threads (thread log records: Hashes with :thread (slot name),
        #   :holder (name or nil), :a, :b, :c; see FastUI::GVLProbe.log_drain)
        # - :gc (GC steps: Hashes with :thread (name or nil), :a, :b, :major)
        # - :samples (Hashes with :mono and :yjit_ns, cumulative compile ns)
        # - :episodes (probe episodes: Hashes with :start, :duration, :stall ns)
        # - :rate (device frames per second), :buffer (device frames per
        #   write), :first_write (ns), :limit_before (the largest queue
        #   limit in the SHRINK_RECENT s before, device frames), :ended
        #   (true when the writer never wrote again), :startup (seconds
        #   after the first write that count as startup; STARTUP)
        # - :render (the render thread's slot name, default 'render')
        # Returns a Hash: :cause (CAUSES or :idle), :detail (a String),
        # :components (ms), :window_ms, :late_ms (from the gap to the next
        # write), :after_shrink, :episode_ms.
        def classify(ctx)
          gap = ctx.fetch(:gap)
          t = gap[:start]
          rate = ctx.fetch(:rate).to_f
          writes = ctx.fetch(:writes)
          render = ctx[:render] || 'render'

          nxt = writes.find { |w| w[:enter] > t }
          late_ms = nxt ? (nxt[:enter] - t) / 1e6 : nil
          base = { window_ms: 0.0, late_ms: late_ms, after_shrink: false, episode_ms: 0.0, components: {} }

          if nxt.nil? && ctx[:ended]
            return base.merge(cause: :idle, detail: 'the writer stopped writing (the song ended, or the Session stopped)')
          end

          limit = gap[:limit].to_i
          window = ((limit + ctx.fetch(:buffer).to_i) / rate * 1e9).round
          lo = t - window
          hi = t
          base[:window_ms] = window / 1e6

          # Waiting in #write for room: [wait start, room found]
          waits = writes.sum { |w|
            next 0 unless w[:wait].to_i > 0 && w[:room].to_i > 0

            overlap(w[:back] - w[:wait], w[:room], lo, hi)
          }
          inside = writes.find { |w| w[:enter] <= t && t < w[:exit] }
          waiting_at_t = inside && inside[:wait].to_i > 0 && inside[:room].to_i > t && inside[:back] - inside[:wait] <= t
          away = window - waits

          os_wake = writes.sum { |w| w[:pull].to_i > 0 && w[:room].to_i > w[:pull] ? overlap(w[:pull], w[:room], lo, hi) : 0 }

          # The render thread's thread log in the window
          in_write = ->(a, b) { writes.any? { |w| a >= w[:enter] - 100_000 && b <= w[:exit] + 100_000 } }
          gvl = 0
          gvl_by = Hash.new(0)
          blocked = 0
          ctx.fetch(:threads, []).each do |e|
            next unless e[:thread] == render

            if e[:a].to_i > 0 && !in_write.(e[:a], e[:b])
              blocked += overlap(e[:a], e[:b], lo, hi)
            end
            w = overlap(e[:b], e[:c], lo, hi)
            next if w == 0

            gvl += w
            gvl_by[e[:holder] || 'another thread'] += w
          end

          # CPU time of the render thread between writes, scaled by how much
          # of each interval lies in the window
          cpu = 0.0
          writes.each_cons(2) do |w0, w1|
            span = w1[:enter] - w0[:exit]
            next if span <= 0 || w0[:cpu_exit].to_i < 0 || w1[:cpu_enter].to_i < 0

            o = overlap(w0[:exit], w1[:enter], lo, hi)
            next if o == 0

            cpu += (w1[:cpu_enter] - w0[:cpu_exit]) * o.to_f / span
          end
          gc_render = 0
          gc_other = 0
          majors = 0
          longest_gc = 0
          ctx.fetch(:gc, []).each do |g|
            o = overlap(g[:a], g[:b], lo, hi)
            next if o == 0

            g[:thread] == render ? gc_render += o : gc_other += o
            majors += 1 if g[:major]
            longest_gc = [longest_gc, g[:b] - g[:a]].max
          end
          gc_other_in_gvl = [gc_other, gvl].min
          gc = gc_render + gc_other_in_gvl

          yjit = yjit_in(ctx.fetch(:samples, []), lo, hi)
          busy = [cpu - gc_render, 0].max + [gvl - gc_other_in_gvl, 0].max
          yjit = [yjit, busy].min
          render_cpu = [cpu - gc_render, 0].max
          gvl_rest = [gvl - gc_other_in_gvl, 0].max
          # (YJIT's compile time comes out of whichever is larger)
          if render_cpu >= gvl_rest
            render_cpu = [render_cpu - yjit, 0].max
          else
            gvl_rest = [gvl_rest - yjit, 0].max
          end
          unaccounted = [away - os_wake - gvl - blocked - cpu, 0].max
          system = unaccounted + os_wake

          episodes = ctx.fetch(:episodes, []).select { |e| overlap(e[:start], e[:start] + [e[:duration].to_i, 1].max, lo - 50_000_000, hi + 10_000_000) > 0 }
          episode_ns = episodes.map { |e| e[:stall].to_i }.max || 0
          base[:episode_ms] = episode_ns / 1e6

          parts = { gc: gc, render: render_cpu, gvl: gvl_rest, lock: blocked, system: system, yjit: yjit }
          ms = ->(ns) { (ns / 1e6).round(3) }
          base[:components] = {
            away_ms: ms.(away), waiting_ms: ms.(waits), cpu_ms: ms.(cpu), gc_ms: ms.(gc), gc_render_ms: ms.(gc_render), gc_other_ms: ms.(gc_other),
            gc_longest_ms: ms.(longest_gc), gc_majors: majors, gvl_ms: ms.(gvl), gvl_by: gvl_by.transform_values { |v| ms.(v) },
            lock_ms: ms.(blocked), os_wake_ms: ms.(os_wake), unaccounted_ms: ms.(unaccounted), yjit_ms: ms.(yjit), render_ms: ms.(render_cpu),
            system_ms: ms.(system), episode_ms: ms.(episode_ns),
          }

          shrink = ctx[:limit_before].to_i > limit
          base[:after_shrink] = shrink
          covered = shrink && late_ms && (ctx[:limit_before] - limit) / rate * 1000 > late_ms

          # The device thread's own pull came late (the process or the
          # machine stalled, then the device caught up at once)
          late = [gap[:since].to_i, gap[:late].to_i].max
          device_late = late >= [DEVICE_LATE * 1e9, 0.5 * window].max
          base[:device_late_ms] = late / 1e6

          top, top_ns = parts.max_by { |_, v| v }
          cause, detail =
            if ctx[:first_write] && t - ctx[:first_write] < (ctx[:startup] || STARTUP) * 1e9
              [:startup, format('%.2f s after the first write', (t - ctx[:first_write]) / 1e9)]
            elsif device_late && (waiting_at_t || away < 0.5 * window || top == :system)
              [:system, format('the device thread itself was stalled %.1f ms, then caught up (the process or the machine stalled; the probe saw %.1f ms)',
                late / 1e6, episode_ns / 1e6)]
            elsif waiting_at_t || away < 0.5 * window
              [:device, format('the writer was waiting for room (away %.1f of %.1f ms); the device asked %d frames with %d queued (limit %d)',
                away / 1e6, window / 1e6, gap[:frames], gap[:available], limit)]
            elsif covered
              [:queue_shrink, format('the queue went %d -> %d ms; the next write came %.1f ms after the gap (largest part: %s %.1f ms)',
                (ctx[:limit_before] / rate * 1000).round, (limit / rate * 1000).round, late_ms, top, top_ns / 1e6)]
            elsif episode_ns >= SYSTEM_SHARE * away && !%i[gc gvl lock].include?(top)
              [:system, format('a probe episode stalled %.1f ms (the machine itself); render thread cpu %.1f, unaccounted %.1f ms', episode_ns / 1e6, cpu / 1e6, unaccounted / 1e6)]
            elsif top_ns >= DOMINANT * away
              [top, detail_for(top, base[:components], gvl_by, majors, episode_ns)]
            else
              second = parts.reject { |k, _| k == top }.max_by { |_, v| v }
              [:unexplained, format('away %.1f ms: %s %.1f ms, %s %.1f ms', away / 1e6, top, top_ns / 1e6, second[0], second[1] / 1e6)]
            end

          base.merge(cause: cause, detail: detail)
        end

        def detail_for(cause, c, gvl_by, majors, episode_ns)
          case cause
          when :gc
            where = c[:gc_render_ms] >= c[:gc_other_ms] ? 'on the render thread' : 'on another thread (the render thread waited for the GVL)'
            format('%s%.1f ms of GC %s, longest step %.1f ms', majors > 0 ? 'major: ' : 'minor: ', c[:gc_ms], where, c[:gc_longest_ms])
          when :render
            format('render thread cpu %.1f ms of %.1f away', c[:cpu_ms], c[:away_ms])
          when :gvl
            holder, ms = gvl_by.max_by { |_, v| v }
            format('waited %.1f ms for the GVL, mostly held by %s (%.1f ms)', c[:gvl_ms], holder, ms / 1e6)
          when :lock
            format('blocked off the GVL %.1f ms outside #write (the render lock, a sleep, or IO)', c[:lock_ms])
          when :system
            seen = episode_ns > 0 ? format('the probe saw a %.1f ms stall', episode_ns / 1e6) : 'the probe saw nothing (another process, or the scheduler)'
            format('not running %.1f ms (woke %.1f ms late after room); %s', c[:unaccounted_ms], c[:os_wake_ms], seen)
          when :yjit
            format('YJIT compiled %.1f ms', c[:yjit_ms])
          end
        end

        # YJIT compile time (ns) in [lo, hi] from cumulative samples,
        # spread evenly over each sample interval.
        def yjit_in(samples, lo, hi)
          total = 0.0
          samples.each_cons(2) do |s0, s1|
            next unless s0[:yjit_ns] && s1[:yjit_ns]

            d = s1[:yjit_ns] - s0[:yjit_ns]
            span = s1[:mono] - s0[:mono]
            next if d <= 0 || span <= 0

            total += d * overlap(s0[:mono], s1[:mono], lo, hi).to_f / span
          end
          total
        end
      end
    end
  end
end
