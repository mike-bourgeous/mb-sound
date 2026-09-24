module MB
  module Sound
    module GraphNode
      # Methods for controlling how long tones in a graph will play.  Included
      # in GraphNode.
      module DurationMethods
        # Sets all Tones in the graph to continue playing for +duration+.
        def for(duration, recursive: true)
          if recursive
            graph.each do |n|
              next if n == self
              n.for(duration, recursive: false) if n.respond_to?(:for)
            end
          end

          self
        end

        # Sets all Tones in the graph to play for +duration+ by default unless
        # the tone was specifically given a duration.
        def or_for(duration, recursive: true)
          if recursive
            graph.each do |n|
              next if n == self
              n.or_for(duration, recursive: false) if n.respond_to?(:or_for)
            end
          end

          self
        end

        # Sets all Tones in the graph (or anything else with a #forever method
        # that takes a :recursive parameter) to continue playing forever.
        def forever(recursive: true)
          if recursive
            graph.each do |n|
              n.forever(recursive: false) if n.respond_to?(:forever)
            end
          end

          self
        end
      end
    end
  end
end
