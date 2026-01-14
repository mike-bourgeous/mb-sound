module MB
  module Sound
    module GraphNode
      # Methods that allow a GraphNode or other objects to have and report an
      # object name.
      module Nameable
        # The name assigned to this object with #named.
        attr_reader :graph_node_name

        # Gives a name to this graph node to make it easier to retrieve later and
        # identify it in visualizations of the node graph (see #graphviz).
        def named(n)
          @graph_node_name = n&.to_s
          @named = !!@graph_node_name
          self
        end

        # Returns true if the graph node has been given a custom name.
        def named?
          @named ||= false
        end

        # Returns the assigned node name if present, or the object ID if not.
        def name_or_id
          @graph_node_name || "id=#{__id__}"
        end
      end
    end
  end
end
