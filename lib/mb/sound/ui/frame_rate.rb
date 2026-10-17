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
        end

        # fps, the painter's CPU per frame (p50 ms), and kB/s written, as a
        # Hash and as text ("42 fps · 0.3 ms · 18 kB/s").
        def frame_rate
          now = @clock.call
          rows = @written_lock.synchronize { @written.select { |t, _| t > now - WINDOW } }
          kbs = rows.sum { |_, b| b } / WINDOW / 1000.0
          cpu = UI.percentiles(@frames.last(120).map { |f| f[0] * 1000 })[:p50] || 0
          f = (rows.length / WINDOW).round
          { fps: f, cpu_ms: cpu, kb_per_s: kbs.round(1), text: "#{f} fps · #{format('%.1f', cpu)} ms · #{kbs.round} kB/s" }
        end

        private

        def init_frame_rate(target)
          @target_fps = target
          @written = []
          @written_lock = Mutex.new
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
