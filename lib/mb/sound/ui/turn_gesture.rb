module MB
  module Sound
    module UI
      # A knob turn made of held-key repeats (ux-r4b item 3, maintainer
      # 2026-10-18): presses of a turn key within GAP seconds of each
      # other are one gesture, which becomes ONE console line when it
      # ends (`turn :"bass/dub/space", 0.62, over: 0.84.seconds`): one
      # journal entry, one undo step, one take line.  Meanwhile the pane
      # previews where the knob is heading (#value); the knob itself moves
      # when the line runs, over the gesture's length, so what plays live
      # is what the take replays.
      #
      # An explicit state machine (STATES, EVENTS, every pair declared in
      # TRANSITIONS; turn_gesture_spec walks them):
      # - :idle: no gesture.
      # - :turning: a gesture on #knob, from #from to #value, started at
      #   #started, last key at #last.
      # - :committing: the gesture's line was handed to the screen (#emit
      #   returned it); #ran (the screen ran it) goes back to :idle.
      #
      # Events: :step (a turn key on the same knob; on another knob the
      # pane flushes first), :tick (time passes, the gap not over), :quiet
      # (GAP seconds since the last key), :flush (another key of the pane,
      # or the pane wants the line now), :ran.
      class TurnGesture
        # Seconds between presses that keep a gesture going: longer than a
        # terminal's autorepeat interval (30-50 ms) and most initial
        # repeat delays (250-600 ms).
        GAP = 0.6

        # Gestures shorter than this are a tap: a plain turn, no over:.
        TAP = 0.05

        STATES = %i[idle turning committing].freeze
        EVENTS = %i[step tick quiet flush ran].freeze

        # [state, event] => [next state, action, what it does].
        TRANSITIONS = {
          [:idle, :step] => [:turning, :start, 'a gesture starts at the knob\'s value'],
          [:idle, :tick] => [:idle, nil, 'nothing waits'],
          [:idle, :quiet] => [:idle, nil, 'nothing waits'],
          [:idle, :flush] => [:idle, nil, 'no gesture to commit'],
          [:idle, :ran] => [:idle, nil, 'not this gesture\'s line'],
          [:turning, :step] => [:turning, :more, 'the gesture goes on (a new target, a later last key)'],
          [:turning, :tick] => [:turning, nil, 'the knob may still turn'],
          [:turning, :quiet] => [:committing, :emit, 'the keys stopped: the line goes out'],
          [:turning, :flush] => [:committing, :emit, 'another key: the line goes out now'],
          [:turning, :ran] => [:turning, nil, 'not this gesture\'s line'],
          [:committing, :step] => [:turning, :start, 'a new gesture (the last line is out)'],
          [:committing, :tick] => [:committing, nil, 'the screen runs the line'],
          [:committing, :quiet] => [:committing, nil, 'the screen runs the line'],
          [:committing, :flush] => [:committing, nil, 'the line is out already'],
          [:committing, :ran] => [:idle, :clear, 'done'],
        }.freeze

        attr_reader :state, :knob, :from, :value, :started, :last

        def initialize
          @state = :idle
          @knob = @from = @value = @started = @last = nil
          @line = nil
        end

        def turning? = @state == :turning

        # A turn key: knob +knob+ (its name) heading to +value+, from
        # +from+ (where it was, for a new gesture), at +now+.
        def step(knob, from, value, now)
          raise ArgumentError, "a gesture on #{@knob.inspect} got a step on #{knob.inspect} (flush first)" if turning? && knob != @knob
          event(:step, now, knob: knob, from: from, value: value)
        end

        # Time passes: the line (PaneKeys::Run) once GAP has gone by
        # since the last key, else nil.
        def tick(now)
          event(turning? && now - @last >= GAP - 1e-9 ? :quiet : :tick, now)
        end

        # The line now (another key), or nil without a gesture.
        def flush(now) = event(:flush, now)

        # The screen ran the line.
        def ran(now = nil) = event(:ran, now)

        # Seconds until #tick has a line, or nil.
        def wait(now)
          turning? ? [@last + GAP - now, 0].max : nil
        end

        # The console line for a gesture on +knob+ from a start at
        # +started+ to the last key at +last+, to +value+.
        def self.line(knob, value, seconds)
          v = number(value)
          if seconds < TAP
            PaneKeys::Run["turn #{knob.inspect}, #{v}", "#{knob} #{v}"]
          else
            s = format('%.2f', seconds).sub(/0+\z/, '').sub(/\.\z/, '.0')
            PaneKeys::Run["turn #{knob.inspect}, #{v}, over: #{s}.seconds", "#{knob} #{v} over #{s} s"]
          end
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
          nil
        end

        def more(now, value:, **)
          @value = value
          @last = now
          nil
        end

        def emit(_now, **)
          @line = TurnGesture.line(@knob, @value, @last - @started)
        end

        def clear(*, **)
          @knob = @from = @value = @started = @last = @line = nil
        end
      end
    end
  end
end
