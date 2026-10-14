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
        # bypass) and description.
        MasterState = Struct.new(:block, :description, keyword_init: true)

        # Every mute and solo flag around a change to all of them (subject
        # :strip, e.g. `solo` with no names).
        StripState = Struct.new(:muted, :soloed, keyword_init: true)

        # One undo step: the changes one command made (see Changes::Change),
        # Set-level state around it (+extras+: [participant, before, after]
        # triples), and +cancelled+ changes (a step that undid queued
        # changes, which redo issues again).
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
          shift_steps(@undo_stack, @redo_stack, 'undo', count, point, start_time)
        end

        # Redoes the last undone step (or the last +count+).  See #undo.
        def redo(count = 1, at: nil, on: nil, in: nil, start_time: nil)
          point = LaunchPoint.of(binding) or return nil
          shift_steps(@redo_stack, @undo_stack, 'redo', count, point, start_time)
        end

        # Runs the block as one undoable command labeled +label+: every
        # change made inside it (on this thread, to this session) becomes
        # one undo step.  Nested commands join the outer one.  Returns the
        # block's value and the changes made, as [value, changes].
        def command(label)
          group = Thread.current[:mb_sound_command]
          return [yield, nil] if group && group[:session].equal?(self)

          group = { session: self, changes: [], extras: [] }
          old = Thread.current[:mb_sound_command]
          Thread.current[:mb_sound_command] = group
          begin
            value = yield
          ensure
            Thread.current[:mb_sound_command] = old
          end

          push_step(label, group[:changes], group[:extras]) unless group[:changes].empty? && group[:extras].empty?
          [value, group[:changes]]
        end

        # Records Set-level state around the current command (see #command)
        # for undo: +participant+ must respond to #restore_undo_state(state).
        def note_undo_extra(participant, before, after)
          group = Thread.current[:mb_sound_command]
          return unless group && group[:session].equal?(self)

          existing = group[:extras].find { |p, _, _| p.equal?(participant) }
          if existing
            existing[2] = after
          else
            group[:extras] << [participant, before, after]
          end
        end

        # The Player objects held by the undo and redo lists that are no
        # longer playing or resumable (for memory measurements).
        def retired_graphs
          live = live_inputs
          @undo_lock.synchronize { retired_inputs(@undo_stack + @redo_stack, live) }
        end

        private

        def init_undo
          @undo_stack = []
          @redo_stack = []
          @undo_lock = Mutex.new
          @undo_inputs = [].freeze
        end

        # Graph inputs the undo and redo lists hold (playing, kept for
        # #resume, or retired), for Strip#read_kept_graphs.  Updated by
        # #prune_steps after every change to the lists.
        def undo_inputs
          @undo_inputs
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

        # Distinct graph inputs held by +steps+' snapshots.
        def held_inputs(steps)
          steps.flat_map { |s|
            s.changes.flat_map { |c| [c.before, c.after] }.grep(PlayerState).flat_map { |st| [st.player&.input, st.stopped&.input] }
          }.compact.uniq(&:__id__)
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
        def revert_step(step, verb, at, start_time)
          # Changes count as landed by the logical time (see #now), so a take
          # replaying lines ahead of time undoes the same way as live
          logical_now = now
          landed, waiting = @render_lock.synchronize {
            l, w = step.changes.partition { |c| c.lands ? true : c.time.nil? || c.time <= logical_now }
            cancel_changes(*w)
            [l, w]
          }
          time = start_time ? start_time.to_r : (landed.empty? ? nil : launch_time(at, [], default: :bar))

          restores = []
          Session.with_perform(source: :undo) do
            # Changes undone by cancelling them are issued again on redo
            step.cancelled&.each do |c|
              restores << change(c.kind, c.subject, c.time && c.time > now ? c.time : time, data: c.entry.data, undoes: c.seq, starts: c.starts, &c.action)
            end

            landed.reject { |c| Changes::NO_SNAPSHOT_KINDS.include?(c.kind) }.group_by { |c| snapshot_subject(c) }.each do |subject, list|
              first = list.min_by(&:seq)
              restores << restore_change(subject, first, time)
            end
          end

          extras = step.extras.map { |participant, before, after|
            participant.restore_undo_state(before)
            [participant, after, before]
          }

          label = step.label.start_with?("#{verb == 'undo' ? 'redo' : 'undo'} ") ? step.label.sub(/\A\w+ /, '') : "#{verb} #{step.label}"
          Step.new(label: label, changes: restores, extras: extras, cancelled: waiting.empty? ? nil : waiting, line: Take.current_line_id)
        end

        # Issues a change that puts +subject+ back the way it was before
        # +original+ (its +before+ snapshot, taken when it landed) at +time+.
        def restore_change(subject, original, time)
          if subject == :master
            state = original.before
            chain = state.is_a?(MasterState) ? build_master(state.block, description: state.description) : nil
            return change(:restore, :master, time, data: { description: state&.description }, undoes: original.seq, graph: chain&.chain_graph) { |t|
              if chain.nil?
                st = original.before
                chain = build_master(st&.block, description: st&.description)
              end
              start_master(chain, t)
            }
          end

          if subject == :strip
            return change(:restore, :strip, time, data: {}, undoes: original.seq) { |_t| restore_strip(original.before) }
          end

          if subject == :timeline
            return change(:restore, :timeline, time, data: {}, undoes: original.seq) { |_t| restore_timeline(original.before) }
          end

          if subject.is_a?(Knobs::KnobSubject)
            return change(:restore, subject.name, time, data: { knob: true }, undoes: original.seq) { |_t| restore_knob(subject.name, original.before) }
          end

          state = original.before
          starts = state.is_a?(PlayerState) && state.player ? state.player.timeline_nodes : nil
          change(:restore, subject, time, data: {}, undoes: original.seq, starts: starts) { |t|
            restore_player(subject, original.before, t)
          }
        end

        # Snapshots a change's subject (see PlayerState and MasterState).
        # Called with @render_lock held.
        def undo_snapshot(subject)
          return knob_snapshot(subject) if subject.is_a?(Knobs::KnobSubject)
          return StripState.new(muted: @muted.dup, soloed: @soloed.dup) if subject == :strip
          return timeline_snapshot if subject == :timeline

          if subject == :master
            chain = @mutex.synchronize { @master_chains&.last }
            return MasterState.new(block: chain&.block, description: chain&.description || 'bypass')
          end

          @mutex.synchronize {
            player = @players.values.select { |p| p.name == subject && p.current? }.last
            stopped = @stopped[subject]
            nodes = (player || stopped)&.timeline_nodes&.grep(MIDI::ClipSource) || []
            PlayerState.new(
              player: player,
              stopped: stopped,
              clips: nodes.to_h { |n| [n, n.ring_clip || n.pending_clip || n.clip] }.compare_by_identity,
              muted: @muted.include?(subject),
              soloed: @soloed.include?(subject)
            )
          }
        end

        # Puts a player name back to +state+ at +time+ (applied by the change
        # queue).  Graphs switch with a declick crossfade.
        def restore_player(name, state, time)
          raise "Nothing to restore for #{name.inspect}" unless state.is_a?(PlayerState)
          declick = declick_bars

          @mutex.synchronize {
            current = @players.values.select { |p| p.name == name && p.current? }.last

            if state.player
              unless current&.input.equal?(state.player.input)
                @stopped.delete(name) if @stopped[name]&.input.equal?(state.player.input)
                @players.each_value do |p|
                  next unless p.name == name && p.current?
                  if p.started
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
            next if set.include?(name) == flag
            flag ? set << name : set.delete(name)
            strip_changed = true
          end
          apply_strip(nil) if strip_changed
        end
      end
    end
  end
end
