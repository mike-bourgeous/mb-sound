module MB
  module Sound
    class Session
      # The live safety limiter (omnibus9, the maintainer's pick of
      # 2026-10-18): a realtime Session with no master chain or preset ends
      # what it writes to its output in a transparent limiter at
      # SAFETY_CEILING (-1 dBFS sample peak, about -1 dBTP), so a hot patch
      # tried in the console can't hit the speakers at full scale.  It is
      # bit-transparent below the ceiling (unity gain until a peak passes
      # it) and adds no latency (no lookahead: the gain drops on the
      # sample that would pass the ceiling and recovers over
      # SAFETY_RELEASE), so it can switch in and out with the master chain
      # without a time jump.
      #
      # It sits where a master chain would end: after the master gain
      # (also a post-chain one, Session#master_gain_post), before the CUE
      # split and the monitor trim (a listening gain, which keeps its own
      # clip warning; see MonitorTrim).  Like the monitor trim it reaches
      # only the live output: renders (non-realtime Sessions), stems,
      # #record_audio files, taps, takes, and captures read the mix before
      # it.  Any master chain (`master { |mix| ... }`, a preset) turns it
      # off, including old chains still ringing out; `master nil` (bypass)
      # brings it back.  Session#master_info says when it is on.
      module SafetyLimiter
        # The safety limiter's ceiling.
        SAFETY_CEILING = -1.db

        # How fast the safety limiter's gain recovers after a peak.
        SAFETY_RELEASE = 0.1

        # True if this Session limits its live output when no master chain
        # is set (by default when it applies the monitor trim, i.e. when
        # realtime; see SafetyLimiter).
        attr_accessor :safety_limiter

        # True if the safety limiter reaches the output now (on, and no
        # master chain).
        def safety_limiting?
          !!@safety_limiter && !master_active?
        end

        private

        def init_safety_limiter(on)
          @safety_limiter = on
          @safety_source = nil
          @safety_nodes = nil
          @safety_in = nil # (reused by #safety_limited)
          @safety_out = nil
        end

        # The main mix to write: +mix+ through the safety limiter when it
        # applies, else +mix+ itself.  The limiter hears every buffer while
        # it is on (its gain stays current while a master chain plays).
        def safety_limited(mix)
          return mix unless @safety_limiter

          if @safety_source.nil? || @safety_nodes.length != mix.length
            @safety_source = GraphNode::MixSource.new(channels: mix.length, sample_rate: sample_rate)
            # Linked across channels (one gain), so the image doesn't move
            @safety_nodes = GraphNode::Channels.new(@safety_source.outputs)
              .limit(ceiling: SAFETY_CEILING, lookahead: 0, true_peak: false, release: SAFETY_RELEASE).outputs
          end
          # (reused Arrays: it runs every buffer of a live session)
          ins = (@safety_in ||= [])
          ins.clear
          mix.each { |c| ins << Numo::SFloat.cast(c) }
          @safety_source.write(ins)
          out = (@safety_out ||= [])
          out.clear
          n = mix[0].length
          @safety_nodes.each { |node| out << node.sample(n) }
          master_active? ? mix : out
        end
      end
    end
  end
end
