module MB
  module Sound
    module GraphNode
      # Extends any audio I/O object with a #read method with a #sample method
      # for compatibility with the arithmetic DSL.
      #
      # You'll generally also want to include GraphNode in any class that
      # includes this module.
      module IOSampleMixin
        include MultiOutput

        # Returns an Array of graph source nodes for each of the channels (up
        # to +:max_channels+) on this input.  If the channel count would be 1,
        # then the input itself is returned.  Similar to GraphNode#tee.
        #
        # Returns the same objects each time, so use GraphNode#get_sampler if
        # they need to be branched (most nodes already use get_sampler
        # internally).
        def split(max_channels: nil)
          ch = self.channels
          ch = MB::M.min(ch, max_channels) if max_channels
          return [self] if ch == 1

          @split ||= InputChannelSplit.new(self, max_channels: max_channels)
          @split.outputs
        end

        # Returns a GraphNode output for each input channel by wrapping #split.
        # For MultiOutput compatibility.
        def outputs
          split
        end

        # Reads +count+ frames (which should match the preferred buffer size of
        # the input object), returning only the first channel from the input.
        # This is for interoperability with the arithmetic DSL in MB::Sound that
        # allows combining Tones, Mixers, Multipliers, and inputs.
        def sample(count)
          raise 'Input has been split; cannot sample directly' if @split

          data = read(count)
          return nil if data.nil? || data.empty? || data[0].empty?

          # TODO: should this sum channels?
          data[0]
        end

        # Overrides the default GraphNode#graph_node_name reader to try to
        # get a sensible name for the input, whether that's a filename, ALSA
        # device, JACK connection list, or whatever.
        def graph_node_name
          # FIXME: Allow renaming nodes (check @graph_node_name or @named first)
          if self.respond_to?(:filename)
            name = self.filename
          elsif self.respond_to?(:device)
            name = self.device
          elsif self.respond_to?(:connections)
            name = self.connections.join(', ')
          elsif self.respond_to?(:name)
            name = self.name
          else
            @graph_node_name ||= __id__.to_s
            name = @graph_node_name
          end

          "#{self.class.name}: #{name}"
        end
      end
    end
  end
end
