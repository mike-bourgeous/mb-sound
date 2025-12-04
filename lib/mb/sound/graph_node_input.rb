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

        @sample_rate = nodes.map(&:sample_rate).max
        nodes.each do |n| n.sample_rate = @sample_rate end

        @buffer_size = buffer_size || nodes[0].graph_buffer_size || 800

        @channels = MB::M.max(nodes.length, channels)

        @nodes = nodes.map { |n| n.get_sampler }.freeze

        @output = Array.new(@channels)
      end

      # Returns the list of nodes that directly feed this input.
      def sources
        @nodes
      end

      # Returns the full list of nodes in the entire graph upstream of this
      # input across all branches.
      #
      # See GraphNode#graph.
      def graph(include_tees: true)
        @nodes.map { |n| n.graph(include_tees: include_tees) }.reduce(&:|)
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

        @output
      end
    end
  end
end
