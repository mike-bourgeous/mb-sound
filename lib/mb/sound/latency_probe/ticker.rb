module MB
  module Sound
    class LatencyProbe
      # A Ruby thread on the same kind of absolute-deadline loop as the probe
      # (Kernel#sleep to the next deadline), so its lateness includes what the
      # probe thread never sees: waiting for the GVL, GC pauses, YJIT
      # compiling, as well as the system's own stalls.  Comparing the two
      # attributes each stall.
      #
      # The ticker aggregates per wall-clock second (count, max, p50/p99 from
      # a Histogram) and records ticks later than the threshold as events,
      # both handed to the consumer through a Thread::Queue.
      class Ticker
        attr_reader :histogram, :period, :threshold

        # +period+ and +threshold+ in seconds.  +events_per_second+ caps the
        # events recorded per second (the rest are counted).
        def initialize(period:, threshold:, events_per_second: 100, priority: 0)
          @period = period
          @threshold = threshold
          @events_per_second = events_per_second
          @priority = priority
          @queue = Thread::Queue.new
          @histogram = Histogram.new
          @thread = nil
          @stop = false
          @sec = nil
          @sec_hist = nil
          @sec_row = nil
        end

        def start
          @stop = false
          @thread = Thread.new { run }
          @thread.name = 'latency-ticker'
          @thread.priority = @priority
          self
        end

        def stop
          @stop = true
          @thread&.join
          @thread = nil
          self
        end

        def running?
          !!@thread&.alive?
        end

        # Everything queued since the last call: Hashes of kind :ruby_second
        # and :ruby_tick.
        def drain
          out = []
          out << @queue.pop until @queue.empty?
          out
        end

        private

        def run
          clock = Process::CLOCK_MONOTONIC
          period_ns = (@period * 1e9).round
          threshold_ns = (@threshold * 1e9).round
          target = Process.clock_gettime(clock, :nanosecond) + period_ns

          until @stop
            now = Process.clock_gettime(clock, :nanosecond)
            wait = target - now
            sleep(wait / 1e9) if wait > 0

            wake = Process.clock_gettime(clock, :nanosecond)
            wall = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
            late = wake - target
            late = 0 if late < 0
            record(wall, late, threshold_ns)

            target += period_ns
            now = Process.clock_gettime(clock, :nanosecond)
            if now >= target
              missed = (now - target) / period_ns + 1
              target += missed * period_ns
              @sec_row[:missed] += missed
            end
          end

          finish_second
        end

        def record(wall, late, threshold_ns)
          sec = wall / 1_000_000_000
          if sec != @sec
            finish_second
            @sec = sec
            @sec_hist = Histogram.new
            @sec_row = { kind: :ruby_second, second: sec, ticks: 0, missed: 0, over: 0, events: 0, dropped: 0, late_max_ns: 0 }
          end

          @histogram.add(late)
          @sec_hist.add(late)
          row = @sec_row
          row[:ticks] += 1
          row[:late_max_ns] = late if late > row[:late_max_ns]
          return unless late > threshold_ns

          row[:over] += 1
          if row[:events] < @events_per_second
            row[:events] += 1
            @queue << { kind: :ruby_tick, wall_ns: wall, late_ns: late }
          else
            row[:dropped] += 1
          end
        end

        def finish_second
          return unless @sec_row

          @sec_row[:late_p50_ns] = @sec_hist.percentile(0.5)
          @sec_row[:late_p99_ns] = @sec_hist.percentile(0.99)
          @queue << @sec_row
          @sec_row = nil
          @sec = nil
        end
      end

      # Logs a Session's buffers into the probe's timeline through a mix tap
      # (Session#add_tap, on the render thread): per wall second the number
      # of buffers, the slowest render (Session#render_load) and the longest
      # gap between buffers, underruns (outputs with #underruns, e.g.
      # DeviceOutput), and events for slow buffers (render over +slow+ of
      # the buffer's duration), late buffers (a gap over twice the buffer's
      # duration plus the threshold), and each new underrun.
      class SessionWatch
        attr_reader :session

        def initialize(session, threshold:, slow: 0.8)
          @session = session
          @threshold_ns = (threshold * 1e9).round
          @slow = slow
          @queue = Thread::Queue.new
          @last = nil
          @underruns = nil
          @sec = nil
          @row = nil
          @tap = nil
          @lock = Mutex.new
        end

        def start
          @tap = @session.add_tap { |mix| @lock.synchronize { buffer(mix) } }
          self
        end

        def stop
          @session.remove_tap(@tap) if @tap
          @tap = nil
          @lock.synchronize { finish_second }
          self
        end

        def drain
          out = []
          out << @queue.pop until @queue.empty?
          out
        end

        private

        def buffer(mix)
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
          wall = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
          frames = mix[0]&.length || 0
          rate = @session.sample_rate.to_f
          duration_ns = frames > 0 ? (frames * 1e9 / rate).round : 0
          load = @session.render_load
          render_ns = load ? (load * duration_ns).round : 0
          gap_ns = @last ? now - @last : 0
          @last = now

          output = @session.output
          underruns = output.respond_to?(:underruns) ? output.underruns.to_i : nil
          new_underruns = underruns && @underruns ? underruns - @underruns : 0
          @underruns = underruns

          sec = wall / 1_000_000_000
          if sec != @sec
            finish_second
            @sec = sec
            @row = { kind: :session_second, second: sec, buffers: 0, render_max_ns: 0, gap_max_ns: 0, underruns: 0, slow: 0 }
          end
          r = @row
          r[:buffers] += 1
          r[:render_max_ns] = render_ns if render_ns > r[:render_max_ns]
          r[:gap_max_ns] = gap_ns if gap_ns > r[:gap_max_ns]
          r[:underruns] += new_underruns if new_underruns > 0

          if duration_ns > 0 && render_ns > @slow * duration_ns
            r[:slow] += 1
            @queue << { kind: :session_slow, wall_ns: wall, render_ns: render_ns, buffer_ns: duration_ns }
          end
          if duration_ns > 0 && gap_ns > 2 * duration_ns + @threshold_ns
            @queue << { kind: :session_gap, wall_ns: wall, gap_ns: gap_ns, buffer_ns: duration_ns }
          end
          @queue << { kind: :underrun, wall_ns: wall, count: new_underruns } if new_underruns > 0
        end

        def finish_second
          return unless @row

          @queue << @row
          @row = nil
          @sec = nil
        end
      end
    end
  end
end
