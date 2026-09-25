module MB
  module Sound
    class Session
      # Fade handling for Session players: default fade lengths in bars, and
      # per-frame gain ramps for fading in, out, and across replacements.
      # Fade lengths follow the Session's transport tempo.
      module Fades
        # Bars to fade in new graphs when Session#add isn't given a +:fade+
        # (nil for no fade).  Graphs replacing a named graph switch over
        # without a fade unless Session#add is given one.
        attr_reader :fade_in

        # Bars to fade out graphs when Session#remove isn't given a +:fade+
        # (nil to stop right away).
        attr_reader :fade_out

        # Sets the default fade-in length in bars (nil, 0, or false for none).
        def fade_in=(bars)
          @fade_in = bars_or_nil(bars)
        end

        # Sets the default fade-out length in bars (nil, 0, or false for none).
        def fade_out=(bars)
          @fade_out = bars_or_nil(bars)
        end

        private

        # Converts a fade length to a positive Rational number of bars, or nil
        # for no fade (nil, false, or 0).
        def bars_or_nil(bars)
          return nil if bars.nil? || bars == false || bars == 0
          raise ArgumentError, "Fade must be a positive number of bars (got #{bars.inspect})" unless bars.is_a?(Numeric) && bars.finite? && bars > 0
          bars.is_a?(Float) ? bars.rationalize(Rational(1, 10_000)) : bars.to_r
        end

        # The gain change per frame for a fade lasting +bars+ at the current
        # tempo.
        def fade_step(bars, rate)
          1.0 / (@transport.seconds(bars * @transport.bar_length) * rate)
        end

        # Returns a Numo::SFloat of per-frame gains for a fading player (and
        # advances its fade), or nil if the player is at full volume.
        def fade_ramp(p, frames)
          return nil if p.gain >= 1 && p.gain_step >= 0

          ramp = Numo::SFloat.new(frames).seq(p.gain, p.gain_step).clip(0, 1)
          p.gain = MB::M.clamp(p.gain + p.gain_step * frames, 0.0, 1.0)
          p.gain_step = 0.0 if p.gain >= 1 && p.gain_step > 0
          ramp
        end
      end
    end
  end
end
