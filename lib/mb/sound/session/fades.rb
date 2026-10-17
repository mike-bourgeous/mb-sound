module MB
  module Sound
    class Session
      # Fade handling for Session players: default fade lengths in bars, and
      # per-frame gain ramps for fading in, out, and across replacements.
      # Fade lengths follow the Session's transport tempo when the fade
      # starts.
      #
      # Ramps are counted in session frames from their first sample (see
      # Ramp), so a fade starts on the exact sample of its time and has the
      # same values whatever the buffer size (a take replays bit for bit at
      # any buffer size; see MB::Sound::Take).
      module Fades
        # A linear gain ramp from +from+ to +to+ over +length+ frames,
        # starting at session frame +start+ (where the level is still
        # +from+; it reaches +to+ at +start+ + +length+).
        Ramp = Struct.new(:from, :to, :start, :length) do
          # The level at session frame +frame+.
          def at(frame)
            k = frame - start
            return from if k <= 0
            return to if k >= length
            k * slope + from
          end

          # The level change per frame.
          def slope
            (to - from) / length.to_f
          end

          # True if the ramp has reached +to+ by session frame +frame+.
          def done?(frame)
            frame - start >= length
          end

          # A Numo::SFloat of the levels for +count+ frames from session
          # frame +frame+ (the same values as #at: each depends only on its
          # frame, so any buffer size gives the same levels).
          def levels(frame, count)
            k0 = frame - start
            k = Numo::DFloat.new(count).seq(k0)
            k = k.clip(0, length) if k0 < 0 || k0 + count > length
            # SFloat, since multiplying SFloat audio by a DFloat is ~20x
            # slower in Numo than casting first
            Numo::SFloat.cast(k.inplace * slope + from)
          end
        end

        # Seconds for a declick ramp: mutes, solos, and undo switch over
        # this quickly unless given a fade.
        DECLICK_SECONDS = 0.005

        # Bars to fade in new graphs when Session#add isn't given a +:fade+
        # (nil for no fade).  Graphs replacing a named graph crossfade over
        # DECLICK_SECONDS unless Session#add is given a fade.
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

        # A declick length (DECLICK_SECONDS) in bars at the current tempo,
        # for fades that should be as short as possible without clicking.
        def declick_bars
          Rational(DECLICK_SECONDS.to_r * @transport.whole_notes_per_second, @transport.bar_length)
        end

        private

        # Converts a fade length (a number of bars or a Duration like
        # 2.beats) to a positive Rational number of bars, or nil for no fade
        # (nil, false, or 0).
        def bars_or_nil(bars)
          bars = Sequence::Duration.bars(bars, @transport.bar_length, transport: @transport)
          return nil if bars.nil? || bars == false || bars == 0
          raise ArgumentError, "Fade must be a positive number of bars (got #{bars.inspect})" unless bars.is_a?(Numeric) && bars.finite? && bars > 0
          Sequence::Duration.rational(bars)
        end

        # The gain change per frame for a fade lasting +bars+ at the current
        # tempo (used by master chain crossfades).
        def fade_step(bars, rate)
          1.0 / (@transport.seconds(bars * @transport.bar_length) * rate)
        end

        # The number of frames (at least 1) in a fade lasting +bars+ at the
        # current tempo.
        def fade_frames(bars, rate)
          MB::M.max((@transport.seconds(bars * @transport.bar_length) * rate).round, 1)
        end

        # A player's fade level at session frame +frame+.
        def fade_level(p, frame)
          p.ramp ? p.ramp.at(frame) : p.gain
        end

        # Starts a player's fade out at session frame +frame+, from its
        # level there, at the speed of a full fade over +bars+ (so a player
        # still fading in fades out sooner).
        def start_fade_out(p, frame, bars, rate)
          level = fade_level(p, frame)
          p.ramp = Ramp.new(level, 0.0, frame, MB::M.max((level * fade_frames(bars, rate)).round, 1))
          p.fading_out = true
        end

        # Returns a Numo::SFloat of per-frame gains for +frames+ frames from
        # session frame +frame+ through a ramp (or nil at full level), and
        # settles the ramp into the constant level once it is done.  +level+
        # and +ramp+ are read and written through the given accessors.
        def ramp_levels(p, level_field, ramp_field, frame, frames)
          ramp = p[ramp_field]
          if ramp.nil?
            level = p[level_field]
            return nil if level >= 1
            return Numo::SFloat.new(frames).fill(level)
          end

          levels = ramp.levels(frame, frames)
          if ramp.done?(frame + frames)
            p[level_field] = ramp.to
            p[ramp_field] = nil
          end
          levels
        end

        # Returns per-frame gains for a player's fade (see #ramp_levels).
        def fade_ramp(p, frame, frames)
          ramp_levels(p, :gain, :ramp, frame, frames)
        end
      end
    end
  end
end
