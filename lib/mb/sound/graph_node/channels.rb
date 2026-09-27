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

        # Returns a stereo bundle: this bundle if it has two channels, or its
        # single channel on both sides.
        def stereo
          case channel_count
          when 2 then self
          when 1 then Channels.new([@outputs[0], @outputs[0]])
          else raise ArgumentError, "Can't make #{channel_count} channels stereo automatically; pick channels (e.g. channels(b[0], b[1])) or mix down with .mono"
          end
        end

        # Mixes the channels into one node, averaging them so levels stay the
        # same for correlated channels.  Also available as #mixdown.
        def mono
          return @outputs[0] if channel_count == 1
          @outputs.reduce(:+) * (1.0 / channel_count)
        end
        alias mixdown mono

        # The first (left) channel.
        def left
          @outputs[0]
        end

        # The second (right) channel.
        def right
          raise ArgumentError, "A #{channel_count}-channel bundle has no right channel" if channel_count < 2
          @outputs[1]
        end

        # Returns a stereo bundle with the left and right channels swapped.
        def swap
          require_stereo('swap')
          Channels.new([right, left])
        end

        # Converts left/right stereo to mid/side: mid is (L + R) / 2 and side
        # is (L - R) / 2.  See #from_mid_side.
        def mid_side
          require_stereo('mid_side')
          Channels.new([(left + right) * 0.5, (left - right) * 0.5])
        end

        # Converts mid/side back to left/right stereo: left is M + S and
        # right is M - S.  See #mid_side.
        def from_mid_side
          require_stereo('from_mid_side')
          Channels.new([left + right, left - right])
        end

        # Changes the stereo width by scaling the side (L - R) signal: 0 is
        # mono, 1 is unchanged, and larger values are wider.  +amount+ may be
        # a graph node.
        #
        # Example (bin/sound.rb):
        #     bg stereo(220.hz.ramp.at(0.2), 221.hz.ramp.at(0.2)).forever.width(1.5)
        def width(amount)
          mid, side = mid_side
          Channels.new([mid, side * amount]).from_mid_side
        end

        # Panning a bundle (balance) will come with more pan laws.
        def pan(*)
          raise NotImplementedError, 'Panning a multichannel bundle (balance) is not supported yet; pan single-channel nodes (e.g. node.pan(-0.5)) or use .width'
        end

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

        private

        def require_stereo(method)
          raise ArgumentError, "#{method} needs a stereo bundle (got #{channel_count} channels)" unless channel_count == 2
        end
      end
    end
  end
end
