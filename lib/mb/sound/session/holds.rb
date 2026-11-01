module MB
  module Sound
    class Session
      # Holds (ux-notes-2, the maintainer's "Arm + hold the clip",
      # 2026-11-02): `hold :bass` silences what feeds a track other than
      # live input (its clip player :bass, its cue player :"bass/cue", and
      # the stream wired into it), while its monitor (:"bass/live") keeps
      # playing; `unhold :bass` brings them back in time, as unmute does.
      # The sound-design screen's KEYS mode holds the inspected track so the
      # keyboard is all that plays it (UI::Keyboard::Takeover).
      #
      # A held player is silent through the strip (Strip.rule
      # :hold_strip_rule, before the cue and mute rules): it ramps down over
      # the declick and sleeps, and its timeline nodes move to the timeline
      # when it wakes (clips come back in time).  A held wire input drops
      # its stream's events (MidiInput#wire_held?), its held notes ending
      # where the hold is first read (note-offs, the pedal up); the stream
      # keeps reading, so it too is in time when released.  Holds belong to
      # names, like mutes: a graph launched on a held name starts held.
      # Journaled (:hold, :unhold), undoable, replayed by takes.
      module Holds
        # Undo subject of hold and unhold changes for track +name+: the held
        # names as they were (a frozen Set).
        HoldSubject = Data.define(:name)
        Undo.subject HoldSubject, snapshot: :hold_undo_snapshot, restore: :restore_hold_change
        Undo.claim :hold_undo_subject, order: 15

        # Before Cue's rule (10): a held track's cue player is silent too.
        Strip.rule :hold_strip_rule, order: 5

        # Change kinds for holds.
        KINDS = %i[hold unhold].freeze

        # Holds tracks +names+ (see the module description) right away, or
        # at a launch point (+at:+ a LaunchPoint, or +start_time+).  Returns
        # the changes.
        def hold(*names, at: nil, on: nil, in: nil, start_time: nil)
          point = LaunchPoint.of(binding) or return nil
          hold_change(:hold, names, point, start_time) { |n| @held_tracks << n }
        end

        # Releases held tracks (all of them when none are named: those held
        # when the change lands).
        def unhold(*names, at: nil, on: nil, in: nil, start_time: nil)
          point = LaunchPoint.of(binding) or return nil
          if names.empty?
            time = start_time ? start_time.to_r : launch_time(point, [], default: nil)
            return [change(:unhold, :hold, time, data: {}) { |_t| @held_tracks.clear; apply_strip(nil) }]
          end
          hold_change(:unhold, names, point, start_time) { |n| @held_tracks.delete(n) }
        end

        # The held track names (an Array).  (Not #held?: Changes#held? is a
        # queued change waiting for its warm-up.)
        def held_tracks
          @render_lock.synchronize { @held_tracks.to_a }
        end

        # True if track +name+ is held.
        def track_held?(name)
          @render_lock.synchronize { @held_tracks.include?(name) }
        end

        private

        def init_holds
          @held_tracks = ::Set.new
        end

        # One change per name at the launch point, each calling +update+
        # with the name when it lands.
        def hold_change(kind, names, point, start_time, &update)
          names = names.flatten
          raise ArgumentError, "Name the tracks to #{kind} (#{kind} :bass)" if names.empty? && kind == :hold
          time = start_time ? start_time.to_r : launch_time(point, [], default: nil)
          names.map { |n|
            change(kind, n, time, data: {}) { |_t|
              update.call(n)
              apply_strip(nil)
            }
          }
        end

        # Strip rule: a held track's own player and its cue player are
        # silent; its monitor is left to the other rules.
        def hold_strip_rule(name)
          return nil if @held_tracks.empty?
          return false if @held_tracks.include?(name)
          base = Session::Name.cued(name)
          base && @held_tracks.include?(base) ? false : nil
        end

        # True while track +track+'s wire input should drop its stream's
        # events (render thread, from MidiInput).
        def wire_held?(track)
          !@held_tracks.empty? && @held_tracks.include?(track)
        end

        def hold_undo_subject(c)
          KINDS.include?(c.kind) || c.entry.data[:hold] ? HoldSubject.new(c.subject) : nil
        end

        def hold_undo_snapshot(_subject)
          @held_tracks.dup.freeze
        end

        # Puts the held names back to before +original+ at +time+.
        def restore_hold_change(subject, original, time)
          change(:restore, subject.name, time, data: { hold: true }, undoes: original.seq) { |_t|
            @held_tracks.replace(original.before)
            apply_strip(nil)
          }
        end
        private :hold_strip_rule, :wire_held?, :hold_undo_subject, :hold_undo_snapshot, :restore_hold_change
      end
    end
  end
end
