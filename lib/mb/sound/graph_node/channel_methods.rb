module MB
  module Sound
    module GraphNode
      # Methods for converting between channel counts, included in GraphNode
      # (for single-channel nodes).  Channel bundles have their own versions
      # (see Channels).
      module ChannelMethods
        # Pan laws accepted by #pan.  More (e.g. -4.5 dB center, balance)
        # may come later.
        PAN_LAWS = [:equal_power].freeze

        # Returns a stereo bundle with this node on both channels.
        #
        # Example (bin/sound.rb):
        #     bg 220.hz.ramp.at(0.3).forever.stereo
        def stereo
          Channels.new([self, self])
        end

        # Pans this single-channel node into a stereo bundle.  +position+
        # goes from -1 (left) through 0 (center) to 1 (right), and may be a
        # graph node (e.g. an LFO) for moving pans.  The default equal-power
        # law puts the center at -3 dB on each side, so loudness stays even
        # as the signal moves.
        #
        # Examples (bin/sound.rb):
        #     bg 330.hz.triangle.at(0.3).forever.pan(-0.5)
        #     bg 330.hz.triangle.at(0.3).forever.pan(4.bars.lfo)
        def pan(position = 0, law: :equal_power)
          raise ArgumentError, "Unknown pan law #{law.inspect} (supported: #{PAN_LAWS.map(&:inspect).join(', ')})" unless PAN_LAWS.include?(law)

          if position.is_a?(Numeric)
            raise ArgumentError, "Pan position must be from -1 to 1 (got #{position})" unless position.between?(-1, 1)
            angle = (position + 1) * Math::PI / 4
            Channels.new([self * Math.cos(angle), self * Math.sin(angle)])
          else
            pos = position.get_sampler
            left = pos.proc(type_name: 'pan left') { |d| Numo::NMath.cos((d.clip(-1, 1) + 1) * (Math::PI / 4)) }
            right = pos.proc(type_name: 'pan right') { |d| Numo::NMath.sin((d.clip(-1, 1) + 1) * (Math::PI / 4)) }
            Channels.new([self * left, self * right])
          end
        end

        # Returns this node, which already has a single channel (see
        # Channels#mono).
        def mono
          self
        end
        alias mixdown mono
      end
    end
  end
end
