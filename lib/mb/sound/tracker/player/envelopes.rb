module MB
  module Sound
    module Tracker
      class Player
        # Instrument envelopes, fadeout, and key off for XM and IT channels
        # (see Tracker::Envelope): the volume envelope's value (0..64) at the
        # channel's envelope tick, interpolated between points, held at a
        # sustain point while the key is on, looping between loop points;
        # after key off the volume fades by the instrument's fadeout every
        # tick.
        module Envelopes
          # The envelope's value at +tick+ (linear between points), or nil
          # without an enabled envelope.
          def envelope_value(env, tick)
            return nil unless env&.enabled
            pts = env.points
            return pts[0][1].to_f if pts.length == 1 || tick <= pts[0][0]
            k = pts.rindex { |x, _| x <= tick } || 0
            return pts[k][1].to_f if k >= pts.length - 1
            x0, y0 = pts[k]
            x1, y1 = pts[k + 1]
            return y1.to_f if x1 <= x0
            y0 + (y1 - y0) * (tick - x0).to_f / (x1 - x0)
          end

          # The tick after +tick+ for +env+: held at a sustain point while
          # +key_on+, back to the loop start at the loop end, else on (to
          # the last point, where it stays).
          def envelope_next(env, tick, key_on, sustain: env&.sustain, loop: env&.loop)
            return tick unless env&.enabled
            pts = env.points
            if key_on && sustain
              s0, s1 = sustain
              return pts[s0][0] if s0 == s1 && tick >= pts[s0][0] && tick <= pts[s0][0]
              return pts[s0][0] if s0 != s1 && tick >= pts[s1][0]
            end
            if loop && tick >= pts[loop[1]][0]
              return pts[loop[0]][0]
            end
            [tick + 1, pts.last[0]].min
          end

          # True if the envelope sits at its last point with nothing to loop
          # (an ended envelope).
          def envelope_done?(env, tick, _key_on)
            return false unless env&.enabled
            !env.loop && tick >= env.points.last[0]
          end
        end
      end
    end
  end
end
