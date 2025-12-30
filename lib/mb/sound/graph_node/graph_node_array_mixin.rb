module MB
  module Sound
    module GraphNode
      module GraphNodeArrayMixin
        # Converts an Array of GraphNodes to an Input with a #read method.
        #
        # +num_channels+ - Minimum number of channels to return.
        # +:buffer_size+ - Buffer size to report to consumers of the Input
        #                  (defaults to graph's upstream buffer size).
        #
        # Example:
        #     [99.hz, 101.hz].as_input
        #
        # See MB::Sound::GraphNodeInput#initialize.
        def as_input(num_channels = 1, buffer_size: nil)
          # TODO: support NArrays for creating an ArrayInput
          unless self.length >= 1 && self.all?(MB::Sound::GraphNode)
            raise 'All Array elements must be GraphNodes to turn them into an input'
          end

          MB::Sound::GraphNodeInput.new(self, channels: num_channels, buffer_size: buffer_size)
        end
      end

      Array.include(GraphNodeArrayMixin)
    end
  end
end
