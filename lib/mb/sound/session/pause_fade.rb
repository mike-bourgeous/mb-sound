module MB
  module Sound
    class Session
      # Pausing a realtime Session without a click (play-ui-1, 2026-11-02:
      # the maintainer's "spacebar play/pause" for bin/play.rb; Session#paused=
      # stopped the render thread on a buffer edge, a cut at full level).
      #
      # The render thread moves through four states, one buffer at a time:
      #
      #     state       pause asked       play asked        the buffer it writes
      #     :playing    -> :fading_out    (stays)           rendered
      #     :fading_out (renders, fades)  -> :fading_in     rendered, faded out over its last FADE_SECONDS
      #     :paused     (stays)           -> :fading_in     silence (nothing renders)
      #     :fading_in  -> :fading_out    (renders, fades)  rendered, faded in over its first FADE_SECONDS
      #
      # after which :fading_out becomes :paused and :fading_in :playing.
      # Nothing renders while paused, so the timeline, the players, and
      # scheduled blocks wait where they are, and playing on renders the
      # next sample after the last one rendered: the frames are exact
      # (renders, stems, recordings, taps, and the UI's meters see the
      # unfaded mix, which is continuous across the pause; only what the
      # output plays fades).  TRANSITIONS is the table above.
      module PauseFade
        # How long the fades are (seconds; the whole buffer when shorter).
        FADE_SECONDS = 0.005

        # [state, request] => the state for the next buffer (request
        # :pause or :play: what #paused= asked).
        TRANSITIONS = {
          [:playing, :pause] => :fading_out, [:playing, :play] => :playing,
          [:fading_out, :pause] => :paused, [:fading_out, :play] => :fading_in,
          [:paused, :pause] => :paused, [:paused, :play] => :fading_in,
          [:fading_in, :pause] => :fading_out, [:fading_in, :play] => :playing,
        }.freeze

        # The render thread's pause state (see PauseFade).
        def pause_state = @pause_state

        private

        def init_pause_fade
          @pause_state = :playing
        end

        # The render thread, before each buffer: the state that buffer
        # plays in (:playing, :fading_out, :paused, :fading_in).
        def next_pause_state
          @pause_state = TRANSITIONS.fetch([@pause_state, @paused ? :pause : :play])
        end

        # +bufs+ faded for the buffer's pause state: out over the last
        # FADE_SECONDS while :fading_out, in over the first while
        # :fading_in (new Arrays; +bufs+ may be the render thread's reused
        # mix), else +bufs+ itself.
        def pause_faded(bufs)
          s = @pause_state
          return bufs unless s == :fading_out || s == :fading_in
          n = bufs[0]&.length.to_i
          return bufs if n == 0

          k = [(FADE_SECONDS * output.sample_rate).round, n].min.clamp(1, n)
          ramp = Numo::SFloat.ones(n)
          # (exact steps of 1/k: the fade out ends on 0, the fade in starts there)
          if s == :fading_out
            ramp[(n - k)..] = Numo::SFloat.new(k).seq(k - 1, -1) / k
          else
            ramp[0...k] = Numo::SFloat.new(k).seq / k
          end
          bufs.map { |c| c * ramp }
        end

        # The render thread's loop body: a buffer in the current pause state.
        def render_or_pause
          if next_pause_state == :paused
            n = buffer_size
            output.write(Array.new(output.channels) { Numo::SFloat.zeros(n) })
          else
            process_buffer
          end
        end
      end
    end
  end
end
