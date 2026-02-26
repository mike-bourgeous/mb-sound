module MB
  module Sound
    module GraphNode
      # Mixin/interface for pseudo-nodes with multiple output nodes, like Tee,
      # InputChannelSplit, etc.
      module MultiOutput
        # When implemented, returns an Array of NodeOutput nodes that may be
        # sampled to retrieve the node's individual output values.
        def outputs
          raise NotImplementedError, 'Multi-output graph nodes must implement #outputs to return NodeOutputs'
        end

        # Notifies spies on the core node when the first output is sampled.
        #
        # TODO: give more useful data than just the first output, e.g. sum,
        # multiple channels, etc.
        def spy(handle: nil, interval: false, phase: :post)
          if outputs[0].equal?(self)
            super
          else
            outputs[0].spy(handle: handle, interval: interval, phase: phase) do |v|
              yield v
            end
          end
        end
      end
    end
  end
end
