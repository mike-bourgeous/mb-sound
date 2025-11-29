module MB
  module Sound
    # An input object that reads from a node graph.
    class GraphNodeInput
      attr_reader :channels, :sample_rate, :buffer_size

      # Creates a graph node input that replicates the node's output across
      # +:channels+ channels.  If +:buffer_size+ is not specified, then the
      # graph will be searched for any inputs that specify a buffer size, and
      # if none are found, will default to 800.
      def initialize(node, channels: 1, buffer_size: nil)
        @sample_rate = node.sample_rate
        @buffer_size = buffer_size || node.graph_buffer_size || 800
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
