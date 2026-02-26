module MB
  module Sound
    module GraphNode
      # Methods related to building and traversing node graphs.  Classes should
      # include this if they want to have #sources, #graph, #graph_edges, and
      # similar methods.
      module Traversable
        # Overridden by users of this mixin to return the inputs to the current
        # object.  For example, a Mixer will return a list of objects that are
        # added together by that mixer, as well as any constant DC offset
        # applied.
        #
        # See #graph for a method that returns every source feeding into this
        # node.
        def sources
          {}
        end

        # Returns a Hash with backward-pointing sources.  Keys are source names,
        # values are source nodes.  These sources are not used when building or
        # ordering the node #graph or #graph_ranks.
        #
        # TODO: this is progress, but we still need a better way of representing
        # feedback in a node graph.
        def feedback_sources
          @feedback_sources ||= {}.freeze
        end

        # Merges the Hash of +sources+ to the feedback source list, replacing any
        # sources of the same name.  Keys are source names, values are source
        # nodes.
        def with_feedback(sources)
          @feedback_sources ||= {}
          @feedback_sources = @feedback_sources.merge(sources).freeze
          self
        end

        # Returns a list of all nodes feeding into this node, either directly or
        # indirectly, plus this node itself, without duplication.  Also may
        # include numeric values used as parameters to some of the nodes.
        #
        # Entries in the returned list should be in order of increasing distance
        # from this node, but if there are loops in the graph this is not
        # guaranteed.
        def graph(include_tees: true)
          MB::Sound::GraphNode.graph(self, include_tees: include_tees)
        end

        # Returns a Hash from source node to a Set of destination node/port name
        # tuples describing all connections upstream of this graph node.
        #
        # If +:feedback+ is true, then only backward-pointing feedback edges are
        # returned.  If false, then only normal edges are returned.
        #
        # Example output shape:
        #     {
        #       Constant => Set.new([[Tone, :frequency]])
        #       Tone => Set.new([[Filter, :cutoff], [Filter, :quality]])
        #     }
        def graph_edges(include_tees: true, feedback: false)
          edges = {}

          graph(include_tees: include_tees).each do |dest|
            if feedback
              next unless dest.respond_to?(:feedback_sources)
            else
              next unless dest.respond_to?(:sources)
            end

            list = feedback ? dest.feedback_sources : dest.sources

            list.each do |name, s|
              s = s.round if s.is_a?(Numeric) && s.respond_to?(:round) && s.round == s

              unless include_tees
                s = climb_tee_tree(s)
              end

              edges[s] ||= Set.new
              edges[s] << [dest, name]
            end
          end

          edges
        end

        # Separates the graph into ranks (in GraphViz terms) based on distance
        # from this node.  Ignores Numeric sources in the graph.  Returns an
        # Array of Arrays of nodes.
        def graph_ranks(include_tees: true)
          MB::Sound::GraphNode.graph_ranks(self, include_tees: include_tees)
        end

        # Looks for the first source node within the graph feeding into this node
        # with the given name.
        def find_by_name(name)
          graph.find { |s| s.respond_to?(:graph_node_name) && s.graph_node_name == name }
        end

        # Returns all nodes within this nodes input graph matching the given
        # name.
        def find_all_by_name(name)
          graph.select { |s| s.respond_to?(:graph_node_name) && s.graph_node_name == name }
        end

        # Returns a String containing a GraphViz representation of the signal
        # graph.
        def graphviz(include_tees: false)
          source_history = Set.new
          source_queue = [self]

          digraph = "digraph {\n"

          digraph << "  graph [ bgcolor=\"#000000e0\" rankdir=\"LR\" pad=\"0.25\" ];\n"
          digraph << "  node [ style=\"filled\" fontcolor=\"#ffffff\" color=\"#2266ee\" shape=\"Mrecord\" ];\n"
          digraph << "  edge [ fontcolor=\"#ffffff\" color=\"#ffffff\" headport=\"w\" tailport=\"e\" ];\n"

          # Add nodes
          graph(include_tees: include_tees).each do |node|
            next if node.is_a?(Numeric)
            desc = node.respond_to?(:to_s_graphviz) ? node.to_s_graphviz : node.to_s
            digraph << "  #{node.__id__.to_s.inspect} [label=#{desc.inspect}]"
          end

          # Add forward edges
          graph_edges(include_tees: include_tees).each do |src, edges|
            edges.each do |dest, name|
              # TODO: add ports to nodes instead of labeling edges
              if src.is_a?(Numeric)
                # Include a separate numeric source node for each destination
                srcname = "#{src.inspect} to #{dest.__id__}/#{name}"
                digraph << "  #{srcname.inspect} [label=#{src.to_s.inspect}];\n"
                digraph << "  #{srcname.inspect} -> #{dest.__id__.to_s.inspect} [label=#{name.to_s.inspect}];\n"
              else
                digraph << "  #{src.__id__.to_s.inspect} -> #{dest.__id__.to_s.inspect} [label=#{name.to_s.inspect}];\n"
              end
            end
          end

          # Add feedback edges
          graph_edges(include_tees: include_tees, feedback: true).each do |src, edges|
            edges.each do |dest, name|
              digraph << "  #{src.__id__.to_s.inspect} -> #{dest.__id__.to_s.inspect} [label=#{name.to_s.inspect}, color=red, constraint=false];\n"
            end
          end

          digraph << "}\n"

          digraph
        end

        # Saves a GraphViz representation of the graph to a temporary file,
        # generates a PNG using dot, and opens the PNG using open.  The PNG file
        # is left behind after the program exits for inspection.
        def open_graphviz(include_tees: false)
          dot = Tempfile.create([self.to_s, '.dot'])

          png = "#{dot.path}.png"
          File.write(dot, self.graphviz(include_tees: include_tees))
          system("dot -Tpng:cairo #{dot.path.shellescape} -o #{png.shellescape}")
          system("open #{png.shellescape}")

          png
        end
      end
    end
  end
end
