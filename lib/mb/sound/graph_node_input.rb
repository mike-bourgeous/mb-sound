module MB
  module Sound
    # An input object that reads from a node graph.
    class GraphNodeInput
      attr_reader :channels, :sample_rate, :buffer_size

      # The graph nodes (one per channel) this input reads from.
      attr_reader :nodes

      # Creates a graph node input that returns the nodes' output across at
      # least +:channels+ channels.  If +:channels+ is greater than the number
      # of nodes, then nodes will be repeated to fill the requested number of
      # channels.  If +:buffer_size+ is not specified, then the graph will be
      # searched for any inputs that specify a buffer size, and if none are
      # found, will default to 800.
      def initialize(*nodes, channels: 1, buffer_size: nil)
        nodes = nodes[0] if nodes.length == 1 && nodes[0].is_a?(Array)
        unless nodes.length >= 1 && nodes.all? { |n| n.is_a?(MB::Sound::GraphNode) || n.is_a?(MB::Sound::GraphNode::MultiOutput) }
          raise 'All sources must be GraphNodes'
        end

        nodes = nodes.flat_map { |n| n.outputs.map(&:get_sampler) }

        @sample_rate = nodes.map(&:sample_rate).max
        nodes.each do |n|
          n.sample_rate = @sample_rate unless n.sample_rate == @sample_rate
        end

        @buffer_size = buffer_size || nodes[0].graph_buffer_size || 800

        @channels = MB::M.max(nodes.length, channels)

        @nodes = nodes.freeze

        @output = Array.new(@channels)
        @data = Array.new(@nodes.length) # (reused by #read)

        @handled_spies = {}
        @synths = nil
        @node_set = nil
      end

      # Lists the graph's nodes (with Tees) for Session::Strip#graph_node_set
      # on the thread that builds the graph (Session#add), so the render
      # thread doesn't walk a new scene's graphs while they wait to land
      # (alloc-2).  Kept as [structure, [nodes, ids]] for the
      # GraphNode.structure_changes count it was listed at.
      def prime_node_set
        structure = GraphNode.structure_changes
        nodes = graph(include_tees: true)
        GraphNode.watch_structure(nodes)
        ids = {}
        nodes.each { |n| ids[n.__id__] = true }
        @node_set = [structure, [nodes, ids]].freeze
        nil
      end

      # Lets nodes that set up on their first buffer (#prime_render, e.g.
      # Drums::Voice's skipping) do it now, on the thread that builds the
      # graph (Session#add, before the graph can start; alloc-2).
      def prime_nodes
        graph(include_tees: true).each { |n| n.prime_render if !n.equal?(self) && n.respond_to?(:prime_render) }
        nil
      end

      # The [nodes, ids] #prime_node_set listed, if listed at +structure+.
      def primed_node_set(structure)
        s = @node_set
        s && s[0] == structure ? s[1] : nil
      end

      # The Synths anywhere in the graph (for Session#align_grids, which
      # needs them on a player's first buffer; Session#add lists them
      # first, on the building thread, so the render thread doesn't walk
      # the graph where the player starts; alloc-2).
      def synths
        @synths ||= @nodes.flat_map { |n| n.respond_to?(:graph) ? [n, *n.graph] : [n] }.uniq.grep(MB::Sound::Synth).freeze
      end

      # Just describes the number of channels.
      def to_s
        "#{@nodes.length} Channel#{@nodes.length != 1 ? 's' : ''}"
      end

      # Returns the list of nodes that directly feed this input.
      def sources
        @nodes.map.with_index { |n, idx|
          [:"channel_#{idx + 1}", n]
        }.to_h
      end

      # Returns the full list of nodes in the entire graph upstream of this
      # input across all branches.
      #
      # See GraphNode#graph.
      def graph(include_tees: true)
        MB::Sound::GraphNode.graph(self, include_tees: include_tees)
      end

      # Merges the rank-grouped graph of each source node into a single list.
      # Ranks will be right-aligned so that all sources to this input end up in
      # the same column.
      #
      # See GraphNode#graph_ranks.
      def graph_ranks(include_tees: true)
        MB::Sound::GraphNode.graph_ranks(self, include_tees: include_tees)
      end

      # Returns all of the upstream edges leading into this input.
      #
      # See GraphNode#graph_edges.
      def graph_edges(include_tees: true, feedback: false)
        edges = {}

        @nodes.each_with_index do |n, idx|
          n = n.climb_tee_tree(n) unless include_tees

          # TODO: use named channels?  allow passing a hash to the constructor to name the channels?
          edges[n] ||= Set.new
          edges[n] << [self, :"channel_#{idx + 1}"] unless feedback

          n.graph_edges(include_tees: include_tees, feedback: feedback).each do |src, edge_set|
            edges[src] ||= Set.new
            edges[src].merge(edge_set)
          end
        end

        edges
      end

      # Adds the given block as a callback to receive the return value from
      # #read as splatted arguments.
      #
      # TODO: combine with GraphNode#spy somehow
      def spy(handle: nil, interval: false, phase: :post, &block)
        @handled_spies[handle] ||= []
        @handled_spies[handle] << [block, interval, phase, MB::U.clock_now - (interval || 1)]

        self
      end

      # Used by #spy.
      # TODO: combine with GraphNode#call_spies somehow
      private def call_spies(data, phase)
        return if @handled_spies.empty?

        now = MB::U.clock_now # (a Float: no Time per read)

        @handled_spies.each do |origin, spies|
          spies.each_with_index do |spy_info, idx|
            s, interval, spy_phase, last_time = spy_info
            next unless spy_phase == phase

            begin
              if !interval || (now - last_time) >= interval
                s.call(*data)
                spy_info[-1] = now
              end
            rescue => e
              info = origin ? " from #{origin}" : ''
              warn "GraphNodeInput spy #{idx}/#{s}#{info} raised #{MB::U.highlight(e)}"
            end
          end
        end
      end

      # Clears any spies attached to this graph node (see #spy), or just spies
      # associated with the given +:handle+.
      # TODO: combine with GraphNode#clear_spies somehow
      def clear_spies(handle: nil)
        @handled_spies ||= nil

        if handle
          if @handled_spies && @handled_spies.include?(handle)
            @handled_spies[handle].clear
            @handled_spies.delete(handle)
          end
        else
          @handled_spies&.clear
        end

        self
      end

      # Returns the nodes' outputs duplicated as needed to fill all channels.
      def read(count)
        call_spies(count, :pre)

        min_length = count
        max_length = count
        data = @data
        i = 0
        while i < @nodes.length
          d = @nodes[i].sample(count)
          if d
            len = d.length
            min_length = len if len < min_length
            max_length = len if len > max_length
          end
          data[i] = d
          i += 1
        end

        return nil if data.all? { |d| d.nil? || d.empty? }

        if min_length != max_length || data.any?(NilClass)
          data = data.map { |d|
            d ? MB::M.zpad(d, max_length) : Numo::SFloat.zeros(max_length)
          }
        end

        idx = 0
        while idx < @channels
          @output[idx] = data[idx % data.length]
          idx += 1
        end

        call_spies(@output, :post)

        @output
      end
    end
  end
end
