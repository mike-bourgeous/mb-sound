module MB
  module Sound
    module GraphNode
      # Methods for converting between channel counts, included in GraphNode.
      # Nodes with several outputs (e.g. stereo file inputs or multi-output
      # reverbs) act like a Channels bundle of their outputs.  Each mixing
      # method is one ChannelMixer node (see ChannelMixer and its subclasses).
      module ChannelMethods
        # Pan laws accepted by #pan (see ChannelMixer::PanLaws).
        PAN_LAWS = [:equal_power, :minus_4_5db, :linear].freeze

        # Returns a stereo bundle with this node on both channels (see
        # Channels#stereo for multichannel nodes).
        #
        # Example (bin/sound.rb):
        #     bg 220.hz.ramp.at(0.3).stereo
        def stereo
          return channels_bundle.stereo if channel_count > 1
          Channels.new([self, self])
        end

        # Pans this single-channel node into a stereo bundle (a
        # ChannelMixer::Pan).  +position+ goes from -1 (left) through 0
        # (center) to 1 (right), and may be a graph node (e.g. an LFO) for
        # moving pans.  The default equal-power +law+ puts the center at
        # -3 dB on each side, so loudness stays even as the signal moves;
        # :minus_4_5db and :linear (-6 dB) are the alternatives.  On a stereo
        # node, balances instead (see Channels#balance), like most DAWs'
        # stereo pan controls.
        #
        # Examples (bin/sound.rb):
        #     bg 330.hz.triangle.at(0.3).pan(-0.5)
        #     bg 330.hz.triangle.at(0.3).pan(4.bars.lfo)
        #     bg 330.hz.triangle.at(0.3).pan(0.5, law: :linear)
        def pan(position = 0, law: :equal_power)
          return channels_bundle.pan(position, law: law) if channel_count > 1
          ChannelMixer::Pan.new(self, position: position, law: law).then { |m| Channels.new(m.outputs) }
        end

        # Mixes any number of channels into new channels with +matrix+ (a
        # ChannelMixer::Matrix): one row per output and one column per
        # channel.  Entries are numbers, complex numbers (phase shifts: real
        # inputs become analytic signals), or graph nodes.  Returns a bundle,
        # or one node for a one-row matrix.
        #
        # Examples (bin/sound.rb):
        #     bg stereo(a, b).matrix([[1, 0.3], [0.3, 1]])   # crossfeed
        #     bg a.matrix([[1], [0.5i]])                     # mono to stereo, 90 degrees apart
        def matrix(matrix, complex: false)
          mixer = ChannelMixer::Matrix.new(outputs, matrix: matrix, complex: complex)
          mixer.outputs.length == 1 ? mixer.outputs[0] : Channels.new(mixer.outputs)
        end

        # Places this single-channel node in a two-channel phase-amplitude
        # field, as matrix surround encoders do (a ChannelMixer::Position):
        # +x+ from -1 (left) to 1 (right) sets the levels, and +y+ from 1
        # (front) to -1 (rear) the phase difference (in phase at the front,
        # opposite at the rear).  Both may be graph nodes.  Real inputs come
        # out as real Lt/Rt channels; complex inputs stay complex.  Also
        # available as #position.
        #
        # Examples (bin/sound.rb):
        #     bg 220.hz.ramp.at(0.3).place(x: -1, y: -1)               # rear left
        #     bg 220.hz.ramp.at(0.3).place(x: 2.hz.lfo, y: 0.3.hz.lfo)  # circling
        def place(x: 0, y: 1, law: :equal_power)
          raise ArgumentError, "place needs a single-channel node (this one has #{channel_count} channels)" if channel_count > 1
          ChannelMixer::Position.new(self, x: x, y: y, law: law).then { |m| Channels.new(m.outputs) }
        end
        alias position place

        # Returns this node if it has a single channel, or its channels mixed
        # down (see Channels#mono).  Also available as #mixdown.
        def mono
          channel_count > 1 ? channels_bundle.mono : self
        end
        alias mixdown mono

        # Stereo conversions for nodes with several outputs (see Channels).
        [:left, :right, :swap, :mid_side, :from_mid_side, :width, :balance].each do |name|
          define_method(name) do |*args|
            raise ArgumentError, "#{name} needs a multichannel node (this one has 1 channel)" if channel_count == 1
            channels_bundle.public_send(name, *args)
          end
        end

        private

        # This node's outputs as a Channels bundle.
        def channels_bundle
          Channels.new(outputs)
        end
      end
    end
  end
end
