module MB
  module Sound
    module GraphNode
      class ChannelMixer
        # Pans a mono signal into stereo.  +position+ goes from -1 (left)
        # through 0 (center) to 1 (right); +law+ picks the gain curve (see
        # PanLaws::LAWS).
        #
        # Created with GraphNode#pan on a single-channel node.
        class Pan < ChannelMixer
          channels 1 => 2
          param :position, default: 0, range: -1..1
          option :law, default: :equal_power, values: PanLaws::LAWS

          def gains_for(position:)
            left, right = PanLaws.gains(option(:law), position)
            [[left], [right]]
          end
        end

        # Balances a stereo signal, as most DAWs' stereo track pan controls
        # do: +position+ from -1 (left only) through 0 (unchanged) to 1
        # (right only); the favored side stays at full level and the other
        # fades out (see PanLaws.balance).
        #
        # Created with Channels#balance (and Channels#pan on stereo bundles).
        class Balance < ChannelMixer
          channels 2 => 2
          param :position, default: 0, range: -1..1

          def gains_for(position:)
            left, right = PanLaws.balance(position)
            [[left, 0], [0, right]]
          end
        end

        # Changes stereo width by scaling the side (L - R) signal: 0 is
        # mono, 1 is unchanged, and larger values are wider.  The mid/side
        # conversion and back collapse into one matrix:
        # L' = L (1 + w) / 2 + R (1 - w) / 2, and the mirror image for R'.
        #
        # Created with Channels#width.
        class Width < ChannelMixer
          channels 2 => 2
          param :amount, default: 1

          def gains_for(amount:)
            same = (amount + 1) * 0.5
            other = (1 - amount) * 0.5
            [[same, other], [other, same]]
          end
        end

        # Converts left/right stereo to mid/side: mid is (L + R) / 2 and side
        # is (L - R) / 2.  See FromMidSide.
        class MidSide < ChannelMixer
          channels 2 => 2

          def gains_for
            [[0.5, 0.5], [0.5, -0.5]]
          end
        end

        # Converts mid/side back to left/right stereo: left is M + S and
        # right is M - S.  See MidSide.
        class FromMidSide < ChannelMixer
          channels 2 => 2

          def gains_for
            [[1, 1], [1, -1]]
          end
        end

        # Swaps the left and right channels.
        class Swap < ChannelMixer
          channels 2 => 2

          def gains_for
            [[0, 1], [1, 0]]
          end
        end

        # Mixes any number of channels into one, averaging them so levels
        # stay the same for correlated channels.
        class Mono < ChannelMixer
          channels :any => 1

          def gains_for
            [Array.new(inputs.length, 1.0 / inputs.length)]
          end
        end
      end
    end
  end
end
