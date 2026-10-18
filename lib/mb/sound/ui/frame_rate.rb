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

        # Frames per second written to the terminal lately (not the
        # target: frames with no change aren't written).
        def fps
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
          text += " · #{@rates.readout}" if @rates.level > 0
          { fps: f, cpu_ms: cpu, kb_per_s: kbs.round(1), pacing: pace, rates: @rates.to_h, text: text }
        end

        private

        def init_frame_rate(target)
          @target_fps = target
          @written = []
          @written_lock = Mutex.new
          @pacer = Pacer.new(target, clock: @clock)
          @rates = PaneRates.new(target, clock: @clock)
          @render_load = nil
          @pacer.on_frame = ->(f) { @rates.observe(f.paint + f.write, @render_load, f.at) }
        end

        # Which of the panes due this frame draw (UI::PaneRates): +items+
        # are [key, name, pane, explicit rate or nil, drawn_at]; all of
        # them on a +full+ frame.  Returns the keys that draw, and notes
        # the render load from +snap+.
        def panes_to_draw(items, now, full, snap)
          @render_load = snap&.load
          @rates.begin_frame(now)
          cands = items.filter_map do |key, name, pane, explicit, drawn_at|
            pr = PaneRates.priority_of(name, pane)
            next [key, pr, Float::INFINITY] if full || drawn_at.nil?
            next unless @rates.due?(pr, pane.rate, explicit, drawn_at, now)
            [key, pr, (now - drawn_at) * @rates.rate(pr, pane.rate, explicit)]
          end
          full ? cands.map(&:first) : @rates.pick(cands)
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
          @pacer.run(stop) do |now|
            refresh(now)
          rescue => e
            warn "UI painter: #{e.class}: #{e.message}" unless @painter_warned
            @painter_warned = true
            nil
          end
        rescue => e
          warn "UI painter stopped: #{e.class}: #{e.message}"
        end

        # Times a terminal write for the Pacer's breakdown.
        def timed_write
          t = @clock.call
          yield
        ensure
          @pacer.note_write(@clock.call - t)
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
