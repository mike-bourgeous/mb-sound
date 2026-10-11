module MB
  module Sound
    class Session
      # Timeline jumps through the change queue (maintainer, 2026-10-11:
      # seek takes launch points, returns a journal entry, is undoable, and
      # replays exactly from takes).  A seek is a :seek change; it lands on
      # the exact frame of its time: Session#process_buffer renders the
      # frames before it, applies it, and renders the rest from the new
      # position, so any buffer size jumps on the same frame.
      #
      # Targets: a bar number (counting from 1, through the meter map), a
      # section or label of the song form playing (the form plays on from
      # there, see Form::Playback#seek_now), or another marker.  Positions
      # are resolved when the seek lands.
      #
      # Undo puts the timeline back where it was when the seek landed (and
      # the form back in the pass it was playing), through a :restore
      # change of subject :timeline, which also lands on its exact frame.
      module Seeks
        # The timeline before a seek (for undo): the position +pos+ and the
        # song form's state (+form+, see Form::Playback#seek_snapshot; nil
        # without a form).
        TimelineState = Struct.new(:pos, :form, keyword_init: true)

        # How many timeline changes (seeks and their undos) have landed: the
        # number of the current pass over the timeline, for take replays
        # (see Scheduler::Entry and Take::Replay).
        def epoch
          @epoch ||= 0
        end

        # Moves the timeline to +target+ (see the module comment) at the
        # launch point +at+ (now by default), or at +start_time+ (whole
        # notes) when +at+ gives none.  Returns the Change.
        def seek(target, at: nil, start_time: nil)
          check_seek_target(target)
          point = at || LaunchPoint::NONE
          time = start_time && !point.given? ? start_time.to_r : launch_time(point, [], default: :now)
          change(:seek, target, time, data: { to: target }) { |_t| apply_seek(target) }
        end

        private

        # True for changes that move the timeline (they land on exact frames
        # at the start of a span of a buffer; see #process_buffer).
        def timeline_change?(c)
          c.kind == :seek || (c.kind == :restore && c.subject == :timeline)
        end

        # The subject whose state a change snapshots for undo.
        def snapshot_subject(c)
          c.kind == :seek ? :timeline : c.subject
        end

        # Raises unless +target+ can be sought now (it is resolved again when
        # the seek lands).
        def check_seek_target(target)
          if target.is_a?(Symbol)
            pb = arrangement.playback
            return if pb && !pb.ended? && (pb.form.sections.key?(target) || pb.form.labels.key?(target))
            return if markers[target]

            names = markers.to_h.keys
            names += pb.form.sections.keys + pb.form.labels.keys if pb
            raise ArgumentError, "No section, label, or marker #{target.inspect} (markers: #{markers.to_h.keys.map(&:inspect).join(', ')})#{Form.suggest(target, names.uniq)}"
          end

          raise ArgumentError, "Bar must be a number of at least 1 (got #{target.inspect})" unless target.is_a?(Numeric) && target >= 1
        end

        # Moves the timeline to +target+ (the action of a :seek change).
        # Changes the form makes while restarting there belong to the seek,
        # not to the console command that issued it (so undo restores the
        # timeline, not each track).
        def apply_seek(target)
          @epoch = epoch + 1
          without_command {
            pb = arrangement.playback
            if target.is_a?(Symbol) && pb && !pb.ended? && (pb.form.sections.key?(target) || pb.form.labels.key?(target))
              pb.seek_now(target)
            else
              pos = target.is_a?(Symbol) ? markers.position(target) : @transport.bar_position(target)
              raise ArgumentError, "No marker #{target.inspect}" if pos.nil?
              @transport.seek(pos)
            end
          }
        end

        # Snapshots the timeline for undo (see TimelineState).
        def timeline_snapshot
          TimelineState.new(pos: @transport.position, form: arrangement.playback&.seek_snapshot)
        end

        # Puts the timeline (and the form) back to +state+ (a TimelineState).
        def restore_timeline(state)
          raise 'Nothing to restore for the timeline' unless state.is_a?(TimelineState)
          @epoch = epoch + 1
          without_command {
            @transport.seek(state.pos)
            pb = arrangement.playback
            pb.restore_seek(state.form) if state.form && pb && !pb.ended?
          }
        end

        # Runs the block in a throwaway undo group: changes made inside it
        # (and commands nested in it, like a scene launch) are not undo
        # steps of their own or part of the console command around it.
        def without_command
          old = Thread.current[:mb_sound_command]
          Thread.current[:mb_sound_command] = { session: self, changes: [], extras: [] }
          yield
        ensure
          Thread.current[:mb_sound_command] = old
        end

        # Commits timeline changes due at the current position (at the start
        # of a span; see #process_buffer), with the changes due before them
        # in queue order (so a change for the same time issued earlier lands
        # first, as in #commit_due).
        def commit_due_seeks
          while @changes.any? { |x| timeline_change?(x) && x.time <= @transport.position }
            while (c = @changes.first) && c.time <= @transport.position
              @changes.shift
              pos = @transport.position
              commit_change(c, land_pos: pos, land_frame: @frame, commits: stamp(pos, frame: @frame), immediate: false)
              break if timeline_change?(c) # what is due now depends on the new position
            end
          end
        end

        # The number of frames (1 to +count+ - 1) before the next timeline
        # change inside the next +count+ frames, or nil if none lands there.
        def frames_before_seek(count, per_sample)
          c = @changes.find { |x| timeline_change?(x) } or return nil
          from = @transport.position
          return nil unless c.time > from && c.time < from + count * per_sample
          k = ((c.time - from) / per_sample).ceil
          k > 0 && k < count ? k : nil
        end
      end
    end
  end
end
