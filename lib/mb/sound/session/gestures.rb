module MB
  module Sound
    class Session
      # Knob gestures in takes (gesture-curves, agreed 2026-10-18): takes
      # reproduce what was heard, exports read like music.
      #
      # A racks-pane gesture is ONE console line printing its fitted
      # keyframes (Knobs#gesture_line), while its journal entry keeps the
      # raw steps (data[:raw]); a take saves those steps (`r.gestures`)
      # and its replay plays them, bit for bit (#replay_gestures!,
      # #replayed_gesture).  #smooth_gesture makes a recorded gesture its
      # fitted curve on purpose: the take then replays the line as printed.
      module Gestures
        # The gestures smoothed on purpose (see #smooth_gesture): journal
        # seqs, with undo (Session#note_undo_extra).
        class Smoothed
          def initialize
            @seqs = Set.new
            @mutex = Mutex.new
          end

          def include?(seq) = @mutex.synchronize { @seqs.include?(seq) }

          def add(seq) = @mutex.synchronize { @seqs << seq }

          def undo_state = @mutex.synchronize { @seqs.dup }

          def restore_undo_state(state)
            @mutex.synchronize { @seqs = state.dup }
          end
        end

        # The gestures smoothed on purpose (a Smoothed).
        def smoothed_gestures
          @smoothed_gestures ||= Smoothed.new
        end

        # The live gestures' journal entries ({ seq => latest entry }) of
        # knob +name+ (all knobs if nil), oldest first.
        def gesture_entries(name = nil)
          journal.changes.select { |e| e.kind == :turn && e.data.is_a?(Hash) && e.data[:raw] && (name.nil? || e.subject == name) }
        end

        # Replaces a recorded gesture (the last one, or the last on knob
        # +name+) with its fitted curve on purpose: takes replay its line as
        # printed (the fitted keyframes) instead of the raw steps.  One undo
        # step (`undo` keeps the raw steps again).  Returns the entry, or
        # nil if there is no recorded gesture.
        def smooth_gesture(name = nil)
          name = knob!(name).name unless name.nil?
          entry = gesture_entries(name).reverse.find { |e| !smoothed_gestures.include?(e.seq) } or return nil
          command("smooth_gesture #{entry.subject.inspect}") {
            before = smoothed_gestures.undo_state
            smoothed_gestures.add(entry.seq)
            note_undo_extra(smoothed_gestures, before, smoothed_gestures.undo_state)
          }
          entry
        end

        # Takes: the raw steps of the gestures a replay plays ([[knob name,
        # epoch, timeline position, [[frames, value], ...]], ...], epochs
        # counted from +base_epoch+).
        def replay_gestures!(rows, base_epoch: 0)
          table = {}
          rows.each { |name, ep, pos, steps| table[[name, ep + base_epoch, pos.to_r]] = steps.map { |f, v| [Integer(f), v.to_f] }.freeze }
          @replayed_gestures = table.freeze
        end

        # The recorded raw steps of knob +name+'s gesture at timeline
        # position +pos+ in the current epoch, or nil.
        def replayed_gesture(name, pos)
          table = @replayed_gestures
          return nil if table.nil? || table.empty? || pos.nil?
          table[[name, epoch, pos.to_r]]
        end
      end
    end
  end
end
