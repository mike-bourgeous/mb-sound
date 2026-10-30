module MB
  module Sound
    # Facts about a node kind that subsystems far from the node need, declared
    # on the node's class (node-traits-1, arch-core finding 3) instead of in
    # class lists kept by each subsystem (Synth's long-memory list, Carry's
    # STATELESS list, Drums::Voice's and SubLane's idle lists), so a new node
    # class answers every question the moment it declares itself, and a guard
    # (node_traits_spec.rb) fails for any node class in lib/ that doesn't.
    #
    #     class Reverb
    #       include GraphNode
    #       node_traits memory: :long
    #     end
    #
    #     class SamplerVoice
    #       include GraphNode
    #       node_traits memory: :short, idle_check: :idle?
    #     end
    #
    # Every class that includes GraphNode, GraphNode::MultiOutput, or
    # Sequence::TimelineNode, and every Filter, gets the +node_traits+ class
    # method (see .attach).  Declarations are found through the class's
    # ancestors, key by key (the nearest declaring ancestor wins), so a
    # subclass is a kind of its parent unless it says otherwise, and a module
    # (GraphNode::NodeOutput) can declare for every class including it.
    #
    # The traits (see Traits):
    # - +memory+: what running state the node keeps.  +:none+ (wiring,
    #   arithmetic, mixing, values from outside: nothing a rebuild or a
    #   sleep could lose), +:short+ (state that follows its input and dies
    #   away with it: oscillator phases, envelopes, filters, companders),
    #   or +:long+ (state holding sound that can come back after a silent
    #   stretch: delay lines, reverbs, feedback loops, long FIR filters).
    # - +timeline+: +true+ if the node's signal follows the session
    #   timeline (tempo LFOs, time limits, tempo-following loops), so a
    #   sleeper (an idle Synth lane, a drum voice) can't pause it; +:events+
    #   if it follows the timeline but only makes MIDI events, which wake
    #   sleepers (clip sources, MIDI transforms); +false+ otherwise.
    # - +idle_check+: the name of a method answering "may I sleep now?"
    #   from the node's own state (true when nothing it holds will sound
    #   without a new input event): an envelope that finished, a sampler
    #   voice with no note, a drum repeat with nothing pending, a delay
    #   whose line holds only silence.  Sleepers ask it only at the points
    #   of their grid where they could fall asleep (Synth::SKIP_GRID), never
    #   per sample.  A +:long+ memory node without one keeps every sleeper
    #   it is in awake (.blocks_sleep?).
    # - +random+: the random numbers the node draws as it renders, so a
    #   sleeper holding it keeps them in step (delay-sleep-1: a voice that
    #   slept draws the noise it would have drawn awake).  +false+ (none,
    #   or only while it is built), +:events+ (only at input events, which
    #   wake sleepers first: a sampler's round robins, Tone#rnd resets,
    #   random sample and hold), +:blocks+ (draws a sleeper can't know
    #   without rendering: keeps every sleeper it is in awake), or the name
    #   of a method taking a frame count that moves its random streams (and
    #   whatever they drive) on by that many frames, as if it had rendered
    #   them with its inputs holding the values they last had: a sleeper
    #   calls it for the frames it slept (NodeTraits.catch_up).
    # - +wiring+: true for fan-out wiring the plan layer sees through (Tees
    #   and their branches), which Synth#lane_fusable? skips.
    # - +carry+: how Session::Carry moves the node's state into a rebuilt
    #   graph: +:none+ (nothing to move), +:snapshot+ (its Plan::Describable
    #   plan_snapshot/plan_restore), +:own+ (a dedicated path: a Synth's
    #   voice allocation, Carry.carry_synth), or +:fresh+ (state no carry
    #   copies yet: the swap crossfades).  Derived unless declared: +:none+
    #   for +memory: :none+, +:snapshot+ for a class with a plan_snapshot of
    #   its own, else +:fresh+.  (State adoption, research-snapshot-
    #   mutability, would add an +:adopt+ kind here.)
    #
    # Nodes whose answer depends on their settings (a Filter::SampleWrapper
    # answers for the filter it wraps) define an instance method
    # +node_traits+ returning a Traits; .of asks it first.
    module NodeTraits
      MEMORY = %i[none short long].freeze
      TIMELINE = [false, true, :events].freeze
      CARRY = %i[none snapshot own fresh].freeze
      KEYS = %i[memory timeline idle_check random wiring carry].freeze

      # The +random+ values that aren't catch-up method names.
      RANDOM = [false, :events, :blocks].freeze

      # The most frames one catch-up call moves on (NodeTraits.catch_up
      # splits longer stretches), so a voice waking after a long sleep
      # spreads no more than this much work over one call.
      CATCH_UP_CHUNK = 4096

      # The traits of one node kind (see NodeTraits).  +owner+ is the class
      # or module whose declaration gave +memory+ (nil for the defaults).
      Traits = Data.define(:memory, :timeline, :idle_check, :random, :wiring, :carry, :owner) do
        # True if a sleeper holding this node can never sleep: it follows the
        # timeline, remembers sound without a way to say it is idle, or
        # draws random numbers it can't catch up.
        def blocks_sleep?
          timeline == true || (memory == :long && idle_check.nil?) || random == :blocks
        end

        # The name of the method moving the node's random streams on by a
        # number of frames (see NodeTraits), or nil.
        def catch_up
          random.is_a?(Symbol) && !RANDOM.include?(random) ? random : nil
        end

        # True for running state Session::Carry can't copy (the swap
        # crossfades).
        def uncarried?
          memory != :none && carry == :fresh
        end

        # True if Session::Carry copies the node's plan snapshot.
        def snapshot?
          carry == :snapshot
        end
      end

      # Traits of objects that aren't node kinds (MIDI streams, numbers).
      NONE = Traits.new(memory: :none, timeline: false, idle_check: nil, random: false, wiring: false, carry: :none, owner: nil)

      # Where the default (stateless: nil) plan_snapshot is defined (see
      # .derived_carry); filled in by plan.rb once those modules load.
      @stateless_snapshot_owners = []
      @declared = {}.compare_by_identity
      @cache = {}.compare_by_identity
      @scratch = [nil, nil]
      @variants = {}

      class << self
        attr_reader :stateless_snapshot_owners

        # The modules (a frozen Array) whose plan_snapshot is the default
        # one, not running state (Plan::Describable, Plan::Describing).
        def stateless_snapshot_owners=(list)
          @stateless_snapshot_owners = list.compact.freeze
          @cache.clear
          @variants.clear
        end

        # Gives +base+ (GraphNode, MultiOutput, TimelineNode, Filter) and
        # every class or module including it the +node_traits+ class method.
        def attach(base)
          base.extend(DSL) unless base.singleton_class.include?(DSL)
          if !base.is_a?(Class) && !base.singleton_class.ancestors.include?(Hook)
            base.singleton_class.prepend(Hook)
          end
          base
        end

        # Records +traits+ (a Hash of KEYS) for class or module +mod+.
        def declare(mod, traits)
          unknown = traits.keys - KEYS
          raise ArgumentError, "Unknown node traits #{unknown.inspect} for #{mod} (known: #{KEYS.join(', ')})" unless unknown.empty?
          check(mod, :memory, traits, MEMORY)
          check(mod, :timeline, traits, TIMELINE)
          check(mod, :carry, traits, CARRY)
          if traits.key?(:idle_check) && !(traits[:idle_check].nil? || traits[:idle_check].is_a?(Symbol))
            raise ArgumentError, "#{mod}'s idle_check must be a method name (a Symbol), not #{traits[:idle_check].inspect}"
          end
          if traits.key?(:random) && !(RANDOM.include?(traits[:random]) || traits[:random].is_a?(Symbol))
            raise ArgumentError, "#{mod}'s random trait must be one of #{RANDOM.inspect} or a catch-up method name, not #{traits[:random].inspect}"
          end
          (@declared[mod] ||= {}).merge!(traits)
          @cache.clear
          @variants.clear
          mod
        end

        # The declaration made on +mod+ itself (a Hash), or nil.
        def declaration(mod)
          @declared[mod]
        end

        # The class or module whose declaration gives +klass+ its memory
        # trait (nil if none of its ancestors declared one).
        def declared_by(klass)
          klass.ancestors.find { |a| @declared[a]&.key?(:memory) }
        end

        # The Traits of class +klass+ (from its ancestors' declarations;
        # undeclared keys take the defaults: memory :short, timeline false,
        # no idle check, carry derived).
        def for_class(klass)
          @cache[klass] ||= begin
            found = {}
            owner = nil
            klass.ancestors.each do |a|
              d = @declared[a] or next
              d.each { |k, v| found[k] = v unless found.key?(k) }
              owner ||= a if d.key?(:memory)
            end
            memory = found.fetch(:memory, :short)
            Traits.new(
              memory: memory,
              timeline: found.fetch(:timeline, false),
              idle_check: found[:idle_check],
              random: found.fetch(:random, false),
              wiring: found.fetch(:wiring, false),
              carry: found.fetch(:carry) { derived_carry(klass, memory) },
              owner: owner
            )
          end
        end

        # The Traits of +node+ (its instance answer if it has one, else its
        # class's; NONE for objects that aren't node kinds).
        def of(node)
          return node.node_traits if node.respond_to?(:node_traits)

          k = node.class
          k.singleton_class.include?(DSL) ? for_class(k) : NONE
        end

        # True if a sleeper (an idle Synth lane, sub-lane, or drum voice)
        # holding +node+ may never sleep (see Traits#blocks_sleep?).
        def blocks_sleep?(node)
          of(node).blocks_sleep?
        end

        # Class +klass+'s Traits with +changes+ (e.g. random: :blocks), for
        # nodes whose answer depends on their settings (an instance
        # +node_traits+ method; see NodeTraits); memoized.
        def variant(klass, **changes)
          base = for_class(klass)
          (@variants[[base, changes]] ||= base.with(**changes))
        end

        # The nodes of +nodes+ with an idle check (see NodeTraits).
        def idle_checked(nodes)
          nodes.select { |n| of(n).idle_check }
        end

        # The nodes of +nodes+ that catch up their random streams, with
        # their catch-up methods: a frozen Array of [node, method name]
        # pairs for .catch_up (see NodeTraits' +random+ trait).
        def catching_up(nodes)
          nodes.filter_map { |n| (m = of(n).catch_up) && [n, m].freeze }.freeze
        end

        # Moves the random streams of the +pairs+ from .catching_up on by
        # +frames+, as if their nodes had rendered them: what a sleeper
        # calls for the frames it slept, in calls of at most
        # CATCH_UP_CHUNK frames each.
        def catch_up(pairs, frames)
          return if frames <= 0 || pairs.empty?

          while frames > 0
            n = frames > CATCH_UP_CHUNK ? CATCH_UP_CHUNK : frames
            i = 0
            while i < pairs.length
              p = pairs[i]
              p[0].public_send(p[1], n)
              i += 1
            end
            frames -= n
          end
          nil
        end

        # A scratch output buffer of +n+ samples (at most CATCH_UP_CHUNK)
        # for a catch-up that runs a node's kernel and drops what it
        # renders: +which+ 0 or 1 (two for stereo kernels).  Shared by every
        # node (the output is never read), inplace, so kernels write it
        # where it is.
        def scratch(n, which = 0)
          raise ArgumentError, "A catch-up scratch holds at most #{CATCH_UP_CHUNK} samples (asked for #{n})" if n > CATCH_UP_CHUNK

          buf = (@scratch[which] ||= Numo::SFloat.zeros(CATCH_UP_CHUNK).inplace!)
          n == CATCH_UP_CHUNK ? buf : buf[0...n].inplace!
        end

        # The value a catch-up holds input +x+ at: +x+ itself for numbers
        # (and nil), the last sample of a buffer (see NodeTraits' +random+
        # trait: inputs hold the values they last had).
        def held(x)
          x.is_a?(Numo::NArray) ? (x.empty? ? nil : x[-1]) : x
        end

        # True if every node of +nodes+ (from .idle_checked) says it may
        # sleep now.
        def all_idle?(nodes)
          i = 0
          while i < nodes.length
            n = nodes[i]
            return false unless n.public_send(of(n).idle_check)
            i += 1
          end
          true
        end

        private

        def check(mod, key, traits, allowed)
          return unless traits.key?(key)
          return if allowed.include?(traits[key])

          raise ArgumentError, "#{mod}'s #{key} trait must be one of #{allowed.inspect}, not #{traits[key].inspect}"
        end

        def derived_carry(klass, memory)
          return :none if memory == :none

          owner = klass.instance_method(:plan_snapshot).owner rescue nil
          owner.nil? || @stateless_snapshot_owners.include?(owner) ? :fresh : :snapshot
        end
      end

      # The class-level declaration (see NodeTraits).
      module DSL
        # With keywords, declares this class's (or module's) traits; without,
        # returns the class's Traits.
        def node_traits(**traits)
          return NodeTraits.for_class(self) if traits.empty?

          NodeTraits.declare(self, traits)
        end
      end

      # Prepended to the singleton class of modules NodeTraits is attached
      # to, so classes and modules including them get DSL.
      module Hook
        def included(base)
          super
          NodeTraits.attach(base)
        end
      end
    end
  end
end
