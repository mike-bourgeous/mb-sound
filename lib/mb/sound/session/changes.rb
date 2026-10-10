module MB
  module Sound
    class Session
      # The Session's change queue: every change to what plays (#add,
      # #remove, #resume, #swap, #master, #mute, #solo, undo, ...) goes
      # through #change, which resolves it to an exact landing time, records
      # it in the journal (see Journal), and either applies it right away
      # (when it lands now) or queues it until the buffer that holds its
      # time, where the render thread hands it to the Session on the exact
      # sample.
      #
      # Queuing future changes, instead of handing them to players early,
      # lets any number of changes wait for one player: e.g. a swap for bar 9
      # and another for the next bar both happen (a clip source only holds
      # one pending swap, so the earlier code silently dropped one).  Changes
      # landing at the same time apply in the order they were issued.
      #
      # Changes are applied under the render lock, between buffers, so a
      # change made from the console while a buffer renders lands exactly at
      # the start of the next one, and the returned journal entry says where.
      module Changes
        # A change waiting in the queue (or applied).  +time+ is the landing
        # position in whole notes (nil for "now").  +action+ is called with
        # the landing time to apply it.  +before+ and +after+ are snapshots
        # of the subject around the change, for undo.  +starts+ is the
        # timeline nodes of a graph the change starts (for swaps queued
        # behind it).
        Change = Struct.new(
          :seq, :kind, :subject, :time, :action, :entry, :before, :after, :lands, :starts,
          keyword_init: true
        )

        # Change kinds that start a player (so a queued one keeps the
        # timeline moving while nothing else plays).
        START_KINDS = [:bg, :resume, :restore].freeze

        # Change kinds whose subject isn't a player or :master (no undo
        # snapshots; e.g. scene launches, whose players' changes are
        # separate).
        NO_SNAPSHOT_KINDS = [:scene].freeze

        # The Journal of changes made to this Session.
        attr_reader :journal

        # The session frame: how many frames have been rendered since the
        # Session was created (see Stamp).
        attr_reader :frame

        # The Stamp of the next frame to render: the frame counter and
        # timeline position where a change made right now lands (see also
        # #transport_record).
        def clock
          @render_lock.synchronize { Stamp.new(frame: @frame, pos: @transport.position, bar_length: @transport.bar_length) }
        end

        # The per-buffer transport record (contract K1): the frame and
        # timeline position of the next buffer, the tempo, the bar length,
        # and whether the timeline is moving.
        def transport_record
          @transport_record
        end

        # A Stamp for timeline position +pos+ (frame unknown unless given).
        def stamp(pos, frame: nil)
          Stamp.new(frame: frame, pos: pos, bar_length: @transport.bar_length)
        end

        # The timeline position that commands resolve their launch points
        # from: the scheduled time inside a scheduled block (so `on: :beat`
        # in `at_bar(5) { ... }` means the beat at or after bar 5), the
        # recorded issue time while a take replays, and the transport
        # position otherwise.
        def now
          perform = Session.perform
          return perform[:now] if perform&.[](:now) && perform[:session].equal?(self)
          context = Session.context
          return context[:time] if context&.[](:time) && context[:session].equal?(self)
          @transport.position
        end

        # Records a change to the subject +subject+ (a player name, :master,
        # ...) landing at +time+ (whole notes; nil or a past time for now),
        # and applies it with +action+ (called with the landing time, under
        # the render lock) now or when the timeline reaches it.  Returns the
        # Change; its +entry+ is the journal entry (updated in the journal
        # as the change lands).
        #
        # While a take replays, the landing time comes from the take instead
        # (see Take).
        def change(kind, subject, time, data: {}, undoes: nil, starts: nil, &action)
          raise IOError, 'Session is closed' if @closed
          raise ArgumentError, 'Pass a block to apply the change' unless action

          perform = Session.perform
          perform = nil unless perform&.[](:session).equal?(self)
          if perform&.[](:forced)
            forced = perform[:forced].shift
            if forced.nil?
              warn "Replay: #{kind} #{subject.inspect} wasn't in the take; it lands where it resolves now" unless perform[:overrun_warned]
              perform[:overrun_warned] = true
            else
              time = forced
            end
          end
          time = time&.to_r

          source = perform&.[](:source) || Session.context&.[](:source) || :console
          line = perform&.[](:line) || Take.current_line_id

          c = nil
          @render_lock.synchronize {
            pos = @transport.position
            seq = @journal.next_seq
            c = Change.new(seq: seq, kind: kind, subject: subject, time: time, action: action, starts: starts)

            c.entry = @journal.add(Journal::Entry.new(
              seq: seq, kind: kind, subject: subject,
              issued: Stamp.new(frame: @frame, pos: perform&.[](:now) || now_unlocked(pos), bar_length: @transport.bar_length),
              commits: nil,
              lands: stamp(time.nil? || time < pos ? pos : time),
              status: :queued, source: source, line: line, data: data.freeze, undoes: undoes
            ))

            if time.nil? || time <= pos
              commit_change(c, land_pos: pos, land_frame: @frame, commits: stamp(pos, frame: @frame), immediate: true)
            else
              idx = @changes.bsearch_index { |q| q.time > time || (q.time == time && q.seq > seq) } || @changes.length
              @changes.insert(idx, c)
            end
          }

          Session.note_command_change(self, c)
          Take.note_change(self, c)
          c
        end

        # Entries for the changes still waiting in the queue (for +name+
        # only if given), soonest first.
        def queued(name = nil)
          @render_lock.synchronize {
            list = name.nil? ? @changes : @changes.select { |c| c.subject == name }
            list.map(&:entry)
          }
        end

        # Removes queued changes (by +seq+ or Change) from the queue before
        # they land, recording them as cancelled.  Returns the cancelled
        # entries.
        def cancel_changes(*seqs)
          seqs = seqs.map { |s| s.respond_to?(:seq) ? s.seq : s }
          @render_lock.synchronize {
            cancelled = @changes.select { |c| seqs.include?(c.seq) }
            @changes -= cancelled
            cancelled.map { |c| c.entry = @journal.add(c.entry.with(status: :cancelled)) }
          }
        end

        # True if a change with +seq+ is still waiting in the queue.
        def queued_change?(seq)
          @render_lock.synchronize { @changes.any? { |c| c.seq == seq } }
        end

        private

        # Sets up the change queue and journal.  Called by Session#initialize.
        def init_changes
          @render_lock = Monitor.new
          @changes = []
          @journal = Journal.new
          @frame = 0
          @transport_record = transport_record_for(false)
        end

        # The transport position or a scheduled block's time, without the
        # lock (see #now).
        def now_unlocked(pos)
          context = Session.context
          context&.[](:time) && context[:session].equal?(self) ? context[:time] : pos
        end

        def transport_record_for(playing)
          {
            frame: @frame, pos: @transport.position, bpm: @transport.bpm,
            bar_length: @transport.bar_length, playing: playing
          }.freeze
        end

        # True if a change that starts a player is queued (with @render_lock
        # or @mutex held, or for an estimate).
        def queued_start?(name = nil)
          @changes.any? { |c| START_KINDS.include?(c.kind) && (name.nil? || c.subject == name) }
        end

        # Applies queued changes whose time is before +to+, each on its
        # exact sample.  Called by #process_buffer with the render lock held,
        # after scheduled blocks run (they may queue changes for this
        # buffer).
        def commit_due(from, to, per_sample)
          until @changes.empty? || @changes.first.time >= to
            c = @changes.shift
            idx = MB::M.max(((c.time - from) / per_sample).floor, 0)
            commit_change(c, land_pos: MB::M.max(c.time, from), land_frame: @frame + idx, commits: stamp(from, frame: @frame), immediate: false)
          end
        end

        # Applies a change, snapshotting its subject before and after (see
        # Undo) and recording that it landed.  Errors from changes applied
        # now are raised to the caller (with the change marked failed);
        # errors from queued changes on the render thread are printed (or
        # raised with +raise_errors+).
        def commit_change(c, land_pos:, land_frame:, commits:, immediate:)
          c.lands = stamp(land_pos, frame: land_frame)
          snapshot = !NO_SNAPSHOT_KINDS.include?(c.kind)
          c.before = undo_snapshot(c.subject) if snapshot
          @landing_frame = land_frame # for ramps that start on the landing sample (see Strip)
          # A past time (e.g. a scheduled block that ran late) is passed on,
          # so launch-aligned clips keep their anchor, as before the queue
          c.action.call(c.time || land_pos)
          c.after = undo_snapshot(c.subject) if snapshot
          @landing_frame = nil

          if immediate
            c.entry = @journal.add(c.entry.with(status: :landed, commits: commits, lands: c.lands))
          else
            @journal.note_landed(c.seq, commits: commits, lands: c.lands)
          end

        rescue => e
          @landing_frame = nil
          if immediate
            c.entry = @journal.add(c.entry.with(status: :failed, commits: commits, lands: c.lands, data: c.entry.data.merge(error: e.message)))
            raise
          end

          @journal.note_landed(c.seq, commits: commits, lands: c.lands, error: e.message)
          raise if @raise_errors
          warn "#{c.kind} #{c.subject.inspect} at #{c.lands} failed: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
