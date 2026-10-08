require 'shellwords'

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
require_relative 'graph_node/distortion_methods'
require_relative 'graph_node/debug_methods'
require_relative 'graph_node/channel_methods'
require_relative 'graph_node/chorus'

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
    # TODO: Standardize a way to detect controls on a node and their data types
    # and ranges.  E.g. maybe a #controls method that returns a map from method
    # name to an array of ranges (or, lol, a ClassyHash array schema)
    #
    # TODO: In-line method to create a meter?
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
      include DistortionMethods
      include DebugMethods
      include ChannelMethods
      include ChorusMethods

      # The per-channel DSL call that made this node, if any (see
      # ChannelDispatch and ChannelGroup).  Used by #graphviz.
      attr_accessor :channel_group

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
      def self.graph(node, include_tees: true)
        # TODO: use a linked list for deletion and reinsertion if this method
        # becomes too slow, or weaken return ordering and memoize in each
        # instance and call graph instead of sources to get sources?
        #
        # Start self at -1 visits to preserve ordering when breaking feedback
        # loops
        source_history = { node => -1 }
        source_queue = [node]
        source_list = []

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
              # FIXME: node graph iteration is reporting possible infinite loops on code which shouldn't have any loops
              # FIXME: only re-traverse a node if doing so would change its
              # depth; I suspect we're doing an exponential traversal of all
              # possible edge combinations in complex graphs.
              warn "Possible infinite loop on #{s} (started from #{self}; seen #{source_history[s]} times of #{source_list.length})"
              next
            end

            source_list.delete(s)
          else
            source_history[s] = 0
          end

          source_history[s] += 1
          source_list << s

          source_queue.concat(s.sources.values) if s.respond_to?(:sources)
        end

        source_list
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
require_relative 'graph_node/sample_rate_helper'
require_relative 'graph_node/graph_node_array_mixin'

require_relative 'graph_node/constant'
require_relative 'graph_node/silence'
require_relative 'graph_node/time_limit'
require_relative 'graph_node/input_channel_split'
require_relative 'graph_node/mix_source'
require_relative 'graph_node/channels'
require_relative 'graph_node/loudness_meter'
require_relative 'graph_node/io_sample_mixin'
require_relative 'graph_node/mixer'
require_relative 'graph_node/multiplier'
require_relative 'graph_node/node_sequence'
require_relative 'graph_node/ringdown'
require_relative 'graph_node/chorus_nodes'
require_relative 'graph_node/proc_node'
require_relative 'graph_node/tee'
require_relative 'graph_node/multitap_delay'
require_relative 'graph_node/complex_node'
require_relative 'graph_node/buffer_adapter'
require_relative 'graph_node/resample'
require_relative 'graph_node/quantize'
require_relative 'graph_node/sample_hold'
require_relative 'graph_node/shaper'
require_relative 'graph_node/curve_shaper'
require_relative 'graph_node/four_pole'
require_relative 'graph_node/data_shuffler'
require_relative 'graph_node/wavetable'
require_relative 'graph_node/harmonic_table'
require_relative 'graph_node/channel_mixer'
require_relative 'graph_node/channel_mixer/matrix'
require_relative 'graph_node/channel_mixer/pan_laws'
require_relative 'graph_node/channel_mixer/stereo'
require_relative 'graph_node/channel_mixer/position'
require_relative 'graph_node/channel_mixer/unison'
require_relative 'graph_node/fdn_reverb'
require_relative 'graph_node/reverb'
require_relative 'graph_node/semitone_shift'

# Generates per-channel DSL methods, so it must load after every *Methods module
require_relative 'graph_node/channel_dispatch'
