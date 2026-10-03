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

        # Mixes the channels into one node (a ChannelMixer::Mono), averaging
        # them so levels stay the same for correlated channels.  Also
        # available as #mixdown.
        def mono
          return @outputs[0] if channel_count == 1
          ChannelMixer::Mono.new(@outputs).outputs[0]
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
          mixed(ChannelMixer::Swap.new(@outputs))
        end

        # Converts left/right stereo to mid/side: mid is (L + R) / 2 and side
        # is (L - R) / 2.  See #from_mid_side.
        def mid_side
          require_stereo('mid_side')
          mixed(ChannelMixer::MidSide.new(@outputs))
        end

        # Converts mid/side back to left/right stereo: left is M + S and
        # right is M - S.  See #mid_side.
        def from_mid_side
          require_stereo('from_mid_side')
          mixed(ChannelMixer::FromMidSide.new(@outputs))
        end

        # Changes the stereo width by scaling the side (L - R) signal: 0 is
        # mono, 1 is unchanged, and larger values are wider.  +amount+ may be
        # a graph node.
        #
        # Example (bin/sound.rb):
        #     bg stereo(220.hz.ramp.at(0.2), 221.hz.ramp.at(0.2)).width(1.5)
        def width(amount)
          require_stereo('width')
          mixed(ChannelMixer::Width.new(@outputs, amount: amount))
        end

        # Runs every channel into one multichannel reverb (one reverb input
        # per channel), returning a bundle of its outputs: as many as there
        # are channels unless +:output_channels+ is given (a single output
        # node for one).  Unlike most methods, this doesn't run separately on
        # each channel: mixing the channels inside the reverb gives a more
        # spacious, decorrelated sound.  Other parameters are the same as
        # GraphNode#reverb.
        #
        # Example (bin/sound.rb):
        #     master { |mix| mix.reverb(:hall, wet: -6.db).softclip(0.6, 0.98) }
        def reverb(preset = :default, output_channels: channel_count, **kwargs)
          Reverb.reverb(preset, input: self, output_channels: output_channels, **kwargs)
        end

        # Runs every channel into one feedback delay network reverb (see
        # GraphNode#fdn_reverb, which takes the same parameters), returning a
        # multi-output reverb node with one output per channel unless
        # +:output_channels+ is given.
        def fdn_reverb(**kwargs)
          return @outputs[0].fdn_reverb(**kwargs) if channel_count == 1
          DelayMethods.instance_method(:fdn_reverb).bind_call(self, **kwargs)
        end

        # Pans a one-channel bundle like a single node (see
        # ChannelMethods#pan), or balances a stereo bundle (see #balance), as
        # most DAWs' stereo track pan controls do.  Bundles with more
        # channels raise an error.
        #
        # Example (bin/sound.rb):
        #     bg stereo(220.hz.ramp.at(0.2), 330.hz.ramp.at(0.2)).pan(2.bars.lfo)
        def pan(position = 0, law: :equal_power)
          return @outputs[0].pan(position, law: law) if channel_count == 1
          raise ArgumentError, "Can only pan bundles with 1 or 2 channels (got #{channel_count})" unless channel_count == 2
          raise ArgumentError, "Unknown pan law #{law.inspect} (supported: #{ChannelMethods::PAN_LAWS.map(&:inspect).join(', ')})" unless ChannelMethods::PAN_LAWS.include?(law)

          balance(position)
        end

        # Balances a stereo bundle (a ChannelMixer::Balance): +position+ from
        # -1 (left only) through 0 (unchanged) to 1 (right only), and may be
        # a graph node.  The side being turned down follows an equal-power
        # curve scaled to unity at the center (about -5.3 dB at +/-0.5); the
        # other side stays at full level.
        #
        # Example (bin/sound.rb):
        #     bg stereo(220.hz.ramp.at(0.2), 330.hz.ramp.at(0.2)).balance(-0.3)
        def balance(position = 0)
          require_stereo('balance')
          mixed(ChannelMixer::Balance.new(@outputs, position: position))
        end

        # Returns [left gain, right gain] for balancing a stereo signal to
        # +position+ (see ChannelMixer::PanLaws.balance).
        def self.balance_gains(position)
          ChannelMixer::PanLaws.balance(position)
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

        # A short label for graph visualizations (see Traversable#graphviz).
        def to_s_graphviz
          "#{graph_node_name || 'Channels'}\n#{channel_count} channels"
        end

        private

        # A bundle of a mixer's outputs.
        def mixed(mixer)
          Channels.new(mixer.outputs)
        end

        def require_stereo(method)
          raise ArgumentError, "#{method} needs a stereo bundle (got #{channel_count} channels)" unless channel_count == 2
        end
      end
    end
  end
end
