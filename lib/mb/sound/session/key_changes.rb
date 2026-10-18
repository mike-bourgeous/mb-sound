module MB
  module Sound
    class Session
      # The session key (MusicalKey, midi-consol-2): key and mode changes
      # are journaled changes (kind :key, subject :key) landing at launch
      # points like knob turns, undoable, and replayed exactly by takes.
      # The key itself lives in the transport's key map
      # (Sequence::Transport#key_at), so readers in event time (scale
      # transforms at their note-ons) see a change on its exact position.
      module KeyChanges
        # The key before a change, for undo.
        KeyState = Data.define(:key)

        # The session key now (a MusicalKey).
        def key
          @transport.key
        end

        # Changes the root (+root+: :ab, 'F#', Ab2, a pitch class) and/or
        # the mode (+mode+: a scale name) of the session key at the launch
        # point (+on:+, +in:+, +at:+; right away by default) or
        # +start_time+.  The other part stays as it is when the change
        # lands.  Returns the Change.
        def change_key(root: nil, mode: nil, at: nil, on: nil, in: nil, start_time: nil)
          raise ArgumentError, 'Give a root, a mode, or both' if root.nil? && mode.nil?
          point = LaunchPoint.of(binding) or return nil
          MusicalKey.parse_root(root) unless root.nil?
          mode = MusicalKey.check_mode(mode) unless mode.nil?

          time = start_time ? start_time.to_r : launch_time(point, [], default: nil)
          data = { root: root.nil? ? nil : MusicalKey.parse_root(root)[1], mode: mode.is_a?(MIDI::Param::Base) ? mode.to_s : mode }.compact
          change(:key, :key, time, data: data) { |t|
            k = @transport.key_at(t)
            k = k.with_root(root) unless root.nil?
            k = k.with_mode(mode) unless mode.nil?
            @transport.key_change(k, at: t)
          }
        end

        # The lock on the Session's MIDI inputs (a MIDI::Lock::Style, see
        # KeyMethods#lock), or nil.
        def input_lock
          @input_lock
        end

        # Sets the lock on the Session's MIDI inputs (live MIDI and the
        # virtual keyboard): a MIDI::Lock::Style, or nil (or an :off style)
        # for none.  Notes held when it changes keep their mapping.
        def input_lock=(style)
          @input_lock = style.nil? || style.off? ? nil : style
        end

        private

        def key_snapshot
          KeyState.new(key: @transport.key)
        end

        def restore_key(state, time)
          raise 'Nothing to restore for the key' unless state.is_a?(KeyState)
          @transport.key_change(state.key, at: time)
        end
      end
    end
  end
end
