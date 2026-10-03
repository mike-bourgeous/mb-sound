module MB
  module Sound
    module GraphNode
      class ChannelMixer
        # Places a mono source in a two-channel (Lt/Rt) phase-amplitude
        # field, as matrix surround encoders do: +x+ from -1 (left) to 1
        # (right) sets the level of each channel (with a pan +law+, see
        # PanLaws), and +y+ from 1 (front) to -1 (rear) sets the phase
        # difference between them: in phase at the front, 90 degrees apart
        # at y = 0, and opposite (180 degrees) at the rear.  Positive phase
        # means the right channel leads, matching the matrix encoders in
        # matrices/ and the old ComplexPan.
        #
        # The gains are complex, so a real input passes through a Hilbert
        # filter (see ChannelMixer) and the outputs are real; a complex
        # input (e.g. a complex oscillator) gives complex outputs.
        #
        # Created with GraphNode#place (alias #position).
        #
        # Examples (bin/sound.rb):
        #     bg 220.hz.ramp.at(0.3).place(x: -1, y: -1)              # rear left
        #     bg 220.hz.ramp.at(0.3).place(x: 2.hz.lfo, y: 0.3.hz.lfo)  # circling
        class Position < ChannelMixer
          channels 1 => 2
          param :x, default: 0, range: -1..1
          param :y, default: 1, range: -1..1
          option :law, default: :equal_power, values: PanLaws::LAWS

          def gains_for(x:, y:)
            left, right = PanLaws.gains(option(:law), x)
            half = (1 - PanLaws.clamp(y)) * (Math::PI / 4) # half the phase difference
            [[left * rotation(-half)], [right * rotation(half)]]
          end

          # Returns the phase difference in radians (right relative to left)
          # for a +y+ position: 0 at the front, pi at the rear.
          def self.phase(y)
            (1 - PanLaws.clamp(y)) * (Math::PI / 2)
          end

          private

          def complex_gains?
            true
          end

          # e^(i * angle) for a number or an NArray of angles.
          def rotation(angle)
            if angle.is_a?(Numo::NArray)
              Numo::NMath.cos(angle) + Numo::NMath.sin(angle) * 1i
            else
              Complex.polar(1, angle)
            end
          end
        end
      end
    end
  end
end
