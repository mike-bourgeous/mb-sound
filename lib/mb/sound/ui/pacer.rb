module MB
  module Sound
    module UI
      # The painters' frame pacing (ux-1 r3 item 23), as an explicit state
      # machine with deadlines: each refresh is due at the previous
      # deadline plus one period (not "a period after the work"), a frame
      # that ran past its deadline skips the deadlines it missed instead of
      # rushing to catch up, and every frame's time is split into paint,
      # write, and wait (sleep asked for, and the oversleep: the scheduler,
      # timer slack, and waiting for the GVL to run again).
      #
      # Measured before this (2026-10-17, container, :wall 200x60): the old
      # loop already ran 59.7 refreshes/s at a 60 target and 231 at 240;
      # `ui.fps` counts frames *written*, and nothing changes between a
      # 30/s pane's draws, so written frames top out near the fastest
      # visible pane's rate (30/s for meters and scopes) whatever the
      # target.  #readout shows both.
      #
      # ui-api-1 (maintainer, 2026-10-18: measured fps fell short of the
      # target "when it's capable of more"; "there could be adaptive pacing
      # so that deadlines are adjusted until the target fps is hit"):
      # - a frame that ends past the next deadline but less than a whole
      #   period late starts at once (catching up); only frames more than
      #   a period late skip deadlines (one long frame used to cost a
      #   frame each time: "15 missed" at 240);
      # - the wake offset: the painter asks to wake +offset+ before each
      #   deadline, +offset+ following how late wakes land (a small gain per
      #   frame, at most half a period), so timer slack and wake latency
      #   don't make every frame start late;
      # - the rate trim: over windows of about ADAPT_SECONDS the measured
      #   refresh rate is compared with the target and the deadline spacing
      #   shortened by +trim+ (at most MAX_TRIM of a period) while it falls
      #   short, released when it overshoots; both reset when the target
      #   changes.  Frames never come faster than their work allows.
      # - KEEP holds 2.5 s at 240/s (it held 240 frames, so the 2 s readout
      #   showed "120/240 Hz" at a 240 target).
      #
      #     pacer = Pacer.new(60, clock: -> { MB::U.clock_now })
      #     pacer.run(-> { @stopping }) { |now| refresh(now) }
      class Pacer
        # States and the events that leave them: [state, event] => state.
        # Every pair not listed is a bug (Pacer::StateError), so the spec
        # walks every (state, event) pair.
        TRANSITIONS = {
          [:idle, :start] => :due,
          [:due, :paint] => :painting,
          [:due, :stop] => :stopped,
          [:painting, :painted] => :waiting,
          [:painting, :stop] => :stopped,
          [:waiting, :woke] => :due,
          [:waiting, :stop] => :stopped,
          [:stopped, :start] => :due,
        }.freeze

        # TRANSITIONS by state, then event (looked up without a key Array).
        NEXT = TRANSITIONS.each_with_object({}) { |((s, e), t), h| (h[s] ||= {})[e] = t }.transform_values(&:freeze).freeze

        STATES = TRANSITIONS.flat_map { |(s, _), t| [s, t] }.uniq.freeze
        EVENTS = TRANSITIONS.keys.map(&:last).uniq.freeze

        # An event that isn't allowed in the current state.
        class StateError < StandardError; end

        # One frame's timing, in seconds: +paint+ (the refresh but its
        # write), +write+, +sleep+ (asked for), +slept+ (actual), +late+
        # (how far past its deadline the frame started), +skipped+
        # (deadlines missed before it), +wrote+ (bytes, 0 for none), +hold+
        # (seconds the write waited for #min_gap, not in +paint+).
        Frame = Data.define(:at, :paint, :write, :sleep, :slept, :late, :skipped, :wrote, :hold) do
          def initialize(hold: 0.0, **rest) = super
        end

        # Frames kept for #breakdown (2.5 s at 240/s).
        KEEP = 600

        # Seconds per rate-trim window, the trim's gain (of the relative
        # rate error, per window), and its bound (a share of the period).
        ADAPT_SECONDS = 1.0
        TRIM_GAIN = 0.5
        MAX_TRIM = 0.1

        # The wake offset's gain per frame and bound (a share of the period).
        OFFSET_GAIN = 0.1
        MAX_OFFSET = 0.5

        # Seconds short of the sleep asked for that count as woken early
        # (Thread#wakeup) rather than a timer firing a little early.
        WOKEN_EARLY = 0.001

        # Frames timed to new data (#timing): the share of a period a
        # frame may move from its deadline to meet the data, the seconds
        # after the data's predicted time the painter wakes, and the
        # seconds between looks while the data is late.
        TIMING_WINDOW = 0.25
        TIMING_MARGIN = 0.0003
        TIMING_POLL = 0.0005

        attr_reader :state, :period, :deadline, :skipped

        # ui-perf-1 (an option, off by default; FrameRate.snapshot_timed):
        # an object timing frames to new data (FrameRate::SnapshotTiming:
        # #mark at each frame's start, #next_after(time) the time new data
        # becomes visible at or after +time+ or nil, #arrived? whether it
        # has).  A frame whose next deadline is within TIMING_WINDOW of a
        # period of new data moves to the data's time (then waits for it to
        # arrive, at most to the window's end), and the deadlines follow
        # from there; otherwise frames keep the deadline grid.  Without it
        # the painter's 60 Hz and 800-frame buffers (also 60 a second) beat:
        # a frame just before a buffer's snapshot shows the old one, and
        # the scope's visible updates come 33 ms apart now and then.
        attr_accessor :timing

        # Seconds the deadline spacing is shortened by (the rate trim), and
        # seconds before each deadline the painter asks to wake (the wake
        # offset).
        attr_reader :trim, :offset

        # Called with each Frame after it (UI::PaneRates#observe).
        attr_accessor :on_frame

        # konsole-pacing (2026-11-21; `ui.pace :terminal`, the default since
        # pace-default-1): the least seconds between frame writes, or nil
        # (terminals with no such rule).  Konsole before 26.04 shows output
        # only 10 ms after it stops arriving (at the latest 40 ms after it
        # starts), so frames written closer than that show at about 25 a
        # second; with a gap the deadlines are at least this far apart, a
        # woken frame without room waits for its deadline (#defer_wake?),
        # and a write that would still come too soon waits for the gap
        # (#hold_before_write), so every frame shows.  See TerminalProfile.
        attr_accessor :min_gap

        # A UI::Perf recording frames (`ui.perf`), or nil.
        attr_accessor :perf

        # +fps+ the target rate; +clock+ a Proc of seconds; +sleeper+ a
        # Proc that sleeps (fake clocks advance their time there).
        def initialize(fps, clock:, sleeper: ->(s) { sleep(s) })
          @clock = clock
          @sleeper = sleeper
          @state = :idle
          @frames = []
          @skipped = 0
          @deadline = nil
          @write = 0.0
          @lock = Mutex.new
          @on_frame = nil
          @perf = nil
          @trim = 0.0
          @offset = 0.0
          @window_at = nil
          @window_frames = 0
          @woken = false
          @timing = nil
          @min_gap = nil
          @hold = 0.0
          @last_write = nil
          @write_gap_min = nil
          @close_writes = 0
          @gap_writes = 0
          self.fps = fps
        end

        # Changes the target rate (from the next frame), resetting the rate
        # trim and the wake offset.
        def fps=(fps)
          @period = 1.0 / fps
          @trim = 0.0
          @offset = 0.0
          @window_at = nil
          @window_frames = 0
        end

        # Applies +event+, raising StateError for a pair the table lacks.
        def event!(event)
          to = NEXT[@state]&.[](event) or raise StateError, "Pacer: #{event.inspect} in #{@state.inspect}"
          @state = to
        end

        # The screen's write calls this with the seconds a write took (so
        # the frame's time splits into paint and write).
        def note_write(seconds)
          @write += seconds
        end

        # Before a frame's write (the screen's timed write): waits until
        # #min_gap has passed since the last write ended, and notes the
        # wait as the frame's hold.  Nothing without a gap.
        # (the sleep can end early, a key's Thread#wakeup: it waits again
        # until the gap has passed.)  Each write's gap since the last one,
        # on this clock, goes into #write_gaps.
        def hold_before_write
          g = @min_gap or return
          return unless @last_write
          t0 = @clock.call
          now = t0
          while (w = @last_write + g - now) > 0
            @sleeper.call(w)
            now = @clock.call
          end
          @hold += now - t0
          gap = now - @last_write
          @write_gap_min = gap if @write_gap_min.nil? || gap < @write_gap_min
          @close_writes += 1 if gap < g - 1e-9 # (float rounding of a wait that ended on the gap)
          @gap_writes += 1
        end

        # The writer's own record of the gaps #hold_before_write kept
        # (pace-default-1): writes checked, the shortest gap from a write's
        # end to the next write's start in ms (nil before two writes), and
        # writes closer than #min_gap (0 by construction: the property the
        # bench reports, read on the painter's clock rather than from a
        # model terminal's stamps, which a busy machine delays).
        def write_gaps
          { writes: @gap_writes, min_ms: @write_gap_min && (@write_gap_min * 1000).round(3), under_gap: @close_writes }
        end

        # The screen's timed write ended at +t+ (for #min_gap).
        def wrote_at(t)
          @last_write = t
        end

        # Runs frames until +stop+ (a Proc) is true: yields the frame's
        # start time to the block (the refresh; its result: bytes written
        # or nil), then sleeps until the next deadline.
        def run(stop)
          event!(:start)
          @deadline = @clock.call
          until stop.call
            frame { |now| yield now }
          end
        ensure
          event!(:stop) unless @state == :stopped || @state == :idle
        end

        # One frame (see #run): paints, then waits for the next deadline.
        # Returns the Frame.
        def frame
          event!(:paint)
          start = @clock.call
          late = [start - @deadline, 0.0].max
          @write = 0.0
          @hold = 0.0
          @perf&.begin_frame(start)
          @timing&.mark
          out = yield start
          done = @clock.call
          event!(:painted)

          # The next deadline: one (trimmed) period on; a frame that ended
          # less than a period past it starts at once, and only the
          # deadlines a frame overran by more than a whole period are skipped
          step = @period - @trim
          gs = gap_step
          step = gs if gs && step < gs
          # (a frame woken before its deadline, by a key, leaves that
          # deadline for the next frame: ui-perf-1, a woken frame used to
          # push the next one a whole period past the deadline it slept
          # toward)
          nxt = @woken && done < @deadline ? @deadline : @deadline + step
          missed = 0
          if done > nxt + step
            missed = ((done - nxt) / step).floor
            nxt += missed * step
          end
          @skipped += missed
          # (timed to new data: the deadline moves to the data's time when
          # that is within the window, without the wake offset)
          timed = false
          limit = nil
          if @timing && missed == 0
            win = TIMING_WINDOW * @period
            t = @timing.next_after(nxt - win)
            if t && t <= nxt + win
              limit = nxt + win
              nxt = t + TIMING_MARGIN
              timed = true
            end
          end
          @deadline = nxt
          want = nxt - (timed ? 0.0 : @offset) - done
          @sleeper.call(want) if want > 0
          woke = @clock.call
          # (woken early: Thread#wakeup ended the sleep before its time)
          @woken = want > 0 && woke - done < want - WOKEN_EARLY
          # (pace-default-1: with #min_gap a woken frame that has no room
          # waits for the deadline it slept toward, see #defer_wake?)
          while @woken && defer_wake?(woke, nxt)
            rest = nxt - (timed ? 0.0 : @offset) - woke
            if rest <= 0
              @woken = false
              break
            end
            @sleeper.call(rest)
            t = @clock.call
            @woken = t - woke < rest - WOKEN_EARLY
            woke = t
          end
          slept = woke - done
          if timed && !@woken
            # (the data late: look again until it comes or the window ends;
            # the frame's deadline is then when it starts, so the next
            # deadline follows the data)
            @sleeper.call(TIMING_POLL) until @timing.arrived? || @clock.call >= limit
            woke = @clock.call
            slept = woke - done
            @deadline = woke
          end
          adapt(woke, @woken || timed ? 0.0 : want)
          event!(:woke)
          f = Frame.new(at: start, paint: done - start - @write - @hold, write: @write, sleep: want, slept: slept, late: late, skipped: missed,
                        wrote: out.is_a?(String) ? out.bytesize : 0, hold: @hold)
          @lock.synchronize do
            @frames << f
            @frames.shift if @frames.length > KEEP
          end
          @on_frame&.call(f)
          @perf&.end_frame(f)
          f
        end

        # The deadline spacing #min_gap asks for when the target's period
        # is shorter (nil otherwise): the smallest whole number of target
        # periods at least the gap, when that is within GRID_SLACK gaps,
        # else the gap.  (pace-default-1, 2026-11-21: spaced by the bare
        # 12 ms gap, about 83 frames a second, the painter beat against
        # the feed's 60 snapshots a second with `ui.smooth :off` and caught
        # only 47 of them at target 120, against 57 shown with :exact;
        # two periods, 16.7 ms, catch 59, and with smooth on show 59 even
        # updates (shown gaps p95 17 ms) instead of 70 at p95 24 ms.  So
        # 120 and 180 pace at 60, 240 at 80, 144 at 72; 90, 100 and 110,
        # whose two periods are over 18 ms, at the gap.)
        GRID_SLACK = 1.5

        def gap_step
          g = @min_gap
          return nil unless g && @period < g
          s = (g / @period).ceil * @period
          s <= GRID_SLACK * g ? s : g
        end

        # True when a frame woken at +t+ (a key, the REPL's echo) should
        # wait for the deadline +nxt+ it slept toward instead of starting
        # now: with #min_gap, when its write would come closer than the gap
        # after the last write, or the deadline's frame closer than the gap
        # after it.  (pace-default-1, 2026-11-21: the woken frame used to
        # start at once and hold its write for the gap, which then held the
        # deadline's frame, moving it off the grid: with `ui.smooth :on`
        # while typing at 60 the scope's shown gaps p95 rose 20.9 -> 37.5
        # ms.  Now the deadline's frame shows the key; at 60 with a 12 ms
        # gap no woken frame has room, at 30 one does.)
        private def defer_wake?(t, nxt)
          g = @min_gap or return false
          (@last_write && t < @last_write + g) || nxt - t < g
        end

        # The wake offset follows where wakes land (a wake +late+ past its
        # deadline asks earlier next time; early, later), and once per
        # ADAPT_SECONDS the rate trim follows the measured refresh rate.
        private def adapt(woke, want)
          if want > 0
            late = woke - @deadline
            @offset = (@offset + OFFSET_GAIN * late).clamp(0.0, MAX_OFFSET * @period)
          end

          @window_at ||= woke
          @window_frames += 1
          span = woke - @window_at
          return if span < ADAPT_SECONDS

          measured = @window_frames / span
          # (seconds per frame too long, positive when short of the target;
          # the target is the gap's spacing when #min_gap is the longer)
          err = 1.0 / measured - (gap_step || @period)
          @trim = (@trim + TRIM_GAIN * err).clamp(0.0, MAX_TRIM * @period)
          @window_at = woke
          @window_frames = 0
        end

        # Ends the frames (#run does this when its stop Proc says so).
        def stop
          event!(:stop) unless @state == :stopped || @state == :idle
        end

        # The last frames' timing over +window+ seconds: refreshes per
        # second, written frames per second, and p50/p99/max milliseconds
        # of paint, write, sleep asked, oversleep, and lateness, skipped
        # deadlines, and the longest gap between frame starts.
        def breakdown(window: 2.0)
          now = @clock.call
          fs = @lock.synchronize { @frames.select { |f| f.at > now - window } }
          ms = ->(list) { UI.percentiles(list.map { |v| v * 1000 }) }
          {
            target: (1.0 / @period).round(1),
            refreshes: (fs.length / window).round(1),
            written: (fs.count { |f| f.wrote > 0 } / window).round(1),
            paint_ms: ms.(fs.map(&:paint)),
            write_ms: ms.(fs.map(&:write)),
            hold_ms: ms.(fs.map(&:hold)),
            sleep_ms: ms.(fs.map(&:sleep)),
            oversleep_ms: ms.(fs.map { |f| f.slept - f.sleep }),
            late_ms: ms.(fs.map(&:late)),
            skipped: fs.sum(&:skipped),
            # (ui-perf-1: the longest time between two frames' starts in
            # the window, the stall a steady rate can hide)
            gap_ms: fs.each_cons(2).map { |a, b| (b.at - a.at) * 1000 }.max&.then { |v| MB::M.sigfigs(v, 3) },
          }
        end

        # The breakdown as one line for the status bar (NAV f): refreshes
        # against the target, frames written, where a frame's time went
        # (p50s), and the window's p99 lateness and longest gap between
        # frames when they hitch (ui-perf-1: smooth is p99 and gaps, not
        # means; #hitches decides, so steady frames keep the line short).
        def readout(window: 2.0)
          b = breakdown(window: window)
          f = ->(v) { v.nil? ? '-' : format('%.1f', v) }
          "#{b[:refreshes].round}/#{b[:target].round} Hz · #{b[:written].round} written · paint #{f.(b[:paint_ms][:p50])} write #{f.(b[:write_ms][:p50])} " \
            "wait #{f.(b[:sleep_ms][:p50])}+#{f.(b[:oversleep_ms][:p50])} ms" \
            "#{hitches(b) ? " · late p99 #{f.(b[:late_ms][:p99])} / stall #{b[:gap_ms]&.round || '-'} ms" : ''}" \
            "#{b[:skipped] > 0 ? " · #{b[:skipped]} missed" : ''}"
        end

        # True when a #breakdown's frames hitch: p99 lateness over half a
        # frame period, or a gap between frame starts over two periods.
        def hitches(b = breakdown)
          period_ms = @period * 1000
          late = b[:late_ms][:p99]
          gap = b[:gap_ms]
          (!late.nil? && late > period_ms / 2) || (!gap.nil? && gap > period_ms * 2)
        end

        # The transition table as text lines (for the spec and help).
        def self.table
          TRANSITIONS.map { |(s, e), t| "#{s.to_s.ljust(9)} --#{e}--> #{t}" }
        end
      end
    end
  end
end
