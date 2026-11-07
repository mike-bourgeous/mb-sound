module MB
  module Sound
    module Sequence
      # A musical length that a graph node counts in units of a Duration,
      # read on every sample: `lfo_bars.bars` (GraphNode#bars) is 1.bar
      # times a param, knob, or other node (reese-params-2, 2026-11-07; the
      # maintainer: "LFO controls are things I will want to turn").  Its
      # tempo pitch (#hz) and LFO (#lfo) follow the node while playing,
      # integrating the moving frequency with no phase jump or rebuild (see
      # TempoNode's +count+), and play exactly like the Duration while the
      # node holds still (2.0.constant.bars plays like 2.bars).  Synth voices
      # take it as a tempo LFO rate (`v.lfo(lfo_bars.bars)`, Notes#lfo).
      #
      # Graph export prints it as the call (`lfo_bars.bars`), so a graph
      # document keeps the param.  Only LFO rates and tempo pitches take it:
      # delays, clips, and other length settings want a fixed length or
      # seconds.
      class NodeDuration
        # The graph node giving the number of units.
        attr_reader :count

        # The Duration counted (1.bar for GraphNode#bars).
        attr_reader :unit

        # Where it came from for graph export: [count, method name].
        attr_reader :origin

        def initialize(count, unit, name)
          raise ArgumentError, "A counted length needs a graph node (got #{count.inspect})" unless count.respond_to?(:sample)
          raise ArgumentError, "A counted length's unit must be a Duration (got #{unit.inspect})" unless unit.is_a?(Duration)

          @count = count
          @unit = unit
          @origin = [count, name].freeze
          freeze
        end

        # A Pitch completing one cycle per this length, following the node
        # and the tempo, locked to the timeline like Duration#hz while the
        # node holds still (see TempoNode).
        def hz
          Pitch.new(TempoNode.new(@unit, mode: :hz, count: @count, origin: self))
        end

        # A tempo LFO (see #hz and Duration#lfo) whose cycle follows the
        # node.
        def lfo
          hz.lfo
        end

        def to_s
          "#{@count} #{@origin[1]}"
        end

        def inspect
          "#<NodeDuration #{self}>"
        end
      end
    end
  end
end
