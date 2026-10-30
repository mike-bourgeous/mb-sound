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
      # are resolved when the seek lands; a position inside a playing form
      # plays the form on from the pass an uninterrupted run plays there
      # (Form::Playback#seek_position).
      #
      # Undo puts the timeline back where it was when the seek landed (and
      # the form back in the pass it was playing), through a :restore
      # change of subject :timeline, which also lands on its exact frame.
      module Seeks
        # The timeline before a seek (for undo): the position +pos+ and the
        # song form's state (+form+, see Form::Playback#seek_snapshot; nil
        # without a form).
        TimelineState = Struct.new(:pos, :form, keyword_init: true)

        # Undo subject of seeks and timeline restores (a TimelineState).
        TimelineSubject = Data.define
        Undo.subject TimelineSubject, snapshot: :timeline_snapshot, restore: :restore_timeline_change, symbol: :timeline
        Undo.claim :seek_undo_subject, order: 30

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
          target = LengthTarget.new(target) if target.is_a?(Sequence::Duration) || target.is_a?(MB::Sound::Length)
          check_seek_target(target)
          point = at || LaunchPoint::NONE
          time = start_time && !point.given? ? start_time.to_r : launch_time(point, [], default: :now)
          prepare_form_seek(target)
          change(:seek, target, time, data: { to: target }) { |_t| apply_seek(target) }
        end

        private

        # True for changes that move the timeline (they land on exact frames
        # at the start of a span of a buffer; see #process_buffer).
        # True for a graph swap that carries running state (Carry): the
        # buffer splits on its frame, so the old graph's state is taken
        # exactly there, at any buffer size.
        def carry_change?(c)
          c.split
        end

        def timeline_change?(c)
          c.kind == :seek || c.kind == :tempo || (c.kind == :restore && (c.subject == :timeline || c.subject == :tempo))
        end

        # The undo subject of a seek (see Undo#snapshot_subject).
        def seek_undo_subject(c)
          c.kind == :seek ? TimelineSubject.new : nil
        end

        # A seek target given as a length (`12.bars`, `32.seconds`), which
        # journal entries print as written.
        LengthTarget = Data.define(:length) do
          def inspect = Seeks.seek_text(length)
          def to_s = inspect
        end

        # How a seek target prints in a journal label (`bar(11, beat: 2)`,
        # `12.bars`).
        def self.seek_text(target)
          case target
          when LengthTarget then seek_text(target.length)
          when LaunchPoint::Bar then target.beat == 1 ? "bar(#{target.bar})" : "bar(#{target.bar}, beat: #{target.beat})"
          when Sequence::Duration then (Form.ruby_value(target) rescue target.inspect)
          when MB::Sound::Length::Seconds, MB::Sound::Length::Samples
            v = target.fixed? ? target.to_f : nil
            v = v.to_i if v.is_a?(Float) && v == v.to_i
            v.is_a?(Numeric) ? "#{v}.#{target.is_a?(MB::Sound::Length::Seconds) ? 'seconds' : 'samples'}" : target.inspect
          else target.inspect
          end
        end

        # The timeline position (whole notes) of a seek +target+ that isn't
        # a name, through ArgTypes.classify: a bar number (:number, a
        # :ratio) counting from 1 or a LaunchPoint::Bar (`bar(12, beat:
        # 2)`), or a length from the start of the timeline (:duration;
        # :seconds and :samples at the current tempo): `12.bars` is the
        # start of bar 13, as a counter starting at 0 reads.  Raises for
        # anything else, listing the spellings.
        def seek_position(target)
          target = target.length if target.is_a?(LengthTarget)
          case target
          when LaunchPoint::Bar
            return target.whole_notes(@transport)
          end

          case ArgTypes.classify(target)
          when :number, :ratio
            return @transport.bar_position(target) if target >= 1
          when :duration, :seconds, :samples
            pos = target.to_whole_notes(sample_rate: output_open? ? sample_rate : 48000, transport: @transport).to_r
            return pos if pos >= 0
          end
          raise ArgumentError, "seek takes a bar (17, 2.5, seek 11, 2, bar(12, beat: 3)), a length from the start (12.bars = bar 13, 43.n16, 32.seconds), or a section, label, or marker name (got #{ArgTypes.describe_value(target)})"
        end

        # Raises unless +target+ can be sought now (it is resolved again when
        # the seek lands).  +form+ checks section and label names against a
        # Form about to play instead of the one playing (see
        # Arrangement#before_form).
        def check_seek_target(target, form: nil)
          if target.is_a?(Symbol)
            pb = arrangement.playback
            playing = form || (pb.form if pb && !pb.ended?)
            return if playing && (playing.sections.key?(target) || playing.labels.key?(target))
            return if markers[target]

            form ||= pb&.form
            sections = form ? form.sections.keys + form.labels.keys : []
            names = (sections + markers.to_h.keys).uniq
            known = []
            known << "sections and labels: #{sections.uniq.map(&:inspect).join(', ')}" unless sections.empty?
            known << "markers: #{markers.to_h.keys.map(&:inspect).join(', ')}" unless markers.to_h.empty?
            known << 'none yet' if known.empty?
            raise ArgumentError, "No section, label, or marker #{target.inspect} (#{known.join('; ')})#{Form.suggest(target, names)}"
          end

          seek_position(target)
          nil
        end

        # Works out a playing form's passes up to a position target here
        # (the console's thread), so the seek's landing on the render thread
        # finds them (Form::Playback#prepare_seek).
        def prepare_form_seek(target)
          pb = arrangement.playback
          return unless pb && pb.started? && !pb.ended?
          return pb.prepare_seek(target) if target.is_a?(Symbol) && (pb.form.sections.key?(target) || pb.form.labels.key?(target))
          pos = target.is_a?(Symbol) ? markers.position(target) : seek_position(target)
          pb.prepare_seek(pos) if pos
        rescue ArgumentError
          nil # (checked again when the seek lands)
        end

        # Moves the timeline to +target+ (the action of a :seek change).
        # Changes the form makes while restarting there belong to the seek,
        # not to the console command that issued it (so undo restores the
        # timeline, not each track).
        def apply_seek(target)
          @epoch = epoch + 1
          without_command_or_line {
            pb = arrangement.playback
            if target.is_a?(Symbol) && pb && !pb.ended? && (pb.form.sections.key?(target) || pb.form.labels.key?(target))
              pb.seek_now(target)
            else
              pos = target.is_a?(Symbol) ? markers.position(target) : seek_position(target)
              raise ArgumentError, "No marker #{target.inspect}" if pos.nil?
              if pb && pb.started? && !pb.ended? && pos >= pb.start_time
                # The form plays on from the pass playing there in an
                # uninterrupted run (G4; Form::Playback#seek_position)
                pb.seek_position(pos)
              else
                @transport.seek(pos)
              end
            end
          }
        end

        # Snapshots the timeline for undo (see TimelineState).
        def timeline_snapshot(_subject)
          TimelineState.new(pos: @transport.position, form: arrangement.playback&.seek_snapshot)
        end

        # Seeks back to before +original+ at +time+.
        def restore_timeline_change(_subject, original, time)
          change(:restore, :timeline, time, data: {}, undoes: original.seq) { |_t| restore_timeline(original.before) }
        end

        # Puts the timeline (and the form) back to +state+ (a TimelineState).
        def restore_timeline(state)
          raise 'Nothing to restore for the timeline' unless state.is_a?(TimelineState)
          @epoch = epoch + 1
          without_command_or_line {
            @transport.seek(state.pos)
            pb = arrangement.playback
            pb.restore_seek(state.form) if state.form && pb && !pb.ended?
          }
        end

        # #without_command, and outside the take line being typed (a seek
        # that lands right away restarts the form inside the line: the
        # scene launches it makes belong to the seek, in the next epoch,
        # and a replay makes them again when the seek lands, so the line
        # mustn't count them as its own landings, which would make the
        # replay run it early).
        # While a take replays the same holds for the replayed line: its
        # recorded landings and issue time aren't the form's.
        def without_command_or_line(&block)
          Session.with_context_fields(take_line: nil, forced: nil, now: nil) { without_command(&block) }
        end

        # Runs the block in a throwaway undo group: changes made inside it
        # (and commands nested in it, like a scene launch) are not undo
        # steps of their own or part of the console command around it.
        def without_command(&block)
          Session.with_context_fields(command: Undo::CommandGroup.new(self), &block)
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
          c = @changes.find { |x| timeline_change?(x) || carry_change?(x) } or return nil
          from = @transport.position
          return nil unless c.time > from && c.time < Sequence::Transport.position_at(from, count, per_sample)
          k = ((c.time - from) / per_sample).ceil
          k > 0 && k < count ? k : nil
        end
      end
    end
  end
end
