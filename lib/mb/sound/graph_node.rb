require 'shellwords'

# First, so every class that includes GraphNode gets its instance variable
# layout (see IvarPreset).
require_relative 'graph_node/ivar_preset'
MB::Sound::GraphNode::IvarPreset.attach(MB::Sound::GraphNode)

require_relative 'graph_node/nameable'
require_relative 'graph_node/traversable'
require_relative 'graph_node/node_output'
require_relative 'graph_node/multi_output'
require_relative 'graph_node/ports'
require_relative 'graph_node/routing_methods'
require_relative 'graph_node/arithmetic_methods'
require_relative 'graph_node/synthesis_methods'
require_relative 'graph_node/resample_methods'
require_relative 'graph_node/filter_methods'
require_relative 'graph_node/delay_methods'
require_relative 'graph_node/feedback_methods'
require_relative 'graph_node/distortion_methods'
require_relative 'graph_node/debug_methods'
require_relative 'graph_node/channel_methods'
require_relative 'graph_node/chorus'
require_relative 'graph_node/stereo_delay_methods'
require_relative 'graph_node/dynamics_methods'
require_relative 'graph_node/sampling_methods'
require_relative 'graph_node/blend_methods'
require_relative 'graph_node/mastering_methods'

module MB
  module Sound
    # Adds methods to any class that implements a :sample method to build
    # signal generation and processing graphs.  In combination with Tone, Note,
    # and the helper methods in MB::Sound, this creates a DSL that can quickly
    # generate complex sounds.
    #
    # Examples (run in the bin/sound.rb environment):
    #     # FM organ bass
    #     mod = F2.at(300) * adsr(0, 0.1, 0.0, 0.5, hold: false)
    #     play F1.at(-6.db).fm(mod) * adsr(0, 0, 1, 0, hold: 0.25)
    #
    #     # FM classic synth bass
    #     cenv = adsr(0, 0.005, 0.5, 2.5, curve: 30)
    #     cenv2 = adsr(0, 0.01, 0.5, 2.5, curve: 60)
    #     c = cenv * C3.at(1).fm(cenv2 * C3.at(1)); nil
    #     denv = adsr(0, 0.005, 0, 2, curve: 50)
    #     d = denv * Tone.new(frequency: C3.frequency.constant * 0.9996 - 0.22).at(1); nil
    #     eenv = adsr(0, 3, 0.0, 2, curve: 80)
    #     e = eenv * C2.at(1).fm(c * 4810 + d * 500); nil
    #     fenv = adsr(0, 2, 0, 2, curve: 80)
    #     f = C2.at(-10.db).fm(e * 250) * fenv; nil
    #     play f
    #
    # There are more examples in the bin/ directory, such as bin/flanger.rb
    #
    # The DSL methods are grouped into modules that GraphNode includes:
    # RoutingMethods, ArithmeticMethods, SynthesisMethods, ResampleMethods,
    # FilterMethods, DelayMethods, DistortionMethods, and DebugMethods (in
    # lib/mb/sound/graph_node/*_methods.rb).  Add new DSL
    # methods to the matching module, or create a new module and include it
    # here after Nameable and Traversable.
    #
    # TODO: Standardize a way to modify an existing graph, e.g. to inject a
    # tee, filter, or tap.
    #
    # Controls and their types: see Traversable#port_info and #param_info
    # (racks R1); meters: DebugMethods#loudness_meter.
    #
    # TODO: Document methods that nodes must implement or override
    module GraphNode
      include Nameable
      include Traversable
      include RoutingMethods
      include ArithmeticMethods
      include SynthesisMethods
      include ResampleMethods
      include FilterMethods
      include DelayMethods
      include FeedbackMethods
      include DistortionMethods
      include DebugMethods
      include ChannelMethods
      include ChorusMethods
      include StereoDelayMethods
      include DynamicsMethods
      include SamplingMethods
      include BlendMethods
      include MasteringMethods

      # The per-channel DSL call that made this node, if any (see
      # ChannelDispatch and ChannelGroup).  Used by #graphviz.
      attr_accessor :channel_group

      # Set lazily by GraphNode's modules and the plan layer (see IvarPreset).
      IvarPreset.declare(
        self,
        :@node_type_name, :@graph_node_name, :@named, :@graph_recipe, :@graph_io_document,
        :@channel_group, :@internal_tee, :@feedback_sources, :@handled_spies,
        :@plan_bypass, :@plan_installations, :@plan_member, :@plan_region,
        :@plan_observed, :@plan_handoff, :@plan_restart, :@plan_excluded
      )

      # The nodes that carry this node's output channels.  Every node has
      # outputs: a single-channel node is its own only output, and nodes with
      # several outputs (MultiOutput, e.g. a stereo reverb or a channel
      # bundle) return one node per channel.  Consumers can use #outputs
      # without checking which kind of node they have.
      def outputs
        [self]
      end

      # The number of output channels (see #outputs).
      def channel_count
        outputs.length
      end

      # Returns the class name, or a custom name set by the subclass (e.g. '/'
      # for a division proc node).
      def node_type_name
        @node_type_name ||= self.class.name.rpartition('::').last
      end

      # Returns the class name of the node plus the node's assigned name or
      # object ID.
      def to_s
        @graph_node_name ||= nil
        "#{node_type_name}/#{@graph_node_name || "id=#{__id__}"}"
      end

      # Returns a multiline description of a node suitable for display in a
      # GraphViz visualization (see #graphviz).
      def to_s_graphviz
        to_s # populate @node_type_name

        <<~EOF
        #{@node_type_name}
        #{@graph_node_name || "id=#{__id__}"}
        #{MB::M.sigformat(sample_rate)}Hz
        EOF
      end

      # Finds the lowest numeric value greater than zero for any graph nodes
      # that have a #buffer_size method.  The idea is that sound card inputs
      # will have the smallest buffer size of any input.
      #
      # If there is no graph node with a buffer_size method, then this method
      # returns nil.
      #
      # TODO: what should this return when the graph contains a buffer adapter?
      def graph_buffer_size
        size = nil

        graph.each do |n|
          nsize = n.respond_to?(:buffer_size) ? n.buffer_size : nil
          if nsize && nsize > 0 && (size.nil? || nsize < size)
            size = nsize
          end
        end

        size
      end

      # The value of +v+ while a graph builds (sound-design-2: settings that
      # choose the graph's structure, such as Tone#sync's +enabled:+): a
      # number as it is, a Constant's value, a Knob's (or Knob::Reader's)
      # value, true/false as 1/0, nil as nil.  A knob read here can't follow
      # turns (the graph doesn't sample it), so inside a track's patch build
      # the knob is remembered as a build knob of that track: turning it
      # rebuilds the track (Arrangement#build_knob_turned).  Raises
      # ArgumentError for other nodes.
      def self.build_value(v)
        v = climb_tee_tree(v) if v.is_a?(GraphNode)
        case v
        when nil, Numeric then v
        when true then 1
        when false then 0
        when Constant then v.constant
        when Knob::Reader, Knob
          k = ValueSource.knob_of(v)
          MB::Sound::Arrangement::TrackKnobs.note_build_read(k)
          k.build_value
        else
          raise ArgumentError, "A setting read while the graph builds must be a number, a param, or a knob (got #{v.class.name.split('::').last})"
        end
      end

      # True if +v+ (see .build_value) is on (nonzero); +default+ for nil.
      def self.build_flag?(v, default: true)
        b = build_value(v)
        b.nil? ? default : b != 0
      end

      # Walk up sources until a "real" node is found, skipping over
      # housekeeping nodes like Tee::Branch.  Used by #graph.
      def self.climb_tee_tree(branch)
        branch = branch.original_source while climb_over?(branch)
        branch
      end

      # Returns true if the given branch should be skipped normally when doing
      # a non-verbose traversal of a node graph.  This e.g. skips tees,
      # branches, adapters, etc.  See .climb_tee_tree and NodeOutput.
      def self.climb_over?(branch)
        branch.is_a?(MB::Sound::GraphNode::NodeOutput)
      end

      # Create a list of upstream nodes from the given graph node.  See #graph.
      #
      # The list starts with +node+, and every node comes after all the
      # nodes in the graph that read it: nodes in order of their longest
      # path from +node+, and nodes at the same distance in order of the
      # last of those paths in a breadth-first walk (the order the original
      # path walk, now .graph_by_paths, gave; a spec compares them).  Each
      # node's #sources is read once, so this takes time linear in the
      # graph's edges.  The path walk took one step per path, which grows
      # exponentially with stacked diamonds (a node read by every lane of a
      # Synth, through every unison copy...), and after a node had been
      # reached more than 50 times plus the list's length it warned
      # "Possible infinite loop" and stopped following that node, leaving
      # it too early in the list (fixes-12, 2026-10-14: the jungle pad
      # printed 994 such warnings for one #graph).  Graphs whose #sources
      # form a loop (feedback goes through #feedback_sources instead) fall
      # back to the path walk.
      # Structural changes (Plan.changed: inputs added or removed, a Tee's
      # branches) to nodes of graphs whose node sets someone caches (see
      # .watch_structure; Session::Strip#asleep_reads): a count that only
      # grows.  Changes to other nodes, e.g. graphs being built for the
      # next scene, don't count, so those caches stay valid while the
      # scheduler thread builds (ux-fix-2).
      def self.structure_changes
        @structure_changes
      end

      # Counts structural changes to +nodes+ from now on (see
      # .structure_changes).  Held weakly.
      def self.watch_structure(nodes)
        watched = @structure_watch
        nodes.each { |n| watched[n] = true unless n.is_a?(Numeric) }
        nil
      end

      # Called by Plan.changed for a structural change to +node+.
      def self.structure_changed(node)
        @structure_changes += 1 if @structure_watch.key?(node)
        nil
      end

      @structure_changes = 0
      @structure_watch = ObjectSpace::WeakMap.new

      def self.graph(node, include_tees: true)
        root = graph_key(node, include_tees)

        # Depth-first walk for the nodes, their sources, and a topological
        # order (reverse post-order), finding loops
        sources = { root => graph_source_list(root, include_tees) }
        open = { root => true }
        post = []
        stack = [[root, 0]]
        until stack.empty?
          frame = stack.last
          n = frame[0]
          list = sources[n]
          i = frame[1]
          if i < list.length
            frame[1] = i + 1
            s = list[i]
            if sources.include?(s)
              return graph_by_paths(node, include_tees: include_tees) if open[s]
            else
              sources[s] = graph_source_list(s, include_tees)
              open[s] = true
              stack << [s, 0]
            end
          else
            open.delete(n)
            post << n
            stack.pop
          end
        end

        # Longest path from the root to each node
        depth = { root => 0 }
        post.reverse_each do |n|
          d = depth[n] + 1
          sources[n].each do |s|
            depth[s] = d if (depth[s] || -1) < d
          end
        end

        # Each level in order of the last edge into its nodes from the level
        # before (insertion-ordered Hashes; delete and store moves a key to
        # the end)
        result = []
        level = { root => true }
        d = 0
        until level.empty?
          result.concat(level.keys)
          d += 1
          following = {}
          level.each_key do |n|
            sources[n].each do |s|
              next unless depth[s] == d

              following.delete(s)
              following[s] = true
            end
          end
          level = following
        end

        result
      end

      # The key .graph uses for +s+: whole Floats as Integers, and (without
      # +include_tees+) the node a Tee branch or other NodeOutput reads.
      def self.graph_key(s, include_tees)
        s = s.round if s.is_a?(Numeric) && s.respond_to?(:round) && s.finite? && s.round == s
        s = climb_tee_tree(s) unless include_tees
        s
      end

      # The largest sum of +weight+ (a block given each node, returning a
      # number) along any path from +node+ up through its sources, edges
      # taken as .graph takes them (through Tees and from a multi-output
      # node's outputs to the node), so walks that need path sums (rack
      # latency) can't miss nodes behind a Tee (racks-r2: a walk that kept
      # only nodes answering #sample stopped at Tees).  Edges back to a
      # node on the current path (feedback) are skipped.  With +visited+
      # (a compare_by_identity Hash), records every node reached.
      def self.longest_path(node, visited: nil, &weight)
        memo = {}.compare_by_identity
        open = {}.compare_by_identity
        walk = nil
        walk = ->(n) {
          return memo[n] if memo.key?(n)
          return 0 if open[n]
          open[n] = true
          visited[n] = true if visited
          best = graph_source_list(n, true).map { |src| walk.(src) }.max || 0
          open.delete(n)
          memo[n] = weight.call(n) + best
        }
        walk.(graph_key(node, true))
      end

      # The sources of +s+ as .graph keys, one per edge.
      def self.graph_source_list(s, include_tees)
        return [] unless s.respond_to?(:sources)

        s.sources.values.map { |v| graph_key(v, include_tees) }
      end

      # The original #graph traversal, used now only for graphs whose
      # #sources form a loop (see .graph): walks every path from +node+,
      # moving a node seen again to the end of the list, until a node has
      # been seen more often than the list is long.
      def self.graph_by_paths(node, include_tees: true)
        # The list is an insertion-ordered Hash (keys only), so moving a
        # node seen again to the end is O(1) (an Array#delete scanned the
        # whole list each time: ~50 ms per traversal of a 1400-node scene
        # graph, three traversals per Session#add; scene-build, 2026-10-12).
        # TODO: weaken return ordering and memoize in each instance and call
        # graph instead of sources to get sources?
        #
        # Start self at -1 visits to preserve ordering when breaking feedback
        # loops
        source_history = { node => -1 }
        source_queue = [node]
        source_list = {}

        until source_queue.empty?
          s = source_queue.shift
          s = s.round if s.is_a?(Numeric) && s.respond_to?(:round) && s.finite? && s.round == s

          # TODO: have a separate configuration for manual tees and implied
          # branches from get_sampler, and default to ignoring get_sampler?
          # TODO: allow climbing past nodes of any type or based on any
          # condition, e.g. to skip mixers and multipliers that were created by
          # an internal arithmetic step inside or for another node.  e.g. #adsr
          # creates a multiplier to icombine the input with the envelope.
          # TODO: automatically differentiate between nodes created directly by
          # the user and nodes created implicitly by other nodes?  e.g. could
          # wrap internal node creation within a block that marks those nodes
          # as invisible by default?
          unless include_tees
            s = climb_tee_tree(s)
          end

          # If we encounter a source again, move it to the end of the source
          # list and look at its sources again.
          if source_history.include?(s)
            # TODO: only look at a source if all paths from it have been traveled
            # TODO: this would all be easier if source/dest links were bidirectional
            # TODO: is this a reasonable number?
            if source_history[s] > 50 + source_list.length
              warn "Possible infinite loop on #{s} (started from #{node}; seen #{source_history[s]} times of #{source_list.length})"
              next
            end

            source_list.delete(s)
          else
            source_history[s] = 0
          end

          source_history[s] += 1
          source_list[s] = true

          source_queue.concat(s.sources.values) if s.respond_to?(:sources)
        end

        source_list.keys
      end

      # Create a rank list for the given graph node (or similar object that
      # responds to #graph).  See #graph_ranks.
      def self.graph_ranks(node, include_tees: true)
        rank_map = { node => 0 }

        (node.graph(include_tees: include_tees) | [node]).each do |dest|
          next if dest.is_a?(Numeric)

          rank_map[dest] ||= 0
          next_rank = rank_map[dest] + 1

          dest.sources.each do |_name, src|
            next if src.is_a?(Numeric)

            src = climb_tee_tree(src) unless include_tees

            rank_map[src] ||= next_rank
            rank_map[src] = MB::M.max(rank_map[src], next_rank)
          end
        end

        ranks = []
        rank_map.each do |n, rank|
          ranks[rank] ||= []
          ranks[rank] << n
        end

        ranks.compact.reverse
      end

      private

      # Instance-method alias for the class method of the same name.
      def climb_tee_tree(branch)
        MB::Sound::GraphNode.climb_tee_tree(branch)
      end

      # Turns a node source, whether Numeric or another node, into a reasonable
      # String representation, skipping Tee branches.
      #
      # The +:separator+ is used for joining terms in arithmetic nodes.
      def make_source_name(numeric_or_node, separator: ' ')
        s = climb_tee_tree(numeric_or_node)
        case
        when s.respond_to?(:graph_node_name) && s.named?
          s.graph_node_name

        when s.respond_to?(:arithmetic_string)
          parenthesize(s.arithmetic_string(separator))

        when s.respond_to?(:display_label) && s.display_label
          s.display_label

        when s.respond_to?(:name_or_id)
          s.name_or_id

        when s.is_a?(Complex)
          s.to_s

        when s.is_a?(Numeric)
          s.to_nice_s(4)

        else
          s.to_s
        end
      end

      # Adds parentheses around a mathematical statement if it contains any
      # operators or spaces.
      def parenthesize(str)
        if str.match?(/[[:space:][:punct:]]/)
          # TODO: maybe count parenthetical nestings to see if there's already
          # a global parenthesis
          "(#{str})"
        else
          str
        end
      end
    end

    # GN is a shorthand alias for GraphNode
    GN = GraphNode
  end
