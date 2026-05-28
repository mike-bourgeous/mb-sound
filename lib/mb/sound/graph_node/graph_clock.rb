module MB
  module Sound
    module GraphNode
      # A MIDI clock that updates with calls to GraphNode#sample.  This allows
      # syncing MIDI playback with realtime sound card output or super-realtime
      # file output.
      class GraphClock
        # Creates a graph-driven clock driven by the given node +n+, which may
        # be nil (see #node=).
        def initialize(n = nil)
          @now = 0

          self.node = n if n
        end

        # Assigns the GraphNode that will drive this clock.  This is useful for
        # graphs that won't be created until after the MIDI file in question is
        # created.
        def node=(node)
          @node = node
          @node.spy { |d|
            @now += d.length / @node.sample_rate if d
          }
        end

        # Returns the current graph time.
        def clock_now
          @now
        end
      end
    end
  end
end
