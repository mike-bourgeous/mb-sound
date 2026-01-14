module MB
  module Sound
    # An input object that reads from a node graph.
    class GraphNodeInput
      attr_reader :channels, :sample_rate, :buffer_size

      # Creates a graph node input that returns the nodes' output across at
      # least +:channels+ channels.  If +:channels+ is greater than the number
      # of nodes, then nodes will be repeated to fill the requested number of
      # channels.  If +:buffer_size+ is not specified, then the graph will be
      # searched for any inputs that specify a buffer size, and if none are
      # found, will default to 800.
      def initialize(*nodes, channels: 1, buffer_size: nil)
        nodes = nodes[0] if nodes.length == 1 && nodes[0].is_a?(Array)
        raise 'All sources must be GraphNodes' unless nodes.length >= 1 && nodes.all?(MB::Sound::GraphNode)

        nodes = nodes.flat_map { |n|
          n.is_a?(MB::Sound::GraphNode::MultiOutput) ? n.outputs.map(&:get_sampler) : n.get_sampler
        }

        @sample_rate = nodes.map(&:sample_rate).max
        nodes.each do |n|
          n.sample_rate = @sample_rate unless n.sample_rate == @sample_rate
        end

        @buffer_size = buffer_size || nodes[0].graph_buffer_size || 800

        @channels = MB::M.max(nodes.length, channels)

        @nodes = nodes.map { |n| n.get_sampler }.freeze

        @output = Array.new(@channels)

        @handled_spies = {}
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
      def spy(handle: nil, interval: false, &block)
        @handled_spies[handle] ||= []
        @handled_spies[handle] << [block, interval, Time.now - (interval || 1)]

        self
      end

      # Used by #spy.
      # TODO: combine with GraphNode#call_spies somehow
      private def call_spies(data)
        now = Time.now

        @handled_spies.each do |origin, spies|
          info = origin ? " from #{origin}" : ''

          spies.each_with_index do |spy_info, idx|
            s, interval, last_time = spy_info

            begin
              if !interval || (now - last_time) >= interval
                s.call(*data)
                spy_info[-1] = now
              end
            rescue => e
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
        min_length = count
        max_length = count
        data = @nodes.map { |n|
          n.sample(count).tap { |d|
            if d
              len = d.length
              min_length = len if len < min_length
              max_length = len if len > max_length
            end
          }
        }

        return nil if data.all? { |d| d.nil? || d.empty? }

        if min_length != max_length || data.any?(NilClass)
          data = data.map { |d|
            d ? MB::M.zpad(d, max_length) : Numo::SFloat.zeros(max_length)
          }
        end

        for idx in 0...@channels
          @output[idx] = data[idx % data.length]
        end

        call_spies(@output)

        @output
      end
    end
  end
end
