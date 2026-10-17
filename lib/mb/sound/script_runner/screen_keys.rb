module MB
  module Sound
    class ScriptRunner
      # The keys of a script's `--ui` screen (ux-r3 items 42, 43): one table
      # per screen kind (KEYS), which both dispatches keys and writes the
      # status line's hints, so they can't disagree.
      #
      # Song screens: q or Esc quits, Space pauses, Left/Right step a bar
      # like a media player (see Scrub), Up/Down or [ / ] move between the
      # form's sections, PageUp/PageDown launch the previous/next scene.
      # Synth and effect screens: q quits, Space pauses, Esc is all notes off
      # (twice: all sound off), as in their plain live mode (LiveKeys).
      module ScreenKeys
        # Screen kind (:song; :synth for synths and effects) => [[keys,
        # action, hint or nil], ...].  Keys are
        # Input::Key#key values without modifiers.
        KEYS = {
          song: [
            [['q', 'Q', :escape], :quit, 'q/Esc quit'],
            [[' '], :pause, 'Space pause'],
            [[:left], :bar_back, 'Left/Right bar'],
            [[:right], :bar_forward, nil],
            [[:up, '['], :section_back, 'Up/Down [ ] section'],
            [[:down, ']'], :section_forward, nil],
            [[:page_up], :scene_back, 'PgUp/PgDn scene'],
            [[:page_down], :scene_forward, nil],
          ].freeze,
          synth: [
            [['q', 'Q'], :quit, 'q quit'],
            [[' '], :pause, 'Space pause'],
            [[:escape], :panic, 'Esc notes off'],
          ].freeze,
        }.freeze

        # Hints shown after the table's (the screen's own keys).
        SCREEN_HINTS = 'Ctrl-] nav  F2 keys'

        # The action for Input::Key +k+ on a +kind+ screen (:song, :synth,
        # :effect), or nil.  Releases do nothing; repeats act like presses
        # (holding Left scrubs; see Scrub).
        def self.action(kind, k)
          return nil if k.respond_to?(:release?) && k.release?
          return nil unless k.mods.empty? || k.mods == [:shift] && k.key.is_a?(String)
          table(kind).each { |keys, act, _| return act if keys.include?(k.key) }
          nil
        end

        # The table of screen kind +kind+.
        def self.table(kind)
          KEYS.fetch(kind == :song ? :song : :synth)
        end

        # The status line hints of a +kind+ screen.
        def self.hints(kind)
          [*table(kind).filter_map { |_, _, h| h }, SCREEN_HINTS].join('  ')
        end
      end

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
