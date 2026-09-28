module MB
  module Sound
    class Session
      # Draws the whole session as one node graph (see #graph_view).
      module GraphView
        # A box in a session graph drawing: the players' mix (with each
        # player's graph as a source named after the player) or the session
        # output (with the master chain's channels, or the mix, as sources).
        class Box
          include GraphNode::Traversable

          attr_reader :sources

          # Creates a box labeled +label+ with +sources+ ({name => node}).
          # With +mix+ (the players' mix box) and +mix_source+ (the master
          # chain's GraphNode::MixSource), #graphviz also draws the players
          # feeding the master chain, which isn't connected to them.
          def initialize(label, sources, mix: nil, mix_source: nil)
            @label = label
            @sources = sources
            @mix = mix
            @mix_source = mix_source
          end

          def to_s
            @label
          end

          # Returns the GraphViz drawing, with the players' graphs and their
          # mix feeding the master chain when there is one.
          def graphviz(**kwargs)
            dot = super
            return dot if @mix.nil?

            # Everything between the header lines and the closing brace
            players = @mix.graphviz(**kwargs).lines[4...-1].join
            id = @mix_source.__id__.to_s.inspect
            extra = "#{players}  #{id} [label=\"master input\"];\n  #{@mix.__id__.to_s.inspect} -> #{id} [label=\"mix\"];\n"
            dot.sub(/\}\n\z/) { extra + "}\n" }
          end
        end

        # Returns a Traversable node for drawing the session with
        # #open_graphviz or #graphviz: every player's graph (current players
        # only, so players started later by #at_bar or #every are missing)
        # mixed together, through the latest master effects chain.
        def graph_view
          players = @mutex.synchronize { @players.values.select(&:current?) }
          chain = @mutex.synchronize { @master_chains&.last }

          sources = players.flat_map { |p|
            nodes = p.input.nodes
            nodes.map.with_index { |n, idx| [nodes.length == 1 ? p.name.to_s : "#{p.name}[#{idx}]", n] }
          }.to_h
          mix = Box.new('players', sources)

          if chain && !chain.bypass?
            outputs = chain.nodes.map.with_index { |n, idx| ["master[#{idx}]", n] }.to_h
            Box.new('session output', outputs, mix: mix, mix_source: chain.source)
          else
            Box.new('session output', { 'mix' => mix })
          end
        end
      end
    end
  end
end
