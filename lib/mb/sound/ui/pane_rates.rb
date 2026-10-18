module MB
  module Sound
    module UI
      # Adaptive pane rates (ux-r4 item 2; maintainer, 2026-10-17: "run
      # panes at 60/s or at target_fps, and have them slow down and take
      # turns when the CPU is loaded").  Live panes (meters, scopes,
      # transport, the keyboard, ...) want the painter's target rate; list
      # panes (tracks, queue, buses, ...) keep their own rate, since the
      # data they show changes a few times a second (UI::Poll reads 4/s).
      # Under load the screen steps down LEVELS one at a time: list panes
      # slow first, then live panes, meters and scopes last, and from level
      # 2 the panes that aren't meters take turns (at most +turns+ of them
      # per frame, the most overdue first).  Load is the painter's share of
      # a frame period (paint + write, smoothed) and the render thread's
      # load (Snapshot#load: the share of real time the audio took);
      # leaving a level asks for calm over EASE seconds, so it doesn't
      # flap.
      #
      # An explicit state machine (TRANSITIONS: [state, event] => [state,
      # action]), events one per frame: :busy (over budget), :fine, :calm
      # (well under).  `ui.stats[:rates]`, NAV f (each pane's rate beside
      # its number), and #readout show it.
      #
      #     rates = PaneRates.new(60, clock: -> { MB::U.clock_now })
      #     rates.begin_frame(now)
      #     rates.due?(:meters, :meter, 30, drawn_at, now)   # per pane
      #     rates.drew(:meters, now)
      #     rates.observe(paint + write, render_load)        # after the frame
      class PaneRates
        # Priority classes, most kept first.
        PRIORITIES = %i[meter live list].freeze

        # The class of each built-in pane kind (others: :list, unless the
        # pane says otherwise with #priority).
        KINDS = {
          meters: :meter, scope: :meter, spectrum: :meter,
          transport: :live, keyboard: :live, lane: :live, knobs: :live,
        }.freeze

        # Rate factors per class, and how many panes other than meters may
        # draw per frame (nil: all that are due), by level.
        Level = Data.define(:meter, :live, :list, :turns)
        LEVELS = [
          Level.new(meter: 1.0, live: 1.0, list: 1.0, turns: nil),
          Level.new(meter: 1.0, live: 0.5, list: 0.5, turns: nil),
          Level.new(meter: 1.0, live: 0.5, list: 0.25, turns: 2),
          Level.new(meter: 0.5, live: 0.25, list: 0.25, turns: 1),
          Level.new(meter: 0.25, live: 0.125, list: 0.125, turns: 1),
        ].freeze

        # The slowest any pane goes (redraws per second).
        MIN_RATE = 0.5

        # Budget: the painter's smoothed share of a frame period above
        # which it is :busy, below which :calm; the render thread's load
        # likewise (the audio comes first: the UI shares its GVL).
        BUSY_SHARE = 0.5
        CALM_SHARE = 0.2
        RENDER_BUSY = 0.8
        RENDER_CALM = 0.6

        # Seconds of :busy before stepping down a level (and between
        # steps), and of :calm before stepping back up.
        STRAIN = 0.25
        EASE = 2.0

        # Smoothing of the painter's share (each frame's weight).
        ALPHA = 0.2

        # [state, event] => [state, action].  States: :steady (nothing
        # pending), :strained (busy since #since; :step_down when STRAIN has
        # passed), :easing (calm since #since; :step_up after EASE).  A
        # spec walks every pair.
        TRANSITIONS = {
          [:steady, :busy] => [:strained, :start],
          [:steady, :fine] => [:steady, :none],
          [:steady, :calm] => [:easing, :start],
          [:strained, :busy] => [:strained, :step_down],
          [:strained, :fine] => [:steady, :none],
          [:strained, :calm] => [:easing, :start],
          [:easing, :busy] => [:strained, :start],
          [:easing, :fine] => [:steady, :none],
          [:easing, :calm] => [:easing, :step_up],
        }.freeze

        STATES = TRANSITIONS.keys.map(&:first).uniq.freeze
        EVENTS = TRANSITIONS.keys.map(&:last).uniq.freeze

        attr_reader :state, :level, :since, :share, :render_load, :changes

        # +fps+ the painter's target rate; +clock+ a Proc of seconds.
        def initialize(fps, clock:)
          @clock = clock
          @fps = fps
          @state = :steady
          @level = 0
          @since = nil
          @share = 0.0
          @render_load = 0.0
          @changes = 0
          @turns_left = nil
          @draws = Hash.new { |h, k| h[k] = [] }
          @lock = Mutex.new
        end

        # The painter's target rate (live panes run at it).
        attr_accessor :fps

        # The table as text lines.
        def self.table
          TRANSITIONS.map { |(s, e), (t, a)| "#{s.to_s.ljust(9)} --#{e}--> #{t.to_s.ljust(9)} #{a}" }
        end

        # The class of +pane+ (named +name+): the pane's own #priority,
        # else KINDS by name or kind, else :list.
        def self.priority_of(name, pane)
          return pane.priority if pane.respond_to?(:priority) && PRIORITIES.include?(pane.priority)
          kind = PaneKeys.kind_of(pane) || name
          KINDS[name] || KINDS[kind] || :list
        end

        # The rate a pane of class +priority+ wants at full speed: the
        # layout's explicit +rate+ option, else the target for meters and
        # live panes, else the pane's own rate.
        def desired(priority, own_rate, explicit = nil)
          return explicit if explicit.is_a?(Numeric) && explicit > 0
          priority == :list ? own_rate : [@fps, own_rate].max
        end

        # The rate now (desired scaled by the level's factor).
        def rate(priority, own_rate, explicit = nil)
          [desired(priority, own_rate, explicit) * LEVELS[@level].public_send(priority), MIN_RATE].max
        end

        # Starts a frame: the turns it has for panes other than meters.
        def begin_frame(_now = nil)
          @turns_left = LEVELS[@level].turns
        end

        # True if a pane (+name+, +priority+, its own rate, the layout's
        # explicit rate or nil) last drawn at +drawn_at+ (nil: never) should
        # draw at +now+, taking a turn if turns are rationed.  +overdue+
        # panes (Array of [name, lateness]) let the caller pick the most
        # overdue first; see #pick.
        def due?(priority, own_rate, explicit, drawn_at, now)
          return true if drawn_at.nil?
          now - drawn_at >= 1.0 / rate(priority, own_rate, explicit) - 0.001
        end

        # From +candidates+ ([[key, priority, lateness], ...]: panes due this
        # frame, lateness in periods past due), the ones that draw: every
        # meter, and the others in order of lateness up to the level's
        # turns.  Returns the keys.
        def pick(candidates)
          meters, others = candidates.partition { |_, pr, _| pr == :meter }
          turns = @turns_left
          others = others.sort_by { |_, _, late| -late }.first(turns) if turns
          (meters + others).map(&:first)
        end

        # Notes that pane +name+ drew at +now+ (for #measured).
        def drew(name, now)
          @lock.synchronize do
            q = @draws[name]
            q << now
            q.shift while q.length > 1 && q[0] < now - WINDOW
          end
        end

        # Seconds of draws #measured counts.
        WINDOW = 2.0

        # Each pane's measured redraws per second over WINDOW.
        def measured(now = @clock.call)
          @lock.synchronize do
            @draws.to_h { |name, q| [name, (q.count { |t| t > now - WINDOW } / WINDOW).round(1)] }
          end
        end

        # One frame's measures: +cost+ seconds of paint and write, the
        # render thread's +render_load+ (0..1, or nil if unknown).  Returns
        # the event applied.
        def observe(cost, render_load, now = @clock.call)
          period = 1.0 / @fps
          @share += ALPHA * ([cost / period, 4.0].min - @share)
          @render_load = render_load || 0.0
          ev =
            if @share > BUSY_SHARE || @render_load > RENDER_BUSY then :busy
            elsif @share < CALM_SHARE && @render_load < RENDER_CALM then :calm
            else :fine
            end
          event!(ev, now)
          ev
        end

        # Applies +event+ at +now+ (the TRANSITIONS row; a pair without one
        # raises).
        def event!(event, now = @clock.call)
          to, action = TRANSITIONS.fetch([@state, event]) { raise ArgumentError, "PaneRates: #{event.inspect} in #{@state.inspect}" }
          case action
          when :start then @since = now
          when :step_down
            if now - @since >= STRAIN && @level < LEVELS.length - 1
              @level += 1
              @changes += 1
              @since = now
            end
          when :step_up
            if now - @since >= EASE && @level > 0
              @level -= 1
              @changes += 1
              @since = now
            end
          when :none then @since = nil
          end
          @state = to
          self
        end

        # "level 2 (busy 0.6 of a frame, render 0.85)" or "full rate".
        def readout
          return 'full rate' if @level == 0
          format('rates level %d (painter %.2f of a frame, render %.2f)', @level, @share, @render_load)
        end

        # A Hash for stats.
        def to_h
          { level: @level, state: @state, share: @share.round(3), render_load: @render_load.round(3), changes: @changes, turns: LEVELS[@level].turns }
        end
      end
    end
  end
end
