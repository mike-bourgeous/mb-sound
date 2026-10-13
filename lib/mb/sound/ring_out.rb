module MB
  module Sound
    # Tracks the tail of a node that rings out after its input ends (delays
    # with feedback, plain delays and multitaps holding their last echo,
    # feedback loops): the input's end feeds silence in, and the node ends
    # once what it writes back into its delay lines has stayed below
    # THRESHOLD (-90 dB) for a whole +window+ of samples (its longest delay
    # plus the interpolation reach), since nothing louder can come out after
    # that.  The end lands on the exact sample where that quiet run is
    # complete, so a tail has the same length at any buffer size.
    #
    # With a loop gain of 1 or more the tail never decays and the node plays
    # on (like an oscillator); a Session's tails (Session::Tails) and
    # MB::Sound.write cap it.
    class RingOut
      # The level below which a written sample counts as silent (-90 dB,
      # as for Session::Tails).
      THRESHOLD = 10.0 ** (-90 / 20.0)

      # The number of quiet samples written since the last loud one (or
      # since the input ended).
      attr_reader :quiet

      def initialize
        @quiet = 0
        @done = false
      end

      # True once the quiet run has reached its window.
      def done?
        @done
      end

      # Advances the quiet run over the +count+ samples a node wrote (an
      # NArray, or nil if they were all silent) with the given +window+ (in
      # samples).  Returns nil if the tail goes on past them, or the number
      # of these samples to keep (1..count) if the quiet run reaches
      # +window+ within them (#done? is then true).
      def advance(written, count, window)
        raise 'This tail has already ended' if @done

        window = window.ceil
        window = 1 if window < 1
        run = @quiet

        loud = written.nil? ? nil : (written.abs > THRESHOLD).where
        if loud.nil? || loud.empty?
          return finish(window - run) if run + count >= window

          @quiet = run + count
          return nil
        end

        # The gap before the first loud sample
        first = loud[0]
        return finish(window - run) if run + first >= window

        # Gaps between loud samples
        if loud.length > 1
          gaps = loud.diff - 1
          idx = (gaps >= window).where
          return finish(loud[idx[0]] + 1 + window) unless idx.empty?
        end

        # The gap after the last loud sample
        last = loud[-1]
        return finish(last + 1 + window) if count - last - 1 >= window

        @quiet = count - last - 1
        nil
      end

      private

      def finish(keep)
        @done = true
        keep
      end
    end
  end
end
