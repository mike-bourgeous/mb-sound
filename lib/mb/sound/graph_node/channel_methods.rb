module MB
  module Sound
    module GraphNode
      # Methods for converting between channel counts, included in GraphNode
      # (for single-channel nodes).  Channel bundles have their own versions
      # (see Channels).
      module ChannelMethods
        # Returns a stereo bundle with this node on both channels.
        #
        # Example (bin/sound.rb):
        #     bg 220.hz.ramp.at(0.3).forever.stereo
        def stereo
          Channels.new([self, self])
        end
      end
    end
  end
end
