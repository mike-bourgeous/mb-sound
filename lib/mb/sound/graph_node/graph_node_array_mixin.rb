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

        # Returns a bundle with the GraphNodes in this Array as separate
        # channels (see GraphNode::Channels).
        #
        # Example:
        #     [left, right].channels.softclip
        def channels
          MB::Sound::GraphNode::Channels.new(self)
        end

        # Runs the GraphNodes in this Array through one multichannel reverb
        # (see GraphNode#reverb), one reverb input per element, and returns a
        # channel bundle of the reverb's outputs: one per input unless
        # +:output_channels+ is given (a single output node for one).  Same as
        # `array.channels.reverb`; other parameters are the same as
        # GraphNode#reverb.
        #
        # Example:
        #     play [l, r].reverb(:hall)
        #     master { |l, r| [l, r].reverb(:hall).map(&:softclip) }
        def reverb(preset = nil, output_channels: length, **kwargs)
          unless self.length >= 1 && self.all?(MB::Sound::GraphNode)
            raise ArgumentError, 'All Array elements must be GraphNodes to run them through a reverb'
          end

          channels.reverb(preset, output_channels: output_channels, **kwargs)
        end
      end

      Array.include(GraphNodeArrayMixin)
    end
  end
end
