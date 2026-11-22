require_relative 'inspect'
require_relative '../node_traits'

module MB
  module Sound
    module GraphNode
      # Mixin/interface for pseudo-nodes with multiple output nodes, like Tee,
      # InputChannelSplit, etc.
      module MultiOutput
        include Inspect # one-line #inspect (ux-fix-1)

        # Set lazily by recording: the recorded bundle whose outputs this
        # node owns (GraphNode::Recipe.bundle_of; multi-output nodes aren't
        # GraphNodes, so they declare it themselves, see IvarPreset).
        IvarPreset.attach(self)
        IvarPreset.declare(self, :@graph_bundle)

        # When implemented, returns an Array of NodeOutput nodes that may be
        # sampled to retrieve the node's individual output values.
        def outputs
          raise NotImplementedError, 'Multi-output graph nodes must implement #outputs to return NodeOutputs'
        end

        # The number of output channels (see #outputs).
        def channel_count
          outputs.length
        end

        # Notifies spies on the core node when the first output is sampled.
        #
        # TODO: give more useful data than just the first output, e.g. sum,
        # multiple channels, etc.
        def spy(handle: nil, interval: false, phase: :post, snapshot: false)
          if outputs[0].equal?(self)
            super
          else
            outputs[0].spy(handle: handle, interval: interval, phase: phase, snapshot: snapshot) do |v|
              yield v
            end
          end
        end
      end
    end
  end
end

MB::Sound::NodeTraits.attach(MB::Sound::GraphNode::MultiOutput)
