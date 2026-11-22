module MB
  module Sound
    class Session
      # Undo and redo for a Session's changes (see Changes): every console
      # command (#bg, #stop, #swap, #resume, #master, #mute, scene launches,
      # ...) is one undo step, and undoing it launches the state from before
      # it, at the next bar by default (+on: :now+ for right away).  Undo is
      # itself a change, so it is logged, quantized, and redoable.
      #
      # A step whose changes haven't landed yet is cancelled instead (right
      # away).
      #
      # Undo of a replaced or stopped graph brings back the same graph
      # object, so its node state is stale, as with #resume.  The undo and
      # redo lists keep at most UNDO_LIMIT steps, and drop the oldest steps
      # when they hold more than RETIRED_GRAPH_LIMIT graphs that are no
      # longer playing or resumable (graphs can be large).
      module Undo
        # The most undo steps kept (and redo steps).
        UNDO_LIMIT = 64

        # The most retired graphs (no longer playing or stopped for
        # #resume) the undo and redo lists may keep alive.
        RETIRED_GRAPH_LIMIT = 8

        # The state of one player name around a change: the current Player
        # (nil if not playing), the stopped Player kept for #resume, the clip
        # each clip source plays (or will play), and the mute/solo flags.
        PlayerState = Struct.new(:player, :stopped, :clips, :muted, :soloed, keyword_init: true)

        # The master effects around a change: the chain's block (nil for
        # bypass or a preset alone), mastering preset (nil for none), and
        # description.
        MasterState = Struct.new(:block, :description, :preset, keyword_init: true)

        # Every mute and solo flag around a change to all of them (subject
        # :strip, e.g. `solo` with no names).
        StripState = Struct.new(:muted, :soloed, keyword_init: true)

        # Undo subject of a player name's changes (#bg, #stop, #swap, ...):
        # its PlayerState.
        PlayerSubject = Data.define(:name)

        # The undo group of a running command (see #command, Context#command):
        # its Session, the changes it made, Set-level extras
        # ([participant, before, after]), and the queued changes of earlier
        # commands it cancelled (+cancelled+: a redefinition superseding a
        # queued one, a stop dropping a queued start; see
        # #note_command_cancel), which undoing it issues again.
        CommandGroup = Struct.new(:session, :changes, :extras, :warm_hold, :cancelled) do
          def initialize(session)
            super(session, [], [], nil, [])
          end
        end

        # A graph a cancelled change would have started (see
        # #restore_superseded), standing in for a Player in a PlayerState.
        PendingGraph = Data.define(:input, :description, :timeline_nodes)

        # How undo snapshots and restores one subject type: +snapshot+ and
        # +restore+ name Session methods, called as
        # `snapshot(subject)` (returns the state) and
        # `restore(subject, original_change, time)` (issues the change that
        # puts the state back; see #restore_change).
        SubjectKind = Data.define(:type, :snapshot, :restore)

        # A Session method `(change) -> subject or nil` that claims changes
        # for its subject type before the Symbol and player lookups (see
        # #snapshot_subject), tried in +order+.
        Claim = Data.define(:name, :order)

        @subject_kinds = {}
        @symbol_subjects = {}
        @claims = [].freeze

        # Undo subjects (session-core-1, design/notes/arrangement.md,
        # "Undo"): each module owning an undoable kind of state registers
        # its subject type here, next to the methods that snapshot and
        # restore it, so Undo dispatches through this table instead of
        # super chains (include order doesn't matter).  +symbol+ maps
        # changes whose subject is that Symbol (e.g. :master) to the
        # subject +type+.new.
        def self.subject(type, snapshot:, restore:, symbol: nil)
          raise ArgumentError, "#{type} is already an undo subject" if @subject_kinds.key?(type)
          @subject_kinds[type] = SubjectKind.new(type: type, snapshot: snapshot, restore: restore)
          @symbol_subjects[symbol] = type.new if symbol
        end

        # Registers +method+ as a claim (see Claim).
        def self.claim(method, order:)
          @claims = (@claims + [Claim.new(name: method, order: order)]).sort_by(&:order).freeze
        end

        # The registered SubjectKind of +subject+.
        def self.subject_kind(subject)
          @subject_kinds.fetch(subject.class) { raise ArgumentError, "Not an undo subject: #{subject.inspect}" }
        end

        # The registered subject for change subject +name+ if it is one of
        # the registered Symbols, else nil.
        def self.symbol_subject(name)
          name.is_a?(Symbol) ? @symbol_subjects[name] : nil
        end

        # The claims in order.
        def self.claims
          @claims
        end

        # The registered subject types (for specs).
        def self.subject_types
          @subject_kinds.keys
        end

        subject PlayerSubject, snapshot: :player_undo_snapshot, restore: :restore_player_change

        # One undo step: the changes one command made (see Changes::Change),
        # Set-level state around it (+extras+: [participant, before, after]
        # triples), and +cancelled+ changes: queued changes the step
        # cancelled (a step that undid queued changes, a `cancel queued:`,
        # or a command that superseded or dropped queued changes of earlier
        # commands), which reverting the step issues again.
        Step = Struct.new(:label, :changes, :extras, :cancelled, :line, keyword_init: true) do
          # The label and where the step's changes land, e.g. "go :drop
          # lands 9:1".
          def to_s
            stamps = changes.map { |c| c.lands || c.entry&.lands }.compact
            where = stamps.empty? ? '' : " lands #{stamps.min_by { |st| st.pos || 0 }}"
            where = ' (cancelled)' if stamps.empty? && cancelled
            "#{label}#{where}"
          end

          def inspect
            "#<#{self}>"
          end

          def pretty_print(q)
            q.text(inspect)
          end
        end

        # The undo steps, oldest first.
        def undo_steps
          @undo_lock.synchronize { @undo_stack.dup }
        end

        # The redo steps, most recently undone last.
        def redo_steps
          @undo_lock.synchronize { @redo_stack.dup }
        end

        # Undoes the last undo step (or the last +count+), landing at the
        # launch point (+on:+, +in:+, +at:+; see LaunchPoint; the next bar
        # by default, +on: :now+ for right away).
        # Returns the steps that redo them (whose labels say what was undone
        # and where it lands), or nil if there is nothing to undo.
        def undo(count = 1, at: nil, on: nil, in: nil, start_time: nil)
          point = LaunchPoint.of(binding) or return nil
          shift_steps(@undo_stack, @redo_stack, 'undo', count, point, start_time).tap { @arrangement&.sync_arms }
        end

        # Redoes the last undone step (or the last +count+).  See #undo.
        def redo(count = 1, at: nil, on: nil, in: nil, start_time: nil)
          point = LaunchPoint.of(binding) or return nil
          shift_steps(@redo_stack, @undo_stack, 'redo', count, point, start_time).tap { @arrangement&.sync_arms }
        end

        # Runs the block as one undoable command labeled +label+: every
        # change made inside it (on this thread, to this session) becomes
        # one undo step.  Nested commands join the outer one.  Returns the
        # block's value and the changes made, as [value, changes].
        def command(label)
          group = Session.context&.command
          return [yield, nil] if group && group.session.equal?(self)

          group = CommandGroup.new(self)
          value = Session.with_context_fields(command: group) { yield }

          unless group.changes.empty? && group.extras.empty? && group.cancelled.empty?
            push_step(label, group.changes, group.extras, cancelled: group.cancelled.empty? ? nil : group.cancelled)
          end
          @arrangement&.sync_arms # (arm states follow the monitors' players; see Arrangement::Arm)
          [value, group.changes]
        end

        # Records Set-level state around the current command (see #command)
        # for undo: +participant+ must respond to #restore_undo_state(state).
        def note_undo_extra(participant, before, after)
          group = Session.context&.command
          return unless group && group.session.equal?(self)

          existing = group.extras.find { |p, _, _| p.equal?(participant) }
          if existing
            existing[2] = after
          else
            group.extras << [participant, before, after]
          end
        end

        # The Player objects held by the undo and redo lists that are no
        # longer playing or resumable (for memory measurements).
        def retired_graphs
          live = live_inputs
          @undo_lock.synchronize { retired_inputs(@undo_stack + @redo_stack, live) }
        end

        private

        # Records that the running command (see #command) cancelled queued
        # change +c+ (a carrying rebuild superseded by a newer one, a start
        # dropped by a stop for now; see Session#add, #remove), so undoing
        # the command issues it again: undo steps back exactly one command
        # (the maintainer, 2026-11-22: "Having undo step back only one step
        # seems ideal"), also to a definition that was queued but never got
        # to play.  A change the command itself made is just dropped from
        # its step.  Called with @render_lock held.
        def note_command_cancel(c)
          group = Session.context&.command
          return unless group && group.session.equal?(self)

          if (i = group.changes.index { |g| g.equal?(c) })
            group.changes.delete_at(i)
          else
            group.cancelled << c
          end
        end

        def init_undo
          @undo_stack = []
          @redo_stack = []
          @undo_lock = Mutex.new
          @undo_inputs = [].freeze
          @undo_waiting = [].freeze
        end

        # Graph inputs the undo and redo lists hold (playing, kept for
        # #resume, or retired), for Strip#read_kept_graphs.  Updated by
        # #prune_steps after every change to the lists.
        def undo_inputs
          @undo_inputs
        end

        # Graphs that cancelled changes held by the undo and redo lists
        # would start (a superseded redefinition's, a start a stop dropped,
        # one an undo cancelled), which undo or redo may issue again or
        # restore (see #revert_step): Strip#catch_up_waiting keeps them in
        # step with shared nodes like graphs waiting in the queue, so they
        # can start after more than a second.  Updated by #prune_steps.
        def undo_waiting_graphs
          @undo_waiting
        end

        # Adds a command's changes as an undo step and clears the redo list.
        def push_step(label, changes, extras, cancelled: nil)
          source = changes.first&.entry&.source
          return if source == :undo

          @undo_lock.synchronize {
            @undo_stack << Step.new(label: label, changes: changes, extras: extras, cancelled: cancelled, line: changes.first&.entry&.line)
            @redo_stack.clear
          }
          prune_steps
        end

        # Drops the oldest steps beyond UNDO_LIMIT or RETIRED_GRAPH_LIMIT.
        def prune_steps
          live = live_inputs
          @undo_lock.synchronize {
            [@undo_stack, @redo_stack].each do |stack|
              stack.shift while stack.length > UNDO_LIMIT
            end
            while retired_inputs(@undo_stack + @redo_stack, live).length > RETIRED_GRAPH_LIMIT
              stack = @undo_stack.empty? ? @redo_stack : @undo_stack
              break if stack.empty?
              stack.shift
            end
            @undo_inputs = held_inputs(@undo_stack + @redo_stack).freeze
            @undo_waiting = cancelled_graphs(@undo_stack + @redo_stack).freeze
          }
        end

        # Inputs of graphs that play on (not being replaced or stopped) or
        # are kept for #resume.
        def live_inputs
          @mutex.synchronize { (@players.values.select(&:current?) + @stopped.values).map(&:input) }
        end

        # Distinct graph inputs held by +steps+' snapshots that aren't in
        # +live+.
        def retired_inputs(steps, live)
          held_inputs(steps).reject { |i| live.any? { |l| l.equal?(i) } }
        end

        # Distinct graph inputs held by +steps+' snapshots and cancelled
        # changes.
        def held_inputs(steps)
          (steps.flat_map { |s|
            (s.changes + (s.cancelled || [])).flat_map { |c| [c.before, c.after, c.base] }.grep(PlayerState).flat_map { |st| [st.player&.input, st.stopped&.input] }
          } + cancelled_graphs(steps)).compact.uniq(&:__id__)
        end

        # Distinct graphs that +steps+' cancelled changes would start (not
        # yet issued again).
        def cancelled_graphs(steps)
          steps.flat_map { |s| s.cancelled ? s.cancelled.map { |c| c.reissued ? nil : c.graph } : [] }.compact.uniq(&:__id__)
        end

        # Pops up to +count+ steps from +from+, launches the state from
        # before each one (cancelling changes that haven't landed), and
        # pushes the steps that do the reverse onto +to+.
        def shift_steps(from, to, verb, count, at, start_time)
          reverses = []
          count.times do
            step = @undo_lock.synchronize { from.pop }
            break if step.nil?

            reverse = revert_step(step, verb, at, start_time)
            @undo_lock.synchronize { to << reverse }
            reverses << reverse
          end
          prune_steps
          reverses.empty? ? nil : reverses
        end

        # Reverts one step (see #shift_steps).  Returns the step that would
        # revert this revert.
        #
        # One step back, always (undo-one-step-1; the maintainer,
        # 2026-11-22: "Having undo step back only one step seems ideal"):
        # the step's changes that landed restore their subjects from their
        # +before+ snapshots, those still waiting are cancelled, and the
        # queued changes of earlier commands the step cancelled (see
        # #note_command_cancel) are issued again, after the restores.  A
        # redefinition that superseded a queued one (Session#add) thus
        # steps back to that queued definition, whether or not it got to
        # play: re-queued while the newer one hadn't landed (still carrying
        # from the graph playing), else its graph restored in place of the
        # snapshot (#restore_superseded).  Before, undo restored what was
        # playing when the undone line ran, so lines faster than their
        # landings undid several redefinitions at once.
        def revert_step(step, verb, at, start_time)
          # Changes count as landed by the logical time (see #now), so a take
          # replaying lines ahead of time undoes the same way as live.  A
          # change issued again by an earlier undo or redo is reverted as
          # that issue.  A cancelled carrying rebuild (superseded by a later
          # command, or cancelled by an undo or a stop) restores the state
          # it would have replaced (Change#base), as if it had landed.
          logical_now = now
          landed, waiting = @render_lock.synchronize {
            live = step.changes.map { |c| current_issue(c) }
            live.select! { |c| c.entry&.status != :cancelled || (c.before ||= c.base) }
            l, w = live.partition { |c| c.lands || c.entry&.status == :cancelled || c.time.nil? || c.time <= logical_now }
            cancel_changes(*w)
            [l, w]
          }
          # (the launch point: restores land there, and changes issued again
          # whose own time has passed)
          point = nil
          point_time = -> { point ||= start_time ? start_time.to_r : launch_time(at, [], default: :bar) }
          time = landed.empty? && !start_time ? nil : point_time.call

          restores = []
          reissues = step.cancelled ? step.cancelled.dup : []
          Session.with_perform(source: :undo) do
            # The newest carrying rebuild (a redefinition) the step
            # superseded, for each player name
            superseded = reissues.select { |c| carrying_rebuild?(c) }.group_by { |c| snapshot_subject(c) }
              .select { |subject, _| subject.is_a?(PlayerSubject) }.transform_values { |list| list.max_by(&:seq) }
            bring_back = lambda { |subject, k, original, t|
              reissues.reject! { |c| Changes::START_KINDS.include?(c.kind) && c.seq <= k.seq && snapshot_subject(c) == subject }
              restores << restore_superseded(subject, k, original, t)
            }

            landed.reject { |c| Changes::NO_SNAPSHOT_KINDS.include?(c.kind) }.group_by { |c| snapshot_subject(c) }.each do |subject, list|
              first = list.min_by(&:seq)
              if (k = superseded.delete(subject))
                # (the newer definition landed: its graph replaced the one
                # the superseded rebuild would carry from)
                bring_back.call(subject, k, first, time)
              else
                restores << restore_change(subject, first, time)
              end
            end

            # A superseded rebuild is queued again where the graph it
            # carries from still plays (the newer definition never landed),
            # else its graph comes back in place of what plays
            superseded.each do |subject, k|
              bring_back.call(subject, k, nil, point_time.call) unless carry_base_playing?(subject.name, k)
            end

            # Changes cancelled by the step (or undone by cancelling them)
            # are issued again, after the restores (a queued change lands
            # on the state from before the step)
            reissues.each do |c|
              restores << reissue_change(c, c.time && c.time > now ? c.time : point_time.call)
            end
          end

          extras = step.extras.map { |participant, before, after|
            participant.restore_undo_state(before)
            [participant, after, before]
          }

          label = step.label.start_with?("#{verb == 'undo' ? 'redo' : 'undo'} ") ? step.label.sub(/\A\w+ /, '') : "#{verb} #{step.label}"
          Step.new(label: label, changes: restores, extras: extras, cancelled: waiting.empty? ? nil : waiting, line: Take.current_line_id)
        end

        # The change +c+ is now: itself, or the change an undo or redo
        # issued it again as (Change#reissued), and so on.
        def current_issue(c)
          c = c.reissued while c.reissued
          c
        end

        # Issues cancelled change +c+ again at +time+, as it was (its graph,
        # timeline nodes, buffer split, spill-over, and the queued change it
        # follows), journaled as undoing it; +c+ points to the new change.
        def reissue_change(c, time)
          follows = c.follows && current_issue(c.follows)
          c.reissued = change(c.kind, c.subject, time, data: c.entry.data, undoes: c.seq, starts: c.starts, graph: c.graph, split: c.split, spill: c.spill,
                              follows: follows, &c.action)
          c.reissued.carries = c.carries
          c.reissued.base = c.base
          c.reissued
        end

        # True for a carrying rebuild of a player's graph (a redefined
        # patch, a bind's or build knob's rebuild; Session#add).
        def carrying_rebuild?(c)
          c.kind == :bg && c.split && !c.graph.nil? && !c.carries.nil?
        end

        # True if carrying rebuild +k+, issued again now, would land on the
        # graph it carries from: that graph plays as +name+ and no other
        # start is queued for the name, or it follows a queued change that
        # starts that graph.
        def carry_base_playing?(name, k)
          @render_lock.synchronize {
            if (f = k.follows && current_issue(k.follows)) && @changes.any? { |c| c.equal?(f) }
              next f.graph.equal?(k.carries)
            end
            next false if @changes.any? { |c| c.subject == name && Changes::START_KINDS.include?(c.kind) }

            cur = @mutex.synchronize { @players.each_value.find { |p| p.name == name && p.current? } }
            !cur.nil? && cur.input.equal?(k.carries)
          }
        end

        # Puts player +subject+ back to the definition +superseded+ (a
        # carrying rebuild that a later command superseded before it
        # landed, Session#add) at +time+: the graph it would have started
        # comes back like an undone graph (a declick crossfade, or the
        # graph replaced spilling over), its notes from that time.  The
        # mute and solo flags are those from before +original+ (the landed
        # change of the step being undone), if given, else the name's own.
        def restore_superseded(subject, superseded, original, time)
          before = original&.before
          graph = PendingGraph.new(input: superseded.graph, description: superseded.entry.data[:description], timeline_nodes: superseded.starts || [])
          clips = graph.timeline_nodes.grep(MIDI::ClipSource).to_h { |n| [n, n.ring_clip || n.pending_clip || n.clip] }.compare_by_identity
          muted, soloed = before.is_a?(PlayerState) ? [before.muted, before.soloed] : [nil, nil] # (nil: left as they are)
          state = PlayerState.new(player: graph, stopped: nil, clips: clips, muted: muted, soloed: soloed)
          spill = !!(original || superseded).spill
          # (+graph+: kept in step with shared nodes while it waits, see
          # Strip#catch_up_waiting)
          change(:restore, subject.name, time, data: {}, undoes: (original || superseded).seq, starts: graph.timeline_nodes, graph: superseded.graph) { |t|
            restore_player(subject.name, state, t, spill: spill)
          }
        end

        # The subject whose state change +c+ snapshots for undo (a subject
        # type registered with Undo.subject): the first registered claim
        # that takes the change (CUE, buses and sends, seeks, knobs), else
        # the type registered for its subject Symbol (:master, :strip,
        # :timeline, :tempo, :key), else the player name (PlayerSubject).
        def snapshot_subject(c)
          Undo.claims.each do |claim|
            subject = __send__(claim.name, c)
            return subject if subject
          end
          Undo.symbol_subject(c.subject) || PlayerSubject.new(c.subject)
        end

        # Snapshots +subject+ (see #snapshot_subject) through its registered
        # snapshot method.  Called with @render_lock held.
        def undo_snapshot(subject)
          __send__(Undo.subject_kind(subject).snapshot, subject)
        end

        # Issues a change that puts +subject+ back the way it was before
        # +original+ (its +before+ snapshot, taken when it landed) at +time+,
        # through the subject's registered restore method.
        def restore_change(subject, original, time)
          __send__(Undo.subject_kind(subject).restore, subject, original, time)
        end

        # A player name's state (see PlayerState).  Called with
        # @render_lock held.
        def player_undo_snapshot(subject)
          name = subject.name
          @mutex.synchronize {
            player = @players.values.select { |p| p.name == name && p.current? }.last
            stopped = @stopped[name]
            nodes = (player || stopped)&.timeline_nodes&.grep(MIDI::ClipSource) || []
            PlayerState.new(
              player: player,
              stopped: stopped,
              clips: nodes.to_h { |n| [n, n.ring_clip || n.pending_clip || n.clip] }.compare_by_identity,
              muted: @muted.include?(name),
              soloed: @soloed.include?(name)
            )
          }
        end

        # Restores a player name (see #restore_player).
        def restore_player_change(subject, original, time)
          state = original.before
          starts = state.is_a?(PlayerState) && state.player ? state.player.timeline_nodes : nil
          change(:restore, subject.name, time, data: {}, undoes: original.seq, starts: starts) { |t|
            restore_player(subject.name, original.before, t, spill: !!original.spill)
          }
        end

        # Puts a player name back to +state+ at +time+ (applied by the change
        # queue).  Graphs switch with a declick crossfade, or, undoing a
        # change that spilled over (+spill+: a rebuild, a new instrument),
        # the graph replaced rings out under the one coming back (carry-1:
        # "Undo spills back"; a graph still spilling comes back as it is).
        def restore_player(name, state, time, spill: false)
          raise "Nothing to restore for #{name.inspect}" unless state.is_a?(PlayerState)
          declick = declick_bars

          @mutex.synchronize {
            current = @players.values.select { |p| p.name == name && p.current? }.last

            if state.player
              unless current&.input.equal?(state.player.input)
                @stopped.delete(name) if @stopped[name]&.input.equal?(state.player.input)
                @players.each_value do |p|
                  next unless p.name == name && p.current?
                  if spill && p.heard? && spillable?(p) && !p.input.equal?(state.player.input)
                    start_ringing(p, time, choke: true, spill: true)
                    @spills += 1
                  elsif p.heard? # (see Session#add_now)
                    p.stop_at = time
                    p.fade_out = declick
                  else
                    @players.delete(p.serial)
                  end
                end

                # A graph still ringing out comes back as it is (see Tails)
                old = state.player
                unless revive_ringing(name, time, input: old.input)
                  start_player(name: name, input: old.input, description: old.description, timeline_nodes: old.timeline_nodes, start: time, fade: current ? declick : nil)
                end
              end
            elsif current
              current.keep = true
              @players.each_value do |p|
                next unless p.name == name && p.current?
                p.stop_at = time
                p.fade_out = declick
              end
            elsif state.stopped && !@stopped.key?(name)
              # Undo of #forget: resumable again
              @stopped[name] = state.stopped
            end
          }

          state.clips.each do |node, clip|
            node.swap_clip(clip, time: time) unless (node.ring_clip || node.pending_clip || node.clip).equal?(clip)
          end

          strip_changed = false
          [[@muted, state.muted], [@soloed, state.soloed]].each do |set, flag|
            next if flag.nil? || set.include?(name) == flag
            flag ? set << name : set.delete(name)
            strip_changed = true
          end
          apply_strip(nil) if strip_changed
        end
      end
    end
  end
end
