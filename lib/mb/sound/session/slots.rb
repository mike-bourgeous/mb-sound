module MB
  module Sound
    class Session
      # Rack slots in a Session (racks R3; design/notes/racks.md, Slots):
      # slots join the Session's names when their graph plays (#adopt_slots),
      # and #swap_slot swaps a slot's content on an exact frame through the
      # change queue (journaled, undoable, replayed by takes), warmed in a
      # sandbox first, handing over by spill-over, crossfade, or cut
      # (Session::Handover, as master chains do).
      module Slots
        # Undo subject of a slot swap (subject: the slot name given to
        # #swap_slot, one slot or a group).
        SlotSubject = Data.define(:name)
        Undo.subject SlotSubject, snapshot: :slot_undo_snapshot, restore: :restore_slot_change

        # What a slot swap's undo puts back: [Slot, content] pairs (content:
        # the Proc or Rack that built the content playing before).
        SlotState = Data.define(:contents)

        Undo.claim :slot_undo_subject, order: 25

        # Contents waiting in the change queue to land (a :slot change's
        # graph, kept in step with nodes shared with playing graphs while
        # it waits; see Strip#catch_up_waiting).
        SlotGraph = Struct.new(:chains, :asleep_reads) do
          def input
            self
          end

          def graph(include_tees: true)
            chains.flat_map { |c| c.nodes.uniq(&:__id__).flat_map { |n| n.graph(include_tees: include_tees) } }.uniq
          end
        end

        # Gives the slots in +found+ (a graph's nodes, joining as player
        # +player+) their Session names: a rack's slots share their
        # instance's key with its knobs (:"dub/color", :"bass/dub/color";
        # see Racks#instance_member_names), an anonymous rack's and those
        # outside racks are the player's (:"bass/color"; :color without a
        # player).  Names claim the Session namespace as kind :slot (a
        # group, standing for every instance's slot, as :slot_group).
        # Returns the slots.
        def adopt_slots(found, player: nil)
          slots = []
          seen = {}.compare_by_identity
          found.each do |n|
            next unless n.is_a?(GraphNode::Slot::Output)
            s = n.owner_slot
            next if seen[s]
            seen[s] = true
            slots << s
          end
          return slots if slots.empty?

          prune_rack_knobs
          slots.each { |s| s.player = player }
          members = slots.select { |s| s.application && s.name }
          unless members.empty?
            names, renames = racks.instance_member_names(members, player)
            renames.each { |m, name| m.is_a?(GraphNode::Slot) ? rename_slot(m, name) : rename_knob(m, name) }
            names.each do |s, (name, rack, key)|
              s.instance_key = key
              claim_slot(s, name) or next
              group = racks.slot_joined(rack, key, s.name, s)
              @names.claim(group, :slot_group) if group
            end
          end
          slots.each do |s|
            next if s.application || s.name.nil?
            claim_slot(s, player.nil? ? s.name : Name.join(player, s.name)) or next
            racks.plain_slot_joined(s)
          end
          slots
        end

        # Swaps the content of slot +name+ (a slot's Session name, or a
        # group: every instance's slot) for +content+ (a Rack taking the
        # slot's signal, or a block or callable taking it) at a launch point
        # (+at:+, a LaunchPoint; the next bar while anything plays, like
        # #add), or at +start_time+ (whole notes).  The old content spills
        # over (+fade:+ nil, the default), crossfades over +fade:+ bars, or
        # is cut (+fade: 0+).  Each slot builds its own copy now (its rack
        # knobs join the Session as the player's), warmed in a sandbox
        # first (Session::Warming); the change lands on its exact frame.
        # Returns the Change.
        def swap_slot(name, content = nil, at: nil, on: nil, in: nil, fade: nil, start_time: nil, &block)
          raise IOError, 'Session is closed' if @closed
          point = LaunchPoint.of(binding) or return nil
          content ||= block
          raise ArgumentError, "swap #{name.inspect} needs the new content: a rack (arack { |s| ... }) or a block" if content.nil?
          content = slot_content(name, content)
          targets = racks.slots_for(name)
          if targets.empty?
            known = racks.slot_names
            raise ArgumentError, "No slot named #{name.inspect} is playing#{MB::Sound::Rack.suggest(name, known)}#{" (slots: #{known.map(&:inspect).join(', ')})" unless known.empty?}"
          end
          mode, bars = master_mode(fade)
          built = targets.map { |s| [s, build_slot_content(s, content)] }
          chains = built.map(&:last)
          desc = "swap #{name.inspect} -> #{chains.first.description}"
          warm_slot_swap(content, targets.first, chains.first, warm_time(point, start_time))

          time = start_time ? start_time.to_r : launch_time(point, chains.flat_map(&:timeline_nodes))
          c = change(:slot, name, time, data: { description: desc, fade: fade }, graph: SlotGraph.new(chains, nil)) { |_t|
            land_slot_swap(built, mode, bars)
          }
          start_thread if @realtime
          c
        end

        # Called by a Slot when content +chain+ starts, +offset+ frames into
        # the slot's buffer (on the render thread): its branches of shared
        # nodes read the frames before it, as a player starting inside a
        # buffer does (Strip#catch_up_started), and its timeline nodes join
        # its player's (so seeks and wakes move them).
        def slot_started(slot, chain, offset)
          @waiting_slots.delete(slot) if slot.waiting.empty?
          catch_up_graph(chain.chain_graph, offset)
          return if chain.timeline_nodes.empty? || slot.player.nil?

          @mutex.synchronize {
            p = @players.each_value.find { |pl| pl.name == slot.player && pl.current? }
            p.timeline_nodes = (p.timeline_nodes + chain.timeline_nodes).uniq if p
          }
        end

        # Called by a Slot when old contents were dropped (on the render
        # thread).
        def slot_dropped(slot)
          nil
        end

        private

        # Claims +name+ for slot +s+ (kind :slot), returning it, or nil if
        # the name is taken by something else (through live_error).
        def claim_slot(s, name)
          return nil unless @names.claim(name, :slot)
          s.path = name
          name
        end

        # Gives slot +s+ the Session name +name+ (its rack became per
        # instance; see Racks#instance_member_names).
        def rename_slot(s, name)
          old = s.path
          @names.release(old) if old && @names.kind(old) == :slot
          claim_slot(s, name)
          warn "slot #{old.inspect} is #{name.inspect} now (the rack plays in several players)" if old && MB::Sound.live?
        end

        # Content given to #swap_slot as something a Slot builds: Racks
        # taking audio, Procs and callables as they are.
        def slot_content(name, content)
          case content
          when MB::Sound::Rack
            unless content.input.type == :audio
              raise ArgumentError, "slot #{name.inspect} carries audio; #{content.label} takes #{content.input.type} (swap in an arack)"
            end
            content
          when Proc, Method then content
          else
            raise ArgumentError, "swap #{name.inspect}: the new content is a rack or a block taking the signal (got #{content.class})" unless content.respond_to?(:call)
            content
          end
        end

        # Builds +content+ for slot +s+ (a Master::Chain), recording it as
        # the slot's `slot` call so documents print it once it plays, its
        # rack knobs joining the Session as its player's.
        def build_slot_content(s, content)
          block = content.is_a?(MB::Sound::Rack) ? ->(sig) { content.call(sig) } : content
          chain = nil
          if s.receiver && s.result
            rec = s.result.instance_variable_get(:@graph_recipe)
            saved = rec&.call
            rec.call = nil if rec
            GraphNode::Recipe.call(s.receiver, :slot, [s.name], {}, block, kind: :build) { |blk|
              chain = s.build(blk)
              s.result
            }
            chain.recipe = rec&.call
            rec.call = saved if rec
          else
            chain = s.build(block)
          end
          chain.block = content
          found = chain.nodes.uniq(&:__id__).flat_map { |n| [n, *n.graph] }
          adopt_knobs(chain.nodes, player: s.player, found: found)
          chain
        end

        # Lands a swap (in its change, under the render lock): each slot
        # gets its content to start on the landing frame.
        def land_slot_swap(built, mode, bars)
          frame = @landing_frame || @frame
          step = mode == :fade ? fade_step(bars, output_open? ? sample_rate : 48000) : 1.0
          built.each do |s, chain|
            s.queue(chain, frame, mode: mode, step: step, session: self)
            @waiting_slots[s] = true
          end
        end

        # The graphs of slot contents that landed but haven't started (see
        # Strip#catch_up_waiting).
        def slot_waiting_graphs
          return [] if @waiting_slots.empty?
          @waiting_slots.keys.flat_map { |s| s.waiting.map(&:chain_graph) }
        end

        # A slot swap's subject (see Undo.claim).
        def slot_undo_subject(c)
          SlotSubject.new(c.subject) if c.kind == :slot
        end

        # The contents of the slots +subject+ names (a SlotState).
        def slot_undo_snapshot(subject)
          SlotState.new(contents: racks.slots_for(subject.name).map { |s| [s, s.latest.block] })
        end

        # Puts the slots back to their contents before +original+ at
        # +time+ (rebuilt from what built them, handed over as the swap
        # was).
        def restore_slot_change(subject, original, time)
          state = original.before
          return nil unless state.is_a?(SlotState)
          fade = original.entry.data[:fade]
          mode, bars = master_mode(fade)
          built = state.contents.map { |s, content| [s, build_slot_content(s, content)] }
          desc = "swap #{subject.name.inspect} -> #{built.first&.last&.description}"
          change(:slot, subject.name, time, data: { description: desc, fade: fade }, undoes: original.seq, graph: SlotGraph.new(built.map(&:last), nil)) { |_t|
            land_slot_swap(built, mode, bars)
          }
        end

        # Warms a slot swap (see Warming): in a sandbox, a copy of the
        # content swaps into a slot playing a noise stand-in, so the
        # content's code and the handover compile before it lands live.
        def warm_slot_swap(content, slot, chain, at)
          return unless warming?
          warm(:slot, slot.path, chain.nodes, at) { |box, land, _, live|
            noise = warm_noise
            noise = noise.stereo if slot.input_channels > 1
            box.add(noise.slot(:warm) { |x| x }, name: :warm_slot, start_time: 0r)
            box.swap_slot(:"warm_slot/warm", content, start_time: land)
            copy = box.racks.slots_for(:"warm_slot/warm").flat_map { |s| s.waiting.flat_map { |c| c.nodes.flat_map { |n| [n, *n.graph] } } }
            next :built if warm_shares?(copy, live)
            :played
          }
        end

        def init_slots
          @waiting_slots = {}.compare_by_identity
        end
      end
    end
  end
end
