module MB
  module Sound
    # Methods for building multichannel signals, available in bin/sound.rb.
    # See GraphNode::Channels and GraphNode::ChannelDispatch.
    module MultichannelMethods
      # Given graph nodes, returns a bundle of them as separate channels.
      # Given other values (numbers, Durations, ...), returns per-channel
      # values for a DSL method, which then runs once per channel.
      #
      # Examples (bin/sound.rb):
      #     play channels(220.hz.at(0.2), 330.hz.at(0.2), 440.hz.at(0.2)).for(2)
      #     bg 220.hz.ramp.at(0.3).forever.delay(seconds: channels(0.010, 0.013))   # mono in, stereo out
      def channels(*items)
        items = items[0] if items.length == 1 && items[0].is_a?(Array)
        nodes = items.count { |i| i.is_a?(GraphNode) || i.is_a?(GraphNode::MultiOutput) }

        if nodes == items.length
          GraphNode::Channels.new(items)
        elsif nodes == 0
          GraphNode::ChannelValues.new(items)
        else
          raise ArgumentError, 'Pass either graph nodes (a channel bundle) or plain values (per-channel values), not both'
        end
      end

      # Returns a stereo bundle of +left+ and +right+.
      #
      # Example (bin/sound.rb):
      #     play stereo(220.hz.at(0.2), 221.hz.at(0.2)).for(2)
      def stereo(left, right)
        GraphNode::Channels.new([left, right])
      end

      # Returns values spread evenly across the channels of a multichannel
      # DSL call (see GraphNode::ChannelSpread).
      #
      # Example (bin/sound.rb):
      #     bg 110.hz.ramp.at(0.3).forever.stereo.filter(:lowpass, cutoff: spread(500..900))
      def spread(range)
        GraphNode::ChannelSpread.new(range)
      end
    end
  end
end
