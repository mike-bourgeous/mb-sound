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
        # Raised (through MB::Sound.live_error) by a change made by a
        # scheduled block that finished after its time, when the change's
        # time has already passed (see #change and Scheduler#lookahead).
        class LateChange < RuntimeError; end

        # A change waiting in the queue (or applied).  +time+ is the landing
        # position in whole notes (nil for "now").  +action+ is called with
        # the landing time to apply it.  +before+ and +after+ are snapshots
        # of the subject around the change, for undo.  +starts+ is the
        # timeline nodes of a graph the change starts (for swaps queued
        # behind it).  +graph+ is the graph input a :bg change starts, or
        # the Master::ChainGraph of a master chain a :master (or master
        # :restore) change starts (kept in step with shared nodes while it
        # waits; see Strip#catch_up_waiting).  +split+ is true for a change
        # that splits the buffer on its frame (a graph swap carrying
        # running state; see Carry).
        Change = Struct.new(
          :seq, :kind, :subject, :time, :action, :entry, :before, :after, :lands, :starts, :graph, :split,
          keyword_init: true
        )

        # Change kinds that start a player (so a queued one keeps the
        # timeline moving while nothing else plays).
        START_KINDS = [:bg, :resume, :restore, :launch].freeze # (:launch: a cue player becoming the name; see Cue)

        # Change kinds whose subject isn't a player or :master (no undo
        # snapshots; e.g. scene launches, whose players' changes are
        # separate).
        NO_SNAPSHOT_KINDS = [:scene, :skip, :snap, :rec, :arm, :disarm, :learn, :record, :stop_record].freeze

        # The Journal of changes made to this Session.
        attr_reader :journal

        # The session frame: how many frames have been rendered since the
        # Session was created (see Stamp).
        attr_reader :frame

        # The Stamp of the next frame to render: the frame counter and
        # timeline position where a change made right now lands (see also
        # #transport_record).
        def clock
          @render_lock.synchronize { Stamp.at(@transport.position, @transport, frame: @frame) }
        end

        # The per-buffer transport record (contract K1): the frame and
        # timeline position of the next buffer, the tempo, the bar length,
        # and whether the timeline is moving.
        def transport_record
          @transport_record
        end

        # A Stamp for timeline position +pos+ (frame unknown unless given).
        def stamp(pos, frame: nil)
          Stamp.at(pos, @transport, frame: frame)
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
        def change(kind, subject, time, data: {}, undoes: nil, starts: nil, graph: nil, split: false, &action)
          raise IOError, 'Session is closed' if @closed
          raise ArgumentError, 'Pass a block to apply the change' unless action

          perform = Session.perform
          perform = nil unless perform&.[](:session).equal?(self)
          if perform&.[](:forced)
            forced = perform[:forced].shift
            if forced.nil?
              warn "Replay: #{kind} #{subject.inspect} wasn't in the take; it lands where it resolves now" unless perform[:overrun_warned]
              perform[:overrun_warned] = true
            elsif forced.is_a?(Array)
              # Landed at forced[0] for an earlier time forced[1] (e.g. a
              # track with lead: launched now): the action gets the
              # earlier time, as it did live (see Take.note_change)
              time, given = forced
              given = given.to_r
              inner = action
              action = ->(_t) { inner.call(given) }
            else
              time = forced
            end
          end
          time = time&.to_r

          source = perform&.[](:source) || Session.context&.[](:source) || :console
          line = perform&.[](:line) || Take.current_line_id

          c = nil
          @render_lock.synchronize {
            # Changes already queued for a time this one would land at or
            # after land first, in queue order (see #commit_queued_due)
            commit_queued_due if time.nil? || time <= @transport.position
            pos = @transport.position
            check_late(kind, subject, time, pos) unless perform&.[](:forced)
            seq = @journal.next_seq
            c = Change.new(seq: seq, kind: kind, subject: subject, time: time, action: action, starts: starts, graph: graph, split: split)

            c.entry = @journal.add(Journal::Entry.new(
              seq: seq, kind: kind, subject: subject,
              issued: Stamp.at(perform&.[](:now) || now_unlocked(pos), @transport, frame: @frame),
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

        # Runs the block under the render lock (between buffers), e.g. to
        # move the timeline and launch what plays there as one step (see
        # Form::Playback#seek).  Returns the block's value.
        def with_render_lock(&block)
          @render_lock.synchronize(&block)
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
          @changes.any? { |c| START_KINDS.include?(c.kind) && (name.nil? || c.subject == name) && !knob_change?(c) }
        end

        # Lands queued changes whose time has come (at or before the
        # current position) now, in queue order, before a change that lands
        # now (see #change): when the position reaches a queued change's
        # time between buffers (a buffer ending on its bar line, or a seek
        # landing now), it is due, and was issued first, so it lands first,
        # as #commit_due and #commit_due_seeks order changes of the same
        # time (fixes-ui-specs, 2026-10-17: `go :both` queued for 2:1, then
        # `seek 2` and `go :none` landing at 2:1 now: :none stopped :y,
        # and the scene's swap of :y failed on the next buffer).  Called
        # with the render lock held, outside any console command's undo
        # step (the changes belong to whoever queued them).
        def commit_queued_due
          return if @changes.empty? || @changes.first.time > @transport.position
          without_command do
            while (c = @changes.first) && c.time <= @transport.position
              @changes.shift
              pos = @transport.position
              commit_change(c, land_pos: pos, land_frame: @frame, commits: stamp(pos, frame: @frame), immediate: false)
            end
          end
        end

        # Applies queued changes whose time is before +to+, each on its
        # exact sample.  Called by #process_buffer with the render lock held,
        # after scheduled blocks run (they may queue changes for this
        # buffer).
        def commit_due(from, to, per_sample)
          # Timeline changes wait for the start of a span (see
          # #process_buffer and Seeks); later changes wait behind them
          until @changes.empty? || @changes.first.time >= to || timeline_change?(@changes.first)
            c = @changes.shift
            idx = MB::M.max(Sequence::Transport.frame_at(c.time, from, per_sample), 0)
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
          c.before = undo_snapshot(snapshot_subject(c)) if snapshot
          @landing_frame = land_frame # for ramps that start on the landing sample (see Strip)
          # A past time (e.g. a scheduled block that ran late) is passed on,
          # so launch-aligned clips keep their anchor, as before the queue
          c.action.call(c.time || land_pos)
          c.after = undo_snapshot(snapshot_subject(c)) if snapshot
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

        # A change made by a scheduled block that runs after its time (see
        # Scheduler#run) whose own time has passed would land late: in live
        # mode it warns and lands now (late); in scripts and specs it raises
        # LateChange (MB::Sound.live_error) before landing, so the block
        # stops there and the scheduler reports it (or raises it with
        # +raise_errors+).  Changes of blocks that run when their time has
        # already come (nothing was playing) land now as usual.
        def check_late(kind, subject, time, pos)
          late = Thread.current[:mb_sound_schedule_deadline]
          return unless late && late[0].equal?(self) && time && time < pos

          ms = (@transport.seconds_of(pos - time) * 1000).to_f.round
          MB::Sound.live_error(LateChange.new(
            "#{kind} #{subject.inspect} for #{Stamp.at(time, @transport)} would land #{ms} ms late: the scheduled block for #{late[1]} " \
            "was still running at its time (lookahead #{MB::M.sigfigs((@scheduler.lookahead_whole_notes / @transport.bar_length).to_f, 3)} bars; " \
            'see Session#lookahead)'
          ))
        end
      end
    end
  end
end
