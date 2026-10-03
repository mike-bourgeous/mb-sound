module MB
  module Sound
    module GraphNode
      class ChannelMixer
        # Gain curves for panning and balance.  Every function takes a
        # position from -1 (left) through 0 (center) to 1 (right) as a number
        # or an NArray (one position per sample), clamps it to -1..1, and
        # returns [left gain, right gain] of the same kind.
        module PanLaws
          # Laws for mono panning (#gains), by center level:
          # - :equal_power: -3 dB at the center (cos/sin), so loudness stays
          #   even as an uncorrelated signal moves
          # - :minus_4_5db: -4.5 dB at the center, a compromise between the
          #   other two
          # - :linear: -6 dB at the center, so a mono mixdown stays even
          LAWS = ChannelMethods::PAN_LAWS

          # Returns [left, right] gains for panning a mono signal to
          # +position+ with +law+ (one of LAWS).
          def self.gains(law, position)
            p = clamp(position)

            case law
            when :equal_power
              angle = (p + 1) * (Math::PI / 4)
              m = ChannelMixer.math(angle)
              [m.cos(angle), m.sin(angle)]

            when :linear
              [(1 - p) * 0.5, (p + 1) * 0.5]

            when :minus_4_5db
              # The -6 dB curve raised to the 0.75 power (as ComplexPan did)
              [((1 - p) * 0.5) ** 0.75, ((p + 1) * 0.5) ** 0.75]

            else
              raise ArgumentError, "Unknown pan law #{law.inspect} (use one of #{LAWS.map(&:inspect).join(', ')})"
            end
          end

          # Returns [left, right] gains for balancing a stereo signal to
          # +position+, as most DAWs do for stereo tracks: full level on the
          # favored side, and an equal-power fade on the other side, scaled
          # to unity at the center (about -5.3 dB at +/-0.5).
          def self.balance(position)
            p = clamp(position)
            angle = (p + 1) * (Math::PI / 4)

            if p.is_a?(Numo::NArray)
              [(Numo::NMath.cos(angle) * Math.sqrt(2)).clip(0, 1), (Numo::NMath.sin(angle) * Math.sqrt(2)).clip(0, 1)]
            else
              [[Math.cos(angle) * Math.sqrt(2), 1].min, [Math.sin(angle) * Math.sqrt(2), 1].min]
            end
          end

          # Clamps +position+ to -1..1.
          def self.clamp(position)
            position.is_a?(Numo::NArray) ? position.clip(-1, 1) : MB::M.clamp(position, -1, 1)
          end
        end
      end
    end
  end
end
