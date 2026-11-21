module MB
  module Sound
    module Sequence
      # Prepended to timeline nodes that play audio from a place on the
      # timeline (GraphNode::LoopPlayer, GraphNode::RegionPlayer), so they
      # pause like an audio player while the transport is paused
      # (Session::TransportPause; the maintainer, 2026-11-21: "audio clips
      # pause on the spot as well with a quickfade mute, just like pausing
      # a normal audio player"): on #timeline_hold(true) the node plays on
      # for +fade_frames+ frames while fading out, then outputs zeros
      # without advancing, so it holds its place inside its graph and the
      # effects after it ring out; on #timeline_hold(false) it plays on
      # from that place, fading in over +fade_frames+ frames.
      #
      # States: nil (playing), :out (fading out), :held, :in (fading in).
      # The fades are linear steps of 1/k: the fade out ends on 0 at its
      # last frame, the fade in starts on 0 (as Session::PauseFade's).
      # Including classes set @hold_mode, @hold_k, @hold_i, and @hold_buf
      # to nil in their constructors (one instance variable layout).
      module TimelineHoldFade
        def timeline_hold_mode
          :native
        end

        def timeline_hold(on, fade_frames: 0)
          k = fade_frames.to_i
          if on
            return self if @hold_mode == :out || @hold_mode == :held
            if k <= 0
              @hold_mode = :held
            else
              @hold_mode = :out
              @hold_k = k
              @hold_i = 0
            end
          else
            return self if @hold_mode.nil? || @hold_mode == :in
            if k <= 0 || @hold_mode == :out
              # (released while still fading out: plays on at full level
              # from where the fade reached; a rare click, never a gap)
              @hold_mode = nil
            else
              @hold_mode = :in
              @hold_k = k
              @hold_i = 0
            end
          end
          self
        end

        def timeline_held?
          @hold_mode == :out || @hold_mode == :held
        end

        def sample(count)
          mode = @hold_mode
          return super if mode.nil?

          case mode
          when :held
            hold_zeros(count)

          when :out
            k = @hold_k
            i = @hold_i
            n = k - i
            n = count if count < n
            data = super(n)
            out = hold_zeros(count)
            return out if data.nil?
            n = data.length if data.length < n
            out[0...n] = data[0...n] * (Numo::SFloat.new(n).seq(k - 1 - i, -1) / k)
            @hold_i = i + n
            @hold_mode = :held if @hold_i >= k
            out

          when :in
            data = super(count)
            return data if data.nil?
            data = data.dup if data.frozen?
            k = @hold_k
            i = @hold_i
            n = k - i
            n = data.length if data.length < n
            data[0...n] = data[0...n] * (Numo::SFloat.new(n).seq(i) / k) if n > 0
            @hold_i = i + n
            @hold_mode = nil if @hold_i >= k
            data
          end
        end

        private

        # A zeroed buffer of +count+ frames for held output (reused).
        def hold_zeros(count)
          b = @hold_buf
          if b.nil? || b.length != count
            b = @hold_buf = Numo::SFloat.zeros(count)
          else
            BufferHelper.zero(b)
          end
          b
        end
      end
    end
  end
end
