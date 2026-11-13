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

        # Undo subject of the instance swaps of a re-defined named rack
        # (subject: the rack's name; see #swap_rack_instances).
        RackSubject = Data.define(:name)
        Undo.subject RackSubject, snapshot: :rack_undo_snapshot, restore: :restore_rack_change

        # What a slot swap's undo puts back: [Slot, content] pairs (content:
        # the Proc or Rack that built the content playing before).
        SlotState = Data.define(:contents)

        Undo.claim :slot_undo_subject, order: 25
        Undo.claim :rack_undo_subject, order: 26

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

          # (no pruning here: #adopt_knobs pruned before this graph's rack
          # knobs joined, and its player isn't queued yet; forgotten
          # players' slots go with Knobs#prune_rack_knobs)
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
          targets = racks.slots_for(name)
          if targets.empty?
            known = racks.slot_names
            raise ArgumentError, "No slot named #{name.inspect} is playing#{MB::Sound::Rack.suggest(name, known)}#{" (slots: #{known.map(&:inspect).join(', ')})" unless known.empty?}"
          end
          content = slot_content(name, content, targets.first.notes? ? :notes : :audio)
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

        # Swaps the playing instances of named rack +name+ for instances of
        # +rack+ (its new definition), each on the same input with the same
        # extra port values, at a launch point (+at:+ a LaunchPoint, else
        # the next bar while anything plays) or +start_time+, handing over
        # as #swap_slot does (+fade:+).  Each new instance's rack knobs join
        # the old instance's (same names, values kept).  Instances in
        # players that aren't playing (stopped for resume) keep theirs.
        # Returns the Change, or nil if no instance plays.  Called by
        # Racks#redefine inside its undo step.
        def swap_rack_instances(name, rack, at: nil, on: nil, in: nil, fade: nil, start_time: nil)
          raise IOError, 'Session is closed' if @closed
          point = LaunchPoint.of(binding) or return nil
          slots = rack_instance_slots(name)
          return nil if slots.empty?

          mode, bars = master_mode(fade)
          built = slots.filter_map do |sl|
            [sl, build_instance_content(sl, rack)]
          rescue ArgumentError, TypeError, NoMethodError => e
            MB::Sound.live_error(e)
            nil
          end
          return nil if built.empty?
          chains = built.map(&:last)
          desc = "rack #{name.inspect} -> #{built.length} instance#{'s' if built.length != 1}"
          warm_rack_swap(rack, built.first[0], chains.first, warm_time(point, start_time))
          time = start_time ? start_time.to_r : launch_time(point, chains.flat_map(&:timeline_nodes))
          c = change(:rack, name, time, data: { description: desc, fade: fade }, graph: SlotGraph.new(chains, nil)) { |_t|
            land_slot_swap(built, mode, bars)
          }
          start_thread if @realtime
          c
        end

        # The instance slots of named rack +name+ in the graphs of the
        # players playing (GraphNode::Slot made by MB::Sound::Rack#call).
        def rack_instance_slots(name)
          players = @mutex.synchronize { @players.values.select(&:current?) }
          found = []
          seen = {}.compare_by_identity
          players.each do |p|
            p.input.nodes.flat_map { |n| [n, *n.graph] }.each do |n|
              next unless n.is_a?(GraphNode::Slot::Output)
              sl = n.owner_slot
              next if seen[sl] || sl.instance_of&.name != name
              seen[sl] = true
              found << sl
            end
          end
          found
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
        def slot_content(name, content, type = :audio)
          case content
          when MB::Sound::Rack
            unless content.input.type == type
              raise ArgumentError, "slot #{name.inspect} takes #{type}; #{content.label} takes #{content.input.type} (swap in #{type == :audio ? 'an arack' : 'an irack'})"
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
            fresh = rec&.call
            if fresh && saved
              # (in the original call's place: inside the rack application's
              # block that made the slot, in its order)
              fresh.scope = saved.scope
              fresh.seq = saved.seq
              fresh.ordinal = saved.ordinal
            end
            chain.recipe = fresh
            rec.call = saved if rec
          else
            chain = s.build(block)
          end
          chain.block = content
          found = chain.nodes.uniq(&:__id__).flat_map { |n| [n, *n.graph] }
          adopt_knobs(chain.nodes, player: s.player, found: found)
          adopt_slots(found, player: s.player) # (slots inside the new content)
          chain
        end

        # A new instance of +rack+ for instance slot +sl+ (a Master::Chain):
        # built on the slot's stand-in with the old instance's extra port
        # values, under a new seed, as a new Rack::Application keeping the
        # old one's instance key (so its rack knobs join the same names);
        # recorded as the old `then` call with the new rack, so documents
        # print the new definition once it plays.
        def build_instance_content(sl, rack)
          old = sl.instance_of
          kw = sl.instance_ports.select { |k, _| rack.ports.key?(k) }
          missing = rack.ports.select { |k, p| p.required && !kw.key?(k) }.keys
          raise ArgumentError, "#{rack.label}: the instance in #{sl.player.inspect} has no value for port#{'s' if missing.length > 1} #{missing.join(', ')} (apply it again with .with(...))" unless missing.empty?
          want = sl.notes? ? :notes : :audio
          if rack.input.type != want
            raise ArgumentError, "#{rack.label} takes #{rack.input.type} now; instances playing take #{want} (they keep playing as they were)"
          end

          seed = Internal.root_rng.rand(1 << 62)
          app = MB::Sound::Rack::Application.new(rack, start: old&.settings&.[](:knobs) || {})
          racks.inherit_key(app, sl.application)
          applied = rack.using(seed: seed)
          block = rack.block
          content = ->(feed) {
            MB::Sound::Rack.applying(app) { MB::Sound.with_seed(seed) { kw.empty? ? block.call(feed) : block.call(feed, **kw) } }
          }
          chain = GraphNode::Recipe.quietly { sl.build(content) }
          chain.block = content
          chain.instance = applied.send(:copy, settings: applied.settings.merge(drawn: true, application: app))
          chain.description = "rack #{rack.name.inspect}"
          rec = sl.result&.instance_variable_get(:@graph_recipe)
          if rec&.call
            fresh = rec.call.dup
            fresh.args = [chain.instance]
            fresh.block = block
            chain.recipe = fresh
          end
          found = chain.nodes.uniq(&:__id__).flat_map { |n| [n, *n.graph] }
          adopt_knobs(chain.nodes, player: sl.player, found: found)
          adopt_slots(found, player: sl.player) # (the new definition's slots take the old ones' names)
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

        # A rack re-definition's subject (see Undo.claim).
        def rack_undo_subject(c)
          RackSubject.new(c.subject) if c.kind == :rack
        end

        # What the instances of the rack +subject+ names play (a SlotState
        # of [Slot, the Rack applied]).
        def rack_undo_snapshot(subject)
          SlotState.new(contents: rack_instance_slots(subject.name).map { |sl| [sl, sl.latest.instance || sl.instance_of] })
        end

        # Puts the rack's instances back to the definitions they played
        # before +original+ (rebuilt), handed over as the swap was.
        def restore_rack_change(subject, original, time)
          state = original.before
          return nil unless state.is_a?(SlotState)
          fade = original.entry.data[:fade]
          mode, bars = master_mode(fade)
          built = state.contents.filter_map { |sl, applied| applied && [sl, build_instance_content(sl, applied)] }
          desc = "rack #{subject.name.inspect} -> #{built.length} instance#{'s' if built.length != 1}"
          change(:rack, subject.name, time, data: { description: desc, fade: fade }, undoes: original.seq, graph: SlotGraph.new(built.map(&:last), nil)) { |_t|
            land_slot_swap(built, mode, bars)
          }
        end

        # Warms a rack re-definition's instance swap (see #warm_slot_swap):
        # in a sandbox, an instance of the rack as it plays (+slot+'s rack,
        # with its port values) on a noise stand-in swaps to +rack+.
        def warm_rack_swap(rack, slot, chain, at)
          return unless warming?
          old = slot.instance_of
          return unless old
          warm(:slot, rack.name, chain.nodes, at) { |box, land, _, live|
            box.add(warm_input(slot).then(&old), name: :warm_slot, start_time: 0r)
            box.swap_rack_instances(rack.name, rack, start_time: land)
            copy = box.racks.instance_variable_get(:@session).send(:rack_instance_slots, rack.name).flat_map { |s| s.waiting.flat_map { |c| c.nodes.flat_map { |n| [n, *n.graph] } } }
            next :built if warm_shares?(copy, live)
            :played
          }
        end

        # Warms a slot swap (see Warming): in a sandbox, a copy of the
        # content swaps into a slot playing a noise stand-in, so the
        # content's code and the handover compile before it lands live.
        def warm_slot_swap(content, slot, chain, at)
          return unless warming?
          now = slot.current.block
          playing = now.is_a?(MB::Sound::Rack) ? ->(x) { now.call(x) } : now
          warm(:slot, slot.path, chain.nodes, at) { |box, land, _, live|
            # (the slot's content playing now spills over, or fades, as it
            # will live)
            box.add(warm_input(slot).slot(:warm, &playing), name: :warm_slot, start_time: 0r)
            box.swap_slot(:"warm_slot/warm", content, start_time: land)
            copy = box.racks.slots_for(:"warm_slot/warm").flat_map { |s| s.chains.flat_map { |c| c.nodes.flat_map { |n| [n, *n.graph] } } + s.waiting.flat_map { |c| c.nodes.flat_map { |n| [n, *n.graph] } } }
            next :built if warm_shares?(copy, live)
            :played
          }
        end

        # A stand-in for +slot+'s input in a warm-up: noise (a stereo pair
        # for a stereo slot), or for an instrument slot a looping chord of
        # notes (as Notes when the slot's input is Notes).
        def warm_input(slot)
          if slot.notes?
            clip = MB::Sound.seq([MB::Sound::C4, MB::Sound::E4], MB::Sound::G4, MB::Sound::C5).n8.loop
            return slot.instance_variable_get(:@notes_in).is_a?(MB::Sound::Notes) ? clip.notes : clip.notes.stream
          end
          noise = warm_noise
          slot.input_channels > 1 ? noise.stereo : noise
        end

        def init_slots
          @waiting_slots = {}.compare_by_identity
        end
      end
    end
  end
end
