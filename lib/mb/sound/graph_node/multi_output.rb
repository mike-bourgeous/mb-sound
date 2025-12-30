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
      end
    end
  end
end
