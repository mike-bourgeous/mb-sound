module MB
  module Sound
    # Methods for building multichannel signals, available in bin/sound.rb.
    # See GraphNode::Channels.
    module MultichannelMethods
      # Returns a bundle of the given nodes as separate channels.
      #
      # Example (bin/sound.rb):
      #     play channels(220.hz.at(0.2), 330.hz.at(0.2), 440.hz.at(0.2)).for(2)
      def channels(*nodes)
        nodes = nodes[0] if nodes.length == 1 && nodes[0].is_a?(Array)
        GraphNode::Channels.new(nodes)
      end

      # Returns a stereo bundle of +left+ and +right+.
      #
      # Example (bin/sound.rb):
      #     play stereo(220.hz.at(0.2), 221.hz.at(0.2)).for(2)
      def stereo(left, right)
        GraphNode::Channels.new([left, right])
      end
    end
  end
end