end

require_relative 'graph_node/arithmetic_node_helper'
require_relative 'graph_node/frozen_copy'
require_relative 'graph_node/frozen_view'
require_relative 'graph_node/sample_rate_helper'
require_relative 'graph_node/graph_node_array_mixin'

require_relative 'graph_node/constant'
require_relative 'graph_node/knob'
require_relative 'graph_node/knob_value_at'
require_relative 'graph_node/silence'
require_relative 'graph_node/time_limit'
require_relative 'graph_node/input_channel_split'
require_relative 'graph_node/mix_source'
require_relative 'graph_node/bus_tap'
require_relative 'graph_node/channels'
require_relative 'graph_node/loudness_meter'
require_relative 'graph_node/rider'
require_relative 'graph_node/io_sample_mixin'
require_relative 'graph_node/mixer'
require_relative 'graph_node/multiplier'
require_relative 'graph_node/node_sequence'
require_relative 'graph_node/ringdown'
require_relative 'graph_node/sounding'
require_relative 'graph_node/chorus_nodes'
require_relative 'graph_node/proc_node'
require_relative 'graph_node/tee'
require_relative 'graph_node/branch_watch'
require_relative 'graph_node/multitap_delay'
require_relative 'graph_node/delay_network'
require_relative 'graph_node/feedback_loop'
require_relative 'graph_node/unary_function'
require_relative 'graph_node/complex_node'
require_relative 'graph_node/math_function'
require_relative 'graph_node/note_frequency'
require_relative 'graph_node/quality_resonance'
require_relative 'graph_node/binary_operation'
require_relative 'graph_node/buffer_adapter'
require_relative 'graph_node/resample'
require_relative 'graph_node/quantize'
require_relative 'graph_node/sample_hold'
require_relative 'graph_node/decimator'
require_relative 'graph_node/sampler_voice'
require_relative 'graph_node/zone_value'
require_relative 'graph_node/sub_lane'
require_relative 'graph_node/loop_player'
require_relative 'graph_node/shaper'
require_relative 'graph_node/curve_shaper'
require_relative 'graph_node/four_pole'
require_relative 'graph_node/formant'
require_relative 'graph_node/data_shuffler'
require_relative 'graph_node/wavetable'
require_relative 'graph_node/harmonic_table'
require_relative 'graph_node/channel_mixer'
require_relative 'graph_node/channel_mixer/matrix'
require_relative 'graph_node/channel_mixer/pan_laws'
require_relative 'graph_node/channel_mixer/stereo'
require_relative 'graph_node/channel_mixer/position'
require_relative 'graph_node/channel_mixer/unison'
require_relative 'graph_node/reverb'
require_relative 'graph_node/semitone_shift'
require_relative 'graph_node/resonator'
require_relative 'graph_node/modal_resonator'
require_relative 'graph_node/dust'
require_relative 'graph_node/drift'
require_relative 'graph_node/dynamics'

# Generates per-channel DSL methods, so it must load after every *Methods module
require_relative 'graph_node/channel_dispatch'
require_relative 'graph_node/ring_hint'
