module MB
  module Sound
    module GraphNode
      # Interface for an output on a multi-output graph node.  Inheritors must
      # set @owner to the MultiOutput node that contains them.
      module NodeOutput
        # (an output; the state is its owner's)
        NodeTraits.attach(self)
        node_traits memory: :none

        # Returns the source node for this output.  Subclasses may override
        # this to bypass the containing node.  Tee::Branch does this, for
        # example.
        def original_source
          raise 'Implementations of NodeOutput must set @owner to a MultiOutput node' unless @owner.is_a?(MultiOutput)
          @owner
        end
      end
    end
  end
end
