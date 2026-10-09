require_relative 'fast_plan'

module MB
  module Sound
    # The plan layer: fused execution of graph regions (optimizer stage 4,
    # phase 1).  A region is a connected part of a GraphNode graph whose
    # nodes can describe their per-sample work as ops (Multipliers, Mixers,
    # Constants, ComplexNode parts, GraphNode / and **, and Tones on the
    # naive and band-limited kernels, with frequency and phase modulation,
    # width, gain, and reset inputs).  Instead of one Ruby #sample call per
    # node and per Tee branch, a region runs as one op list in C
    # (MB::Sound::FastPlan), reading its boundary inputs (envelopes, MIDI
    # nodes, filters, anything without ops) through the handles its nodes
    # already hold.
    #
    # It is an as-if transformation: the same samples (every op is
    # bit-exact with its node; see Op), the user's graph untouched (plans
    # reference nodes and never rewire them; names, graphviz, #sources, and
    # find_by_name see the original graph), and node state in the nodes
    # (Tone::State's Arrays are the registers' state), so a plan can be
    # dropped at any block boundary and the graph continues unfused.
    #
    # == Automatic plans
    #
    # Session#add and Synth (each lane) install plans on what they play
    # (Plan.install); nothing else changes.  Plans compile when their region
    # first plays, and rebuild after a structural change to a node they
    # cover (Plan.changed: Multiplier#add, Mixer#[]=, a new Tee branch, a
    # spy, ...).  Graph introspection disables fusion for what it inspects:
    # a spied node (GraphNode#spy) or one marked with Plan.observe (e.g. a
    # per-node visualizer or profiler) becomes a region boundary, computed
    # by its own #sample.
    #
    # Settings (environment variables, read at load; also writable):
    # - MB_SOUND_PLAN=0 turns plans off (Plan.enabled = false); =ruby runs
    #   them with the Ruby mirror (Plan.engine = :ruby) for debugging.
    # - MB_SOUND_PLAN_CHECK=1 (or raise / warn) runs every planned block
    #   both ways, planned and unfused (Plan.check = :raise or :warn), and
    #   compares samples and oscillator states: :raise in scripts and specs,
    #   :warn (and the region stops planning) in bin/sound.rb.
    #
    # == The node protocol
    #
    # A node takes part by including Plan::Describable and defining
    #
    # - #plan_describe(p): its per-sample work as ops, in a small DSL (see
    #   Builder): p[input] gives an input's Value (described in the same
    #   plan if the region owns that node, else a boundary input), and
    #   Values combine with Ruby operators:
    #
    #       # Multiplier: the constant times each input, in order
    #       def plan_describe(p)
    #         @multiplicands.keys.reduce(p.const(@constant, complex: plan_complex?)) { |product, m| product * p[m] }
    #       end
    #
    #       # Tone: one oscillator op on the Tone's own state
    #       p.tone(self, frequency: p[@frequency], phase_mod: p[@phase_mod || 0], reset: p.boundary(@reset, optional: true), ...)
    #
    # - #plan_inputs: the handles #plan_describe reads (for the region
    #   finder), and #plan_unsupported_reason: nil if the node's current
    #   settings can be described, else why not (listed by Plan.explain).
    # - #plan_snapshot / #plan_restore for state the check mode compares
    #   (Tone: its State; Constant: its change queue).
    #
    # Specs (spec/lib/mb/sound/plan/) run each node's ops in C and with the
    # Ruby mirror against the node's own #sample, sample for sample, over
    # block sizes from 1 to 800, parameter changes, and resets.
    #
    # == Feedback loops (later)
    #
    # The executor runs ops a block at a time.  Feedback regions (the
    # loop-region API sketched in proposals/feedback_loops.md:
    # `sig.delay(t, feedback: g) { |fb| ... }`, `sig.feedback { |fb, input| ... }`)
    # will add a per-sample mode: a Program flagged as a loop, whose ops
    # run in one per-sample loop (each op as a scalar step), with state
    # slots for one-sample histories (Value of the previous sample, a
    # delay line's ring) and a latency per op (Op#latency, 0 for every P1
    # op; a softclip's half sample, a delay's length) summed around the
    # loop.  The pieces are in place: ops are Ruby objects with explicit
    # operands, the C executor dispatches on opcodes over a register file,
    # and node state is already explicit (Tone::State).  See the design
    # note in CLAUDE.md's Plan layer section.
    module Plan
      # Raised by #plan_describe (or ops) for settings a plan can't run;
      # the region finder treats the node as a boundary.
      class Unsupported < StandardError
        attr_reader :node

        def initialize(node, why)
          @node = node
          super("#{Plan.node_label(node)}: #{why}")
        end
      end

      # Raised in check mode (Plan.check = :raise) when a planned block
      # differs from the unfused graph.
      class CheckFailed < RuntimeError; end

      class << self
        # Whether Plan.install builds plans (MB_SOUND_PLAN=0 turns it off).
        attr_accessor :enabled

        # :c (the default) or :ruby (MB_SOUND_PLAN=ruby): which executor
        # runs plans.
        attr_accessor :engine

        # nil, :raise, or :warn: whether to check every planned block
        # against the unfused graph (see the module description).
        attr_accessor :check

        # :fast (the default) or :exact (MB_SOUND_PLAN_PRECISION=exact):
        # with :fast, naive real sine tones use a vectorized float
        # polynomial (mb_vec_sine.h, Ruby mirror Plan::VecSine; within 1e-6
        # of the Tone's samples, about -120 dB, at about a sixth of libm's
        # cost; user decision 2026-10-09); with :exact every op is
        # bit-exact with its node.  Read when a region compiles.
        attr_accessor :precision

        # The fewest graph nodes a region must cover to be planned
        # (single-node regions gain nothing).
        attr_accessor :min_nodes

        # Whether folding 0 * x to 0 (Plan::Fold) warns, once per kind of
        # node (default true; MB_SOUND_PLAN_FOLD_WARN=0 turns it off).
        attr_accessor :fold_warnings

        # Labels a node for listings and messages: its name or class and id.
        def node_label(node)
          return node.to_s if node.is_a?(Numeric)
          return node.graph_node_name if node.respond_to?(:named?) && node.named?

          "#{class_label(node)}/#{node.__id__}"
        end

        # A node's class name without MB::Sound:: (or its superclass's for
        # anonymous classes).
        def class_label(node)
          cls = node.class
          cls = cls.superclass while cls.name.nil? && cls.superclass
          cls.name.to_s.sub('MB::Sound::', '')
        end

        # Installs plans on the graphs feeding +outputs+ (GraphNodes,
        # bundles, or Arrays of them): finds the regions, hooks their root
        # nodes, and returns the Installation (nil when plans are off or
        # nothing could be planned).
        def install(*outputs, engine: self.engine, check: self.check)
          return nil unless enabled

          inst = Installation.new(outputs.flatten.flat_map { |o| o.respond_to?(:outputs) ? o.outputs.to_a : [o] }, engine: engine, check: check)
          inst.build
          inst.precompile
          inst.regions.empty? ? (inst.uninstall; nil) : inst
        end

        # Called by nodes (and Tees) after a change: a structural change
        # (inputs added or removed, spies, configuration) makes the
        # installations covering +node+ rebuild their plans before their
        # next block; a settings change (+structure: false+: a sample rate,
        # a Multiplier's constant, a Mixer gain) only recompiles the region
        # computing +node+.
        def changed(node, structure: true)
          list = watch[node]
          return nil unless list

          list.keys.each { |inst| structure ? inst.stale! : inst.settings_changed(node) }
          nil
        end

        # Marks +node+ as observed (true) or not (false): an observed node
        # is never fused into a region, so its #sample runs and anything
        # that wraps or spies on it sees every buffer (per-node plots,
        # visualizers, profilers).
        def observe(node, observed = true)
          node.instance_variable_set(:@plan_observed, observed)
          changed(node)
          node
        end

        # True if +node+ is observed (Plan.observe or a spy).
        def observed?(node)
          return true if node.instance_variable_get(:@plan_observed)

          spies = node.instance_variable_get(:@handled_spies)
          !!spies && !spies.empty?
        end

        # For internal use: Installations covering each node, as a weak
        # set (an ObjectSpace::WeakMap of Installation => true) per node
        # (weak keys).  Both sides are weak: an Installation references
        # its graph, so a strong value would keep every node (and with
        # them every Synth, Notes, and buffer) alive forever (2026-10-09:
        # the plan specs grew by ~80 MB per synth).  Installations are kept
        # alive by their regions' hooks on the nodes and by their roots
        # (Installation#watch).
        def watch
          @watch ||= ObjectSpace::WeakKeyMap.new
        end

        # A listing of how +outputs+ would be planned (regions, ops, and
        # why each other node isn't fused), without installing anything.
        def explain(*outputs)
          inst = Installation.new(outputs.flatten.flat_map { |o| o.respond_to?(:outputs) ? o.outputs.to_a : [o] }, engine: :ruby, check: nil, dry_run: true)
          inst.build
          inst.explain
        end
      end

      self.enabled = ENV['MB_SOUND_PLAN'] != '0'
      self.engine = ENV['MB_SOUND_PLAN'] == 'ruby' ? :ruby : :c
      self.check = case ENV['MB_SOUND_PLAN_CHECK']
                   when nil, '', '0' then nil
                   when 'warn' then :warn
                   else :raise
                   end
      self.min_nodes = 2
      self.fold_warnings = ENV['MB_SOUND_PLAN_FOLD_WARN'] != '0'
      self.precision = ENV['MB_SOUND_PLAN_PRECISION'] == 'exact' ? :exact : :fast
    end
  end
end

require_relative 'plan/value'
require_relative 'plan/vec_sine'
require_relative 'plan/vec_exp2'
require_relative 'plan/ops'
require_relative 'plan/tone_op'
require_relative 'plan/events'
require_relative 'plan/envelope_op'
require_relative 'plan/snapshot'
require_relative 'plan/builder'
require_relative 'plan/fold'
require_relative 'plan/program'
require_relative 'plan/describable'
require_relative 'plan/region'
require_relative 'plan/installation'
require_relative 'plan/shared_inputs'
require_relative 'plan/loop'
require_relative 'plan/loop_pitch'
