module MB
  module Sound
    module UI
      # Values a pane key set, carried until the snapshot catches up (the
      # racks pane since ux-r4b; KnobTurns, the knobs pane, and the tracks
      # pane's levels since knobs-pane-keys-1, one mechanism): a key's
      # value stands in for what it changed for PENDING seconds, so the next
      # key (a held key's repeat, faster than the poll) steps on from it and
      # the pane shows it on the next frame instead of the old value.
      #
      # Kept in the pane's per-placement state (`state[:pending]`: key =>
      # [value, when]).  The including class gets KnobTurns' settable clock
      # (KnobTurns::ClassMethods: monotonic seconds; specs set their own).
      module CarriedValues
        # Seconds a value a key set is used over the snapshot's.
        PENDING = 0.6

        # (KnobTurns includes this module before its ClassMethods exist;
        # classes including either get the one clock)
        def self.included(base)
          base.extend(KnobTurns::ClassMethods) if base.is_a?(Class)
        end

        private

        # Carries +value+ for +key+ (a knob or track name) from now.
        def carry(state, key, value)
          (state[:pending] ||= {})[key] = [value, self.class.clock.call]
          value
        end

        # The value a key set for +key+ within PENDING seconds, else nil.
        def carried(state, key)
          v, at = state[:pending]&.[](key)
          v if at && self.class.clock.call - at < PENDING
        end
      end
    end
  end
end
