module MB
  module Sound
    module UI
      # A knob turn made of held-key repeats (ux-r4b item 3, maintainer
      # 2026-10-18): a held arrow is a live sweep you hear while you hold
      # it, and ONE console line when it ends (one journal entry, one undo
      # step, one take line), and the take replays exactly what was heard.
      #
      # Each key returns a PaneKeys::Preview (the screen moves the knob
      # with Session#preview_turn: unjournaled, at the next frame to
      # render, recorded as a step of the Session's live gesture); when
      # the keys stop (GAP) or another key comes, a PaneKeys::Commit (the
      # screen runs Session#gesture_line: its fitted keyframes, `turn
      # :"bass/dub/space", 0 => 0.32, 1.n4 => 0.48`, which the take lands
      # at the gesture's first frame, replaying the raw steps it keeps, and
      # whose undo restores the value from before it).
      #
      # An explicit state machine (STATES, EVENTS, every pair declared in
      # TRANSITIONS; turn_gesture_spec walks them):
      # - :idle: no gesture.
      # - :turning: a gesture on #knob, from #from to #value, started at
      #   #started, last key at #last.
      # - :committing: the Commit was handed to the screen; #ran (the
      #   screen ran its line) goes back to :idle.
      #
      # Events: :step (a turn key on the same knob; on another knob the
      # pane flushes first), :tick (time passes, the gap not over), :quiet
      # (GAP seconds since the last key), :flush (another key of the pane),
      # :ran.
      class TurnGesture
        # Seconds between presses that keep a gesture going: longer than a
        # terminal's autorepeat interval (30-50 ms) and most initial
        # repeat delays (250-600 ms).
        GAP = 0.6

        STATES = %i[idle turning committing].freeze
        EVENTS = %i[step tick quiet flush ran].freeze

        # [state, event] => [next state, action, what it does].
        TRANSITIONS = {
          [:idle, :step] => [:turning, :start, 'a gesture starts at the knob\'s value: the first preview'],
          [:idle, :tick] => [:idle, nil, 'nothing waits'],
          [:idle, :quiet] => [:idle, nil, 'nothing waits'],
          [:idle, :flush] => [:idle, nil, 'no gesture to commit'],
          [:idle, :ran] => [:idle, nil, 'not this gesture\'s line'],
          [:turning, :step] => [:turning, :more, 'the gesture goes on: a preview (a new value, a later last key)'],
          [:turning, :tick] => [:turning, nil, 'the knob may still turn'],
          [:turning, :quiet] => [:committing, :emit, 'the keys stopped: the Commit goes out'],
          [:turning, :flush] => [:committing, :emit, 'another key: the Commit goes out now'],
          [:turning, :ran] => [:turning, nil, 'not this gesture\'s line'],
          [:committing, :step] => [:turning, :start, 'a new gesture (the last Commit is out)'],
          [:committing, :tick] => [:committing, nil, 'the screen runs the line'],
          [:committing, :quiet] => [:committing, nil, 'the screen runs the line'],
          [:committing, :flush] => [:committing, nil, 'the line is out already'],
          [:committing, :ran] => [:idle, :clear, 'done'],
        }.freeze

        attr_reader :state, :knob, :from, :value, :started, :last

        def initialize
          @state = :idle
          @knob = @from = @value = @started = @last = nil
        end

        def turning? = @state == :turning

        # A turn key: knob +knob+ (its name) to +value+, from +from+ (where
        # it was, for a new gesture), at +now+.  Returns the Preview.
        def step(knob, from, value, now)
          raise ArgumentError, "a gesture on #{@knob.inspect} got a step on #{knob.inspect} (flush first)" if turning? && knob != @knob
          event(:step, now, knob: knob, from: from, value: value)
        end

        # Time passes: the PaneKeys::Commit once GAP has gone by since the
        # last key, else nil.
        def tick(now)
          event(turning? && now - @last >= GAP - 1e-9 ? :quiet : :tick, now)
        end

        # The Commit now (another key), or nil without a gesture.
        def flush(now) = event(:flush, now)

        # The screen ran the Commit's line.
        def ran(now = nil) = event(:ran, now)

        # Seconds until #tick has a Commit, or nil.
        def wait(now)
          turning? ? [@last + GAP - now, 0].max : nil
        end

        # A value to 4 significant figures, as Ruby.
        def self.number(v)
          v = v.to_f
          v == v.round ? v.round.to_s : MB::M.sigfigs(v, 4).to_s
        end

        # The table as text lines, for notes and specs.
        def self.table
          TRANSITIONS.map { |(s, e), (to, _, what)| format('%-11s %-6s -> %-11s %s', s, e, to, what) }
        end

        def inspect
          "#<UI::TurnGesture #{@state}#{turning? ? " #{@knob} #{@from} -> #{@value}" : ''}>"
        end

        private

        def event(name, now, **args)
          to, action, = TRANSITIONS.fetch([@state, name])
          out = action ? send(action, now, **args) : nil
          @state = to
          out
        end

        def start(now, knob:, from:, value:)
          @knob = knob
          @from = from
          @value = value
          @started = @last = now
          PaneKeys::Preview[knob, value]
        end

        def more(now, value:, **)
          @value = value
          @last = now
          PaneKeys::Preview[knob, value]
        end

        def emit(_now, **)
          PaneKeys::Commit[@knob, "#{@knob} #{TurnGesture.number(@value)}#{@last > @started ? format(' (%.2f s held)', @last - @started) : ''}"]
        end

        def clear(*, **)
          @knob = @from = @value = @started = @last = nil
        end
      end
    end
  end
end
