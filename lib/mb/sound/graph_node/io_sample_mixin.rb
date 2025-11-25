module MB
  module Sound
    module GraphNode
      # Extends any audio I/O object with a #read method with a #sample method
      # for compatibility with the arithmetic DSL.
      #
      # You'll generally also want to include GraphNode in any class that
      # includes this module.
      module IOSampleMixin
        # Returns an Array of graph source nodes for each of the channels (up to
        # +:max_channels+) on this input.  Similar to GraphNode#tee.
        def split(max_channels: nil)
          InputChannelSplit.new(self, max_channels: max_channels).channels
        end

        # Reads +count+ frames (which should match the preferred buffer size of
        # the input object), returning only the first channel from the input.
        # This is for interoperability with the arithmetic DSL in MB::Sound that
        # allows combining Tones, Mixers, Multipliers, and inputs.
        def sample(count)
          data = read(count)
          return nil if data.nil? || data.empty? || data[0].empty?

          # TODO: should this sum channels?
          data[0].not_inplace!
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
