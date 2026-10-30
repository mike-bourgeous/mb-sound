module MB
  module Sound
    class Session
      # Running state carried from a player's graph into the graph that
      # replaces it (sound-design-2; the maintainer: "carry the running
      # state ... so a bind mid-note doesn't restart or click"): a `bind` or
      # a build knob's turn rebuilds a track's patch, and #add with +carry:
      # true+ matches the new graph's nodes to the old graph's and, on the
      # swap frame, copies each matched node's state (Plan::Describable's
      # plan_snapshot/plan_restore, the same protocol plans and the render
      # pane's copies use) and each Synth's voice allocation, so held notes
      # play on in the same voices with their oscillator phases, envelope
      # stages and levels, filter states, and glides.
      #
      # Matching (.plan, on the building thread): from the graphs' outputs,
      # nodes of the same class at the same place (the same source name
      # from a matched node, through Tees) pair up.  Where the structure
      # changed (a node added or of another class), that branch's nodes
      # start fresh, and the swap keeps its short crossfade; with every
      # stateful node matched it is a cut, so the new graph continues the
      # old one's samples.
      #
      # What carries: Tones, Envelopes and note envelopes (their stage and
      # level), filters (SVF/biquad, four-pole, diode), resonators, shapers,
      # companders, decimators, sample-and-holds, smoothers, Notes nodes
      # (held notes, note numbers, velocities, controllers, glides), and the
      # Synth's allocator (which lane holds which note).  What doesn't:
      # delay lines, reverbs, choruses, sampler voices, grains, and other
      # nodes without plan snapshots (their tails start fresh).  Times are
      # moved to the new graph's stream time (graphs count stream time from
      # their own start).
      module Carry
        # What .plan found: +pairs+ ([[old node, new node], ...] with state
        # to copy), +synths+ ([[old Synth, new Synth], ...]), +stateful+
        # (nodes of the new graph with state), +matched+ (of those, the
        # ones paired), +old_input+ (the replaced player's GraphNodeInput).
        # +uncarried+ counts the new graph's nodes with memory no snapshot
        # holds (delays, reverbs, sampler voices: see .uncarried?).
        Plan = Data.define(:pairs, :synths, :stateful, :matched, :uncarried, :old_input) do
          # True if every stateful node of the new graph has a partner and
          # none holds uncarried memory (the swap can cut instead of
          # crossfading).
          def full? = matched == stateful && uncarried == 0

          def to_s
            "#{matched}/#{stateful} stateful nodes, #{synths.length} synth#{'s' unless synths.length == 1}" \
              "#{", #{uncarried} with memory that starts fresh (crossfaded)" if uncarried > 0}"
          end
        end

        # Node classes whose snapshots aren't running state (values the
        # graph reads from outside: knobs, constants).
        SKIP = [GraphNode::Constant, GraphNode::Knob, GraphNode::Knob::Reader].freeze

        # Notes node instance variables kept from the new node on a carry:
        # its own stream's position and generation, frame counts, and grid
        # bookkeeping (the rest is the old node's held notes and values).
        NOTES_KEEP = %i[@generation @frames_read @tail @grid_end @grid_generation @smooth_generation].freeze

        # Where the default (stateless: nil) plan_snapshot is defined.
        STATELESS_OWNERS = [MB::Sound::Plan::Describable, (MB::Sound::Plan::Describing if defined?(MB::Sound::Plan::Describing))].compact.freeze

        module_function

        # Matches graph +new_nodes+ (the outputs of the graph about to
        # play) to +old_input+'s (see the module description).  Returns a
        # Plan.
        def plan(old_input, new_nodes)
          old_nodes = old_input.instance_variable_get(:@nodes) || []
          all = graph_nodes(new_nodes)
          old_all = nil
          pairs = []
          synths = []
          seen = {}
          taken = {}
          pair = ->(o, n) {
            seen[n.__id__] = true
            taken[o.__id__] = true
            pairs << [o, n] if stateful?(n)
          }

          # Nodes of the same class at the same place: from the outputs,
          # through the same source names
          queue = old_nodes.zip(new_nodes).reject { |o, n| o.nil? || n.nil? }
          until queue.empty?
            o, n = queue.shift
            o = GraphNode.climb_tee_tree(o)
            n = GraphNode.climb_tee_tree(n)
            next if seen[n.__id__] || taken[o.__id__] || o.equal?(n) || o.class != n.class
            pair.(o, n)
            synths << [o, n] if o.is_a?(Synth)
            next unless o.respond_to?(:sources) && n.respond_to?(:sources)
            os = o.sources
            n.sources.each do |name, src|
              next if src.is_a?(Numeric) || !(old = os[name]) || old.is_a?(Numeric)
              queue << [old, src]
            end
          end

          # Inside nodes whose #sources don't lead to their inputs (a
          # multiband compander's bands): the k-th node of a class pairs with
          # the old graph's k-th of that class when both graphs have as many
          # (Synths first, so their lanes pair by voice below)
          unless all.all? { |x| seen[x.__id__] || !(stateful?(x) || x.is_a?(Synth)) }
            old_all = graph_nodes(old_nodes)
            by_class = ->(list) { list.select { |x| stateful?(x) || x.is_a?(Synth) }.group_by(&:class) }
            olds = by_class.(old_all)
            news = by_class.(all)
            news.keys.sort_by { |k| k <= Synth ? 0 : 1 }.each do |klass|
              list = news[klass]
              old_list = olds[klass] || []
              next unless old_list.length == list.length
              list.zip(old_list).each do |x, o|
                next if seen[x.__id__] || taken[o.__id__]
                pair.(o, x)
                synths << [o, x] if o.is_a?(Synth)
              end
            end
          end

          # Notes nodes the new graph has where the old had none (a unison
          # whose detune became a knob reads note numbers of its own): each
          # takes the state of an old node of its kind in the same voice,
          # since every note node of a voice follows its notes (a
          # controller only one of the same number)
          kind = ->(x) { [x.class, x.instance_variable_get(:@node_type_name)] }
          synths.each do |o, n|
            olanes = o.instance_variable_get(:@lane_graphs) || []
            nlanes = n.instance_variable_get(:@lane_graphs) || []
            nlanes.each_with_index do |g, i|
              by_kind = (olanes[i] || []).select { |x| notes_side?(x) }.group_by(&kind)
              g.each do |x|
                next unless notes_side?(x) && !seen[x.__id__] && stateful?(x)
                partner = by_kind[kind.(x)]&.first or next
                seen[x.__id__] = true
                pairs << [partner, x]
              end
            end
          end

          stateful = all.select { |x| stateful?(x) }
          in_all = stateful.to_h { |x| [x.__id__, true] }
          Plan.new(pairs: pairs.freeze, synths: synths.freeze, stateful: stateful.length, matched: pairs.count { |_, x| in_all[x.__id__] },
                   uncarried: all.count { |x| uncarried?(x) }, old_input: old_input)
        end

        # Every node of graph +roots+, once.
        def graph_nodes(roots)
          roots.flat_map { |r| [r, *(r.respond_to?(:graph) ? r.graph : [])] }.uniq(&:__id__)
        end

        # Node classes with no running state of their own (wiring,
        # arithmetic, mixing, values from outside, note plumbing whose state
        # is its Notes nodes'), by name so the list loads before them.
        STATELESS = %w[
          MB::Sound::GraphNode::Tee MB::Sound::GraphNode::Tee::Branch MB::Sound::GraphNode::NodeOutput
          MB::Sound::GraphNode::Mixer MB::Sound::GraphNode::Multiplier MB::Sound::GraphNode::ProcNode
          MB::Sound::GraphNode::BinaryOperation MB::Sound::GraphNode::NoteFrequency MB::Sound::GraphNode::QualityResonance
          MB::Sound::GraphNode::Constant MB::Sound::GraphNode::Knob MB::Sound::GraphNode::Knob::Reader
          MB::Sound::GraphNode::ChannelMixer MB::Sound::GraphNode::ChannelMixer::Output MB::Sound::GraphNode::Ports::Port
          MB::Sound::GraphNode::UnaryFunction MB::Sound::GraphNode::MathFunction MB::Sound::GraphNode::ComplexNode
          MB::Sound::GraphNode::BusTap MB::Sound::GraphNode::Channels MB::Sound::GraphNode::ZoneValue
          MB::Sound::Synth MB::Sound::Synth::Output MB::Sound::Sequence::TempoNode MB::Sound::MIDI::ClipSource
          MB::Sound::Notes::EnvelopeInputs::Port MB::Sound::Notes::NoteEnvelope::GmTime MB::Sound::Notes::NotePitch
          MB::Sound::Notes::Resonance MB::Sound::Notes::Aftertouch MB::Sound::SQ80::TimeScale
        ].freeze

        # True if +node+ (a graph node) has running state a carry doesn't
        # copy: no plan snapshot and not a STATELESS kind (delay lines,
        # reverbs, feedback loops, choruses, formants, crossovers, sampler
        # voices, grains, loop players, ...), filters other than SVFs,
        # cookbook biquads, and chains of them, and drum kit voices (their
        # idle sleeping; their hits' nodes carry).  Unknown kinds count:
        # the swap then crossfades rather than cut.
        def uncarried?(node)
          return false unless node.is_a?(GraphNode) || node.is_a?(Drums::Voice)
          return true if node.is_a?(Filter::SampleWrapper) && !Filter::SampleWrapper.filter_state?(node.base_filter)
          return true if node.is_a?(Drums::Voice)
          return false if stateful?(node)
          node.class.ancestors.none? { |c| STATELESS.include?(c.name) }
        end

        # True for a voice's note-following nodes (Notes nodes, note
        # envelopes, note frequencies).
        def notes_side?(node)
          node.class.name.to_s.start_with?('MB::Sound::Notes::')
        end

        # True if +node+ keeps running state that carries (see SKIP).
        def stateful?(node)
          node.respond_to?(:plan_snapshot) && node.respond_to?(:plan_restore) && SKIP.none? { |k| node.is_a?(k) } &&
            !STATELESS_OWNERS.include?(node.method(:plan_snapshot).owner)
        end

        # Copies the state of +plan+'s old nodes into the new ones (see the
        # module description), on the swap frame: the old graph has played
        # up to it and the new one hasn't played.  Returns the number of
        # nodes whose state was copied.
        def apply(plan)
          shifts = {}
          plan.synths.each do |o, n|
            shift = carry_synth(o, n)
            shifts[n.__id__] = shift if shift
          end
          count = 0
          plan.pairs.each do |o, n|
            snap = o.plan_snapshot or next
            if n.is_a?(Notes::NoteEnvelope)
              # (its stage and level; its stream time is the new graph's)
              n.instance_variable_get(:@state)[0..] = snap.data[:@state]
            elsif n.is_a?(Notes::Node)
              reader = n.plan_reader
              cursor = reader.cursor
              keep = NOTES_KEEP.to_h { |iv| [iv, n.instance_variable_get(iv)] }
              n.plan_restore(snap)
              keep.each { |iv, v| n.instance_variable_set(iv, v) }
              reader.cursor = cursor
              # (no chase of the new stream's notes in progress: the node
              # holds the old one's notes already)
              n.instance_variable_set(:@pending_chase, nil)
              n.skip_start_chase!
            else
              n.plan_restore(snap)
            end
            count += 1
          end
          count
        end

        # Carries Synth +o+'s voice allocation into Synth +n+ (the lanes
        # holding notes, the held keys, the mono note stack), with times
        # moved to +n+'s stream time.  Returns the shift (old time - new
        # time), or nil if the synths' lanes don't match.
        def carry_synth(o, n)
          a = o.instance_variable_get(:@allocator)
          b = n.instance_variable_get(:@allocator)
          return nil unless a && b && a.lanes.length == b.lanes.length && a.mono? == b.mono?
          shift = a.read_to - b.read_to
          time = ->(t) { t.nil? ? nil : t - shift }
          old_states = a.instance_variable_get(:@voice_states)
          new_states = b.instance_variable_get(:@voice_states)
          old_states.each_with_index do |s, i|
            t = new_states[i]
            t.state = s.state
            t.channel = s.channel
            t.note = s.note
            t.velocity = s.velocity
            t.on_seq = s.on_seq
            t.off_seq = s.off_seq
            t.free_seq = s.free_seq
            t.choke_end = time.(s.choke_end)
            t.last_time = time.(s.last_time)
          end
          slots = {}.compare_by_identity
          remap = ->(slot) { slots[slot] ||= MIDI::Allocator::Slot.new(slot.voice && new_states[slot.voice.index]) }
          new_states.each_with_index { |t, i| t.slots = old_states[i].slots.map(&remap) }
          b.instance_variable_set(:@held, a.instance_variable_get(:@held).transform_values { |list| list.map(&remap) })
          # (mono: the note stack's events, and the playing one by identity)
          stack = a.instance_variable_get(:@stack)
          playing = a.instance_variable_get(:@playing)
          b.instance_variable_set(:@stack, stack.dup)
          b.instance_variable_set(:@playing, playing)
          b.instance_variable_set(:@seq, a.instance_variable_get(:@seq))

          # The carried notes' note-offs: the new graph's source never
          # started them, so the old source's (read ahead from the swap)
          # go into the new allocator at the same moments
          b.inject(note_offs_ahead(a).map { |e| e.with(time: e.time - shift) })

          # The lanes' idle bookkeeping (asleep lanes stay asleep, on the
          # same grid of the synth's own time)
          SYNTH_STATE.each do |iv|
            v = o.instance_variable_get(iv)
            n.instance_variable_set(iv, v.is_a?(Array) ? Marshal.load(Marshal.dump(v)) : v)
          end
          shift
        end

        # A Synth's idle-skipping and lane measuring state, carried as it
        # is (frame counts of the synth's own time and per-lane flags).
        SYNTH_STATE = %i[
          @skipping @skip_generation @cell_loud @skip_position @grid_offset @grid_started @quiet @quiet_pos @peaks
          @cell_lo @cell_hi @cell_fresh @done @last_loud
        ].freeze

        # Seconds of the old source read ahead for the held notes'
        # note-offs, at most, in steps.
        LOOKAHEAD = 32
        LOOKAHEAD_STEP = 1

        # The note-offs (Events at +a+'s stream time) that end the notes
        # allocator +a+ holds, read ahead from its input (none for real-time
        # input, whose note-offs arrive live in the new graph's stream).
        def note_offs_ahead(a)
          return [] if a.stream.realtime_input?
          held = a.instance_variable_get(:@held)
          want = held.transform_values { |list| list.count(&:voice) }.select { |_, c| c > 0 }
          if a.mono?
            stack = a.instance_variable_get(:@stack)
            stack.each { |e| want[[e.channel, e.note]] = (want[[e.channel, e.note]] || 0) + 1 }
          end
          return [] if want.empty?
          # (a reader of its own: the old graph may play on through a
          # crossfade, reading its input from where it is)
          input = a.stream.reader(at: a.read_to)
          from = a.read_to
          out = []
          begin
            (LOOKAHEAD / LOOKAHEAD_STEP).times do
              to = from + LOOKAHEAD_STEP
              input.events(from, to).each do |e|
                next unless e.type == :note_off && (c = want[k = [e.channel, e.note]]) && c > 0
                out << e
                want[k] = c - 1
              end
              from = to
              break if want.values.all?(&:zero?) || input.ended?
            end
          ensure
            input.close
          end
          out
        end
      end
    end
  end
end
