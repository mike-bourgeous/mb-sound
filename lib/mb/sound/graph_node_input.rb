module MB
  module Sound
    # An input object that reads from a node graph.
    class GraphNodeInput
      attr_reader :channels, :sample_rate, :buffer_size

      # Creates a graph node input that replicates the node's output across
      # +:channels+ channels.
      def initialize(node, channels: 1)
        @sample_rate = node.sample_rate
        @buffer_size = node.graph_buffer_size
        @channels = channels
        @node = node
      end

      # Returns the node's output duplicated for each channel.
      def read(count)
        [@node.sample(count)] * @channels
      end
    end
  end
end
