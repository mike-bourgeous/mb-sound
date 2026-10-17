module MB
  module Sound
    class ScriptRunner
      # Media-player transport keys for song screens (ux-r3 item 42):
      # Left goes to the start of the bar playing, then a bar back per
      # press; Right a bar forward.  Presses (and key repeats, so holding
      # scrubs) within GRACE seconds of the previous press of the same key
      # step from the previous press's TARGET, not from the playhead, so a
      # fast tempo never traps Left in the bar the seek landed in; the
      # window is wall-clock time, not musical time.  Held past ACCELERATE
      # seconds a press steps 2 bars, then 4.
      #
      # States (TABLE): :idle, :back (Left presses chained), :forward
      # (Right presses chained); a press after GRACE has passed counts from
      # :idle.  Every (state, key) pair is declared.
      class Scrub
        # Seconds after a press in which the next press steps from its
        # target.
        GRACE = 0.6

        # [seconds held, bars per press]: held at least that long, presses
        # step that many bars.
        ACCELERATE = [[2.0, 4], [1.0, 2], [0.0, 1]].freeze

        # [state, key] => [next state, how the target is found]:
        # :bar_start (the start of the playhead's bar, or the bar before it
        # when the playhead is at a bar line), :next_bar (the next bar
        # line), :step_back / :step_forward (from the previous target).
        TABLE = {
          [:idle, :left] => [:back, :bar_start],
          [:idle, :right] => [:forward, :next_bar],
          [:back, :left] => [:back, :step_back],
          [:back, :right] => [:forward, :next_bar],
          [:forward, :left] => [:back, :bar_start],
          [:forward, :right] => [:forward, :step_forward],
        }.freeze

        attr_reader :state, :target

        # +transport+ gives #position and the meter map (Sequence::Transport);
        # +seek+ is called with a bar number (an Integer from 1); +clock+
        # gives seconds (monotonic).
        def initialize(transport, seek:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @transport = transport
          @seek = seek
          @clock = clock
          @state = :idle
          @target = nil
          @last = nil
          @chain_start = nil
        end

        # Handles +key+ (:left or :right): seeks and returns the target bar.
        def press(key)
          now = @clock.call
          state = @last && now - @last <= GRACE ? @state : :idle
          nxt, how = TABLE.fetch([state, key]) { raise ArgumentError, "Scrub: no key #{key.inspect} (:left, :right)" }
          @chain_start = now if %i[bar_start next_bar].include?(how) # (a new chain: no acceleration yet)
          step = ACCELERATE.find { |held, _| now - @chain_start >= held }[1]
          bar = @transport.bar_at(@transport.position)
          target =
            case how
            when :bar_start then bar == bar.floor ? bar.floor - 1 : bar.floor
            when :next_bar then bar.floor + 1
            when :step_back then @target - step
            when :step_forward then @target + step
            end
          target = [target.to_i, 1].max
          @state = nxt
          @target = target
          @last = now
          @seek.call(target)
          target
        end
      end
    end
  end
end
