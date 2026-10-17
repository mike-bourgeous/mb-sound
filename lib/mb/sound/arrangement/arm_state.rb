module MB
  module Sound
    class Arrangement
      # The arm state of one track, as a small state machine (ux-r3 item
      # 21, maintainer 2026-10-17: two states that should agree, "armed"
      # and "its monitor plays", drifted apart when `panic` stopped the
      # monitor but left the track armed).
      #
      # States:
      # - :disarmed - not armed (the default; no entry is kept).
      # - :monitoring - armed, and the monitor player ("name/live") plays
      #   or is queued to play.
      # - :silent - armed for `rec`/`capture`, but no monitor plays
      #   (`arm :x, monitor: false`, a graph track, or a monitor stopped
      #   by `stop :"x/live"` or undone).
      #
      # Events (see TABLE): :arm (monitor started), :arm_silent (no
      # monitor wanted, or none could be built), :disarm, :panic (panic
      # disarms every track: you may have armed a broken track making
      # noise), :monitor_lost and :monitor_found (the Session's players
      # disagree with the state; see Recording#sync_arms, run after every
      # Session command, undo, redo, and seek), :redefine (the track's
      # patch changed; a playing monitor was rebuilt).
      #
      # Invariant (checked by Recording#arm_problems): a track is
      # :monitoring exactly when its monitor player is playing or queued
      # (Session#playing_after_queue?).
      class Arm < Data.define(:input, :monitor, :state)
        # The states in order.
        STATES = %i[disarmed monitoring silent].freeze

        # The events, in order.
        EVENTS = %i[arm arm_silent disarm panic monitor_lost monitor_found redefine].freeze

        # Every (state, event) pair and the state it leads to.  Events
        # that don't apply keep the state (listed, so every pair has a
        # declared answer).
        TABLE = {
          disarmed: {
            arm: :monitoring, arm_silent: :silent, disarm: :disarmed, panic: :disarmed,
            monitor_lost: :disarmed, monitor_found: :disarmed, redefine: :disarmed,
          },
          monitoring: {
            arm: :monitoring, arm_silent: :silent, disarm: :disarmed, panic: :disarmed,
            monitor_lost: :silent, monitor_found: :monitoring, redefine: :monitoring,
          },
          silent: {
            arm: :monitoring, arm_silent: :silent, disarm: :disarmed, panic: :disarmed,
            monitor_lost: :silent, monitor_found: :monitoring, redefine: :silent,
          },
        }.transform_values(&:freeze).freeze

        # The state +state+ goes to on +event+.
        def self.next_state(state, event)
          row = TABLE.fetch(state) { raise ArgumentError, "Unknown arm state #{state.inspect} (#{STATES.join(', ')})" }
          row.fetch(event) { raise ArgumentError, "Unknown arm event #{event.inspect} (#{EVENTS.join(', ')})" }
        end

        # The transition table as text (one row per state).
        def self.table_text
          w = EVENTS.map { |e| [e.length, 10].max }
          head = format('%-11s', '') + EVENTS.each_with_index.map { |e, i| format("%-#{w[i]}s ", e) }.join
          rows = STATES.map { |s| format('%-11s', s) + EVENTS.each_with_index.map { |e, i| format("%-#{w[i]}s ", TABLE[s][e]) }.join }
          [head.rstrip, *rows.map(&:rstrip)].join("\n")
        end

        # This arm after +event+ (nil once disarmed).
        def on(event)
          s = Arm.next_state(state, event)
          s == :disarmed ? nil : with(state: s)
        end

        # True while the track's monitor plays (see the invariant).
        def monitoring? = state == :monitoring
      end
    end
  end
end
