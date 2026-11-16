module MB
  module Sound
    module UI
      # Measured frame rate for a screen (Band, Tiles; ux-1 item 12: `ui.fps`
      # returned the target, so "I don't know if that's display fps or
      # target fps"): #fps is frames written per second over the last
      # WINDOW seconds, #target_fps the painter's rate (settable), and
      # #frame_rate a readout with the painter's CPU per frame and the
      # bytes per second.  Uses @target_fps and @written (set by the
      # screen's constructor through #init_frame_rate).
      module FrameRate
        # Seconds of written frames #fps counts.
        WINDOW = 2.0

        class << self
          # ui-perf-1 (an option, off by default): the painter times its
          # frames to the render thread's snapshots (UI::Pacer#timing,
          # SnapshotTiming), for screens made after it is set.
          # MB_SOUND_UI_SNAPSHOT_TIMED=1 turns it on at start.
          attr_accessor :snapshot_timed
        end
        self.snapshot_timed = ENV['MB_SOUND_UI_SNAPSHOT_TIMED'] == '1' || ENV['MB_SOUND_UI_SMOOTH'] == '1'

        # When the newest snapshot's data becomes visible, for
        # Pacer#timing, read on the painter thread from the Feed's newest
        # snapshot alone (the render thread does nothing more): snapshots
        # are published at the end of each buffer (with Feed.every_buffer;
        # else every other one), so the next comes about a buffer after
        # the newest, and with an output latency they become visible
        # (Follow#heard) that much later; the times of the last snapshots
        # seen are kept, so a heard time is exact rather than predicted.
        # Buffers shorter than MIN_SHARE of a frame period time nothing:
        # every frame on the grid has a new snapshot then.  Allocates
        # nothing.
        class SnapshotTiming
          MIN_SHARE = 0.5

          # Snapshot times kept (for heard times under output latency).
          KEEP = 8

          # Seconds without a snapshot after which frames keep the grid (a
          # paused or stopped render thread).
          STALE = 0.1

          # +feed+ a Proc returning the screen's Feed; +pacer+ its Pacer.
          def initialize(feed, pacer)
            @feed = feed
            @pacer = pacer
            @seq = nil
            @times = Array.new(KEEP, -Float::INFINITY)
            @pos = 0
            @last_seq = nil
            @exact = false
          end

          # At each frame's start: notes the newest snapshot.
          def mark
            s = @feed.call&.latest
            @seq = s&.seq
            note(s)
          end

          # The time at or after +time+ when new data becomes visible, or
          # nil (no snapshots, stale ones, or short buffers).
          def next_after(time)
            s = @feed.call&.latest or return nil
            note(s)
            buf = s.buffer_size.to_f / s.sample_rate
            return nil if buf < MIN_SHARE * @pacer.period || time - s.time > STALE + buf
            lat = s.latency.to_f
            # (a kept snapshot heard at or after +time+: exact)
            best = nil
            i = 0
            while i < KEEP
              h = @times[i] + lat
              best = h if h >= time && (best.nil? || h < best)
              i += 1
            end
            @exact = !best.nil?
            return best if best
            base = s.time + lat
            base + ((time - base) / buf).ceil * buf
          end

          # True when the data #next_after named has arrived: a kept
          # snapshot's heard time, or a snapshot newer than the frame's.
          def arrived?
            return true if @exact
            s = @feed.call&.latest
            !s.nil? && s.seq != @seq
          end

          private

          def note(s)
            return if s.nil? || s.seq == @last_seq
            @last_seq = s.seq
            @times[@pos] = s.time
            @pos = (@pos + 1) % KEEP
          end
        end

        # Frames per second the painter ran lately: its refreshes over the
        # last WINDOW seconds, the first number of the status line's
        # readout (NAV f, "60/60 Hz"; ui-api-1: `ui.fps` counted written
        # frames, which skip frames with no change, so it read 48.5 while
        # the painter ran 60).  See #written_fps.
        def fps
          r = @pacer.breakdown(window: WINDOW)[:refreshes]
          r > 0 ? r : written_fps
        end

        # Frames per second written to the terminal lately (frames with no
        # change aren't written).
        def written_fps
          times = @written_lock.synchronize { @written.map(&:first) }
          return 0.0 if times.empty?
          now = @clock.call
          recent = times.count { |t| t > now - WINDOW }
          (recent / WINDOW).round(1)
        end

        # The painter's target rate (refreshes per second).
        attr_reader :target_fps

        # Sets the painter's target rate (1..240).
        def target_fps=(rate)
          raise ArgumentError, "target_fps is a rate from 1 to 240 (got #{rate.inspect})" unless rate.is_a?(Numeric) && rate >= 1 && rate <= 240
          @target_fps = rate
          @pacer.fps = rate
          @rates.fps = rate
        end

        # The painter's pacing (UI::Pacer): deadlines, and each frame's
        # paint, write, and wait times.
        attr_reader :pacer

        # The panes' adaptive rates (UI::PaneRates): live panes at the
        # target rate, slowing in steps under load.
        attr_reader :rates

        # fps (frames written), the painter's CPU per frame (p50 ms), kB/s
        # written, and the pacing breakdown (UI::Pacer#breakdown: refreshes
        # against the target, paint, write, and wait times), as a Hash and
        # as text ("60/60 Hz · 30 written · paint 0.4 write 0.1 wait
        # 15.9+0.1 ms · 18 kB/s").  Written frames top out near the fastest
        # visible pane's rate (meters and scopes: 30/s): nothing changes
        # between its draws.
        def frame_rate
          now = @clock.call
          rows = @written_lock.synchronize { @written.select { |t, _| t > now - WINDOW } }
          kbs = rows.sum { |_, b| b } / WINDOW / 1000.0
          cpu = UI.percentiles(@frames.last(120).map { |f| f[0] * 1000 })[:p50] || 0
          f = (rows.length / WINDOW).round
          pace = @pacer.breakdown(window: WINDOW)
          text = pace[:refreshes] > 0 ? "#{@pacer.readout(window: WINDOW)} · #{kbs.round} kB/s" : "#{f} fps · #{format('%.1f', cpu)} ms · #{kbs.round} kB/s"
          # (the live panes' redraws, when the slowest is under the painter's
          # rate: the painter ran 60/60 Hz while the envelope preview drew
          # 9.5 times a second, rates level 3; inspector-nav-1, the
          # maintainer: "the UI heading says it's at 60fps")
          slow = slowest_live_pane(now)
          if slow && slow[1] < @target_fps * 0.9
            note = " (#{slow[0]} #{slow[1] >= 10 ? slow[1].round : slow[1]}/s)"
            text = text.include?(' Hz') ? text.sub(' Hz', " Hz#{note}") : text.sub(' fps', " fps#{note}")
          end
          text += " · #{@rates.readout}" if @rates.level > 0
          { fps: f, cpu_ms: cpu, kb_per_s: kbs.round(1), pacing: pace, rates: @rates.to_h, live_panes: slow && { name: slow[0], fps: slow[1] }, text: text }
        end

        # The UI::Perf recording this screen's frames (`ui.perf`), or nil.
        def perf = @pacer.perf

        # Starts recording frames into a new UI::Perf (replacing one that
        # runs); options as for Perf.new (+ack:+ defaults to the screen's
        # #perf_ack).  Returns it.
        def start_perf(**opts)
          stop_perf
          p = Perf.new(clock: @clock, ack: perf_ack, **opts)
          perf_identify(p)
          @pacer.perf = p
          @rates.perf = p
          p
        end

        # Stops recording; returns the UI::Perf (kept for its report), or
        # nil.
        def stop_perf
          p = @pacer.perf
          @pacer.perf = nil
          @rates.perf = nil
          p&.stop
        end

        private

        # The terminal query kind ui.perf uses on this screen (nil: none,
        # the band's input is Reline's).
        def perf_ack = nil

        # Fills in the terminal's identity (screens with a terminal of
        # their own also ask it).
        def perf_identify(p)
          p.identify(size: [@rows, @cols])
        end

        # [name, measured redraws/s] of the slowest visible pane that wants
        # the painter's rate (meters and live panes, UI::PaneRates), or nil
        # (screens without per-pane draws: #live_panes is theirs).
        def slowest_live_pane(now)
          names = respond_to?(:live_panes, true) ? live_panes : nil
          return nil if names.nil? || names.empty?
          m = @rates.measured(now)
          names.map { |n| [n, m[n] || 0.0] }.min_by(&:last)
        end

        def init_frame_rate(target)
          @target_fps = target
          @written = []
          @written_lock = Mutex.new
          @pacer = Pacer.new(target, clock: @clock)
          @rates = PaneRates.new(target, clock: @clock)
          @render_load = nil
          @pacer.on_frame = ->(f) { @rates.observe(f.paint + f.write, @render_load, f.at) }
          apply_timing
        end

        public

        # Times frames to snapshots or not, as FrameRate.snapshot_timed says
        # now (at start, and from `ui.smooth` while the screen runs).
        def apply_timing
          if FrameRate.snapshot_timed
            @pacer.timing ||= SnapshotTiming.new(-> { @feed }, @pacer)
            # (timed frames come up to the window early: panes at the
            # painter's rate stay due on each of them)
            @rates.slack = Pacer::TIMING_WINDOW
          else
            @pacer.timing = nil
            @rates.slack = 0.0
          end
          nil
        end

        private

        # Which of the panes due this frame draw (UI::PaneRates): +items+
        # are [key, name, pane, explicit rate or nil, drawn_at]; all of
        # them on a +full+ frame.  Returns the keys that draw, and notes
        # the render load from +snap+.
        def panes_to_draw(items, now, full, snap)
          @render_load = snap&.load
          @rates.begin_frame(now)
          # (reused Arrays, no per-pane candidate Arrays: the painter's
          # steady state allocates nothing here; ui-perf-1.  The keys come
          # back in no particular order: callers ask include?)
          out = (@draw_keys ||= [])
          keys = (@cand_keys ||= [])
          lates = (@cand_lates ||= [])
          out.clear
          keys.clear
          lates.clear
          items.each do |key, name, pane, explicit, drawn_at|
            pr = PaneRates.priority_of(name, pane)
            if full || (pr == :meter && (drawn_at.nil? || @rates.due?(pr, pane.rate, explicit, drawn_at, now)))
              out << key
            elsif drawn_at.nil?
              keys << key
              lates << Float::INFINITY
            elsif pr != :meter && @rates.due?(pr, pane.rate, explicit, drawn_at, now)
              keys << key
              lates << (now - drawn_at) * @rates.rate(pr, pane.rate, explicit)
            end
          end
          @rates.pick_into(out, keys, lates)
          out
        end

        # A pane's rate for NAV f's badges: measured redraws per second
        # ("60/s").
        def rate_text(name, now = @clock.call)
          r = @rates.measured(now)[name] || 0
          "#{r >= 10 ? r.round : r}/s"
        end

        # The painter thread's loop: frames on the Pacer's deadlines until
        # +stop+ (a Proc) is true, a failing refresh warned once.
        def paced_loop(stop)
          Thread.current.name = 'MB::Sound::UI'
          Thread.current.priority = -1
          # (a live thread: code it calls takes cached data rather than
          # reading files, e.g. Library::Index#document_entries)
          Thread.current[:mb_sound_live] = true
          @pacer.run(stop) do |now|
            yield_to_render
            refresh(now)
          rescue => e
            warn "UI painter: #{e.class}: #{e.message}" unless @painter_warned
            @painter_warned = true
            nil
          end
        rescue => e
          warn "UI painter stopped: #{e.class}: #{e.message}"
        ensure
          stop_yielding
        end

        # The painter (and, on the tiled screen, its input thread) hand the
        # GVL to the followed Session's render thread whenever that wakes
        # (UI::Yielding, Yielding.painter; ui-perf-2): a pane draw otherwise
        # kept the render thread waiting up to Ruby's 10 ms timeslice.
        # Joins when the render thread is first known or changes (a new
        # Session), on the painter thread before each frame: two ivar reads
        # and a comparison when nothing changed, no allocation.
        def yield_to_render
          return unless Yielding.painter
          t = @attached&.render_thread
          t = nil unless t&.alive?
          return if t.equal?(@yield_render)
          @yield_render = t
          input = Yielding.input && defined?(@reader) ? @reader : nil
          if t
            Yielding.join(Thread.current, render: t)
            Yielding.join(input, render: t) if input
          else
            stop_yielding
          end
        end

        # The painter and input threads stop yielding (the painter's loop
        # ended, or no render thread to follow).
        def stop_yielding
          @yield_render = nil
          Yielding.leave(Thread.current)
          Yielding.leave(@reader) if defined?(@reader) && @reader
        end

        # Times a terminal write for the Pacer's breakdown.
        def timed_write
          t = @clock.call
          yield
        ensure
          t1 = @clock.call
          @pacer.note_write(t1 - t)
          @pacer.perf&.wrote(t, t1)
        end

        # Notes a frame of +bytes+ written at +now+.
        def note_written(now, bytes)
          @written_lock.synchronize do
            @written << [now, bytes]
            @written.shift while @written.length > 1 && @written[0][0] < now - WINDOW
          end
        end
      end
    end
  end
end
