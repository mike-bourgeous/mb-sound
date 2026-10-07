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

          private

          # Law numbers for MB::Sound::FastArithmetic.pan.
          FAST_LAWS = { equal_power: 0, linear: 1, minus_4_5db: 2 }.freeze

          # A moving position with single-precision buffers pans in C
          # without allocating (the same values as #gains_for and #mix).
          def mix_params(values, data)
            position = values[:position]
            input = data[0]
            return nil unless position.is_a?(Numo::SFloat) && input.is_a?(Numo::SFloat)

            length = input.length
            if @pan_gains.nil? || @pan_gains[0].length != length
              @pan_gains = Array.new(2) { Numo::SFloat.zeros(length) }
              @pan_rows = @pan_gains.map { |g| [g] }
              @pan_outputs = Array.new(2) { Numo::SFloat.zeros(length) }
            end

            return nil unless MB::Sound::FastArithmetic.pan(FAST_LAWS.fetch(option(:law)), position, input, @pan_gains, @pan_outputs)

            @last_gains = @pan_rows
            @pan_outputs
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
