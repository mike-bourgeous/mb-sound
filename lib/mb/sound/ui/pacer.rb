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

        STATES = TRANSITIONS.flat_map { |(s, _), t| [s, t] }.uniq.freeze
        EVENTS = TRANSITIONS.keys.map(&:last).uniq.freeze

        # An event that isn't allowed in the current state.
        class StateError < StandardError; end

        # One frame's timing, in seconds: +paint+ (the refresh but its
        # write), +write+, +sleep+ (asked for), +slept+ (actual), +late+
        # (how far past its deadline the frame started), +skipped+
        # (deadlines missed before it), +wrote+ (bytes, 0 for none).
        Frame = Data.define(:at, :paint, :write, :sleep, :slept, :late, :skipped, :wrote)

        # Frames kept for #breakdown.
        KEEP = 240

        attr_reader :state, :period, :deadline, :skipped

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
          self.fps = fps
        end

        # Changes the target rate (from the next frame).
        def fps=(fps)
          @period = 1.0 / fps
        end

        # Applies +event+, raising StateError for a pair the table lacks.
        def event!(event)
          to = TRANSITIONS[[@state, event]] or raise StateError, "Pacer: #{event.inspect} in #{@state.inspect}"
          @state = to
        end

        # The screen's write calls this with the seconds a write took (so
        # the frame's time splits into paint and write).
        def note_write(seconds)
          @write += seconds
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
          out = yield start
          done = @clock.call
          event!(:painted)

          # The next deadline, past the ones a long frame missed
          nxt = @deadline + @period
          missed = 0
          if done > nxt
            missed = ((done - nxt) / @period).floor + 1
            nxt += missed * @period
          end
          @skipped += missed
          @deadline = nxt
          want = nxt - done
          @sleeper.call(want) if want > 0
          slept = @clock.call - done
          event!(:woke)
          f = Frame.new(at: start, paint: done - start - @write, write: @write, sleep: want, slept: slept, late: late, skipped: missed,
                        wrote: out.is_a?(String) ? out.bytesize : 0)
          @lock.synchronize do
            @frames << f
            @frames.shift if @frames.length > KEEP
          end
          f
        end

        # Ends the frames (#run does this when its stop Proc says so).
        def stop
          event!(:stop) unless @state == :stopped || @state == :idle
        end

        # The last frames' timing over +window+ seconds: refreshes per
        # second, written frames per second, and p50/max milliseconds of
        # paint, write, sleep asked, oversleep, and lateness, plus skipped
        # deadlines.
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
            sleep_ms: ms.(fs.map(&:sleep)),
            oversleep_ms: ms.(fs.map { |f| f.slept - f.sleep }),
            late_ms: ms.(fs.map(&:late)),
            skipped: fs.sum(&:skipped),
          }
        end

        # The breakdown as one line for the status bar (NAV f): refreshes
        # against the target, frames written, and where a frame's time went.
        def readout(window: 2.0)
          b = breakdown(window: window)
          f = ->(v) { v.nil? ? '-' : format('%.1f', v) }
          "#{b[:refreshes].round}/#{b[:target].round} Hz · #{b[:written].round} written · paint #{f.(b[:paint_ms][:p50])} write #{f.(b[:write_ms][:p50])} " \
            "wait #{f.(b[:sleep_ms][:p50])}+#{f.(b[:oversleep_ms][:p50])} ms#{b[:skipped] > 0 ? " · #{b[:skipped]} missed" : ''}"
        end

        # The transition table as text lines (for the spec and help).
        def self.table
          TRANSITIONS.map { |(s, e), t| "#{s.to_s.ljust(9)} --#{e}--> #{t}" }
        end
      end
    end
  end
end
