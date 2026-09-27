require 'forwardable'

module MB
  module Sound
    module GraphNode
      # A bundle of graph nodes played as separate channels, e.g. the left
      # and right channels of a stereo signal.  Create bundles with
      # MB::Sound#channels or #stereo, Array#channels, or GraphNode#stereo;
      # multi-output nodes like stereo reverbs and split inputs are bundles
      # too (see MultiOutput).
      #
      # A bundle acts like an Array of its channels for access (#[], #each,
      # #map, #to_a, and destructuring with `l, r = bundle`), and can be
      # played, rendered, or used in a master chain like any node.
      #
      # Example (bin/sound.rb):
      #     pad = stereo(110.hz.ramp.at(0.3), 110.5.hz.ramp.at(0.3))
      #     l, r = pad
      #     bg pad
      class Channels
        extend Forwardable
        include MultiOutput
        include Traversable
        include Nameable

        # The channel nodes.
        attr_reader :outputs

        def_delegators :@outputs, :[], :each, :each_with_index, :map, :each_slice, :zip, :first, :last, :length, :size, :sum
        alias channels outputs

        # Creates a bundle of +nodes+ (GraphNodes, or multi-output nodes
        # whose outputs become channels here).
        def initialize(nodes)
          nodes = nodes.flat_map { |n|
            unless n.is_a?(GraphNode) || n.is_a?(MultiOutput)
              raise ArgumentError, "Channels must be graph nodes (got #{n.class}); use e.g. 440.hz or 1.constant for numbers"
            end
            n.outputs
          }
          raise ArgumentError, 'A channel bundle needs at least one channel' if nodes.empty?

          @outputs = nodes.freeze
        end

        # The channel nodes, as an Array.
        def to_a
          @outputs.dup
        end

        # Allows destructuring (e.g. `l, r = bundle`) and Array(bundle).
        def to_ary
          to_a
        end

        # Traversable: each channel is a source.
        def sources
          @outputs.each_with_index.map { |n, idx| [:"channel_#{idx + 1}", n] }.to_h
        end

        def sample_rate
          @outputs[0].sample_rate
        end

        # Sets the sample rate of every channel.  Returns self.
        def sample_rate=(rate)
          @outputs.each { |n| n.sample_rate = rate }
          self
        end
        alias at_rate sample_rate=

        # Allows numbers first in arithmetic with bundles (e.g. `2 * bundle`).
        def coerce(numeric)
          [numeric.constant(sample_rate: sample_rate), self]
        end

        # Channel bundles have no single output buffer; sample their channels.
        def sample(count)
          raise NotImplementedError, "A #{channel_count}-channel bundle has no single output; sample its channels (e.g. bundle[0].sample(count)) or play it"
        end

        def to_s
          "#{graph_node_name || 'Channels'}(#{channel_count}: #{@outputs.map(&:to_s).join(', ')})"
        end

        def inspect
          "#<#{self.class.name.rpartition('::').last} #{channel_count} channels>"
        end
      end
    end
  end
end
