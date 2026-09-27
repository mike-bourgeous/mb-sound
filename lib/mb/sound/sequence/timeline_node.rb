module MB
  module Sound
    module Sequence
      # Mixin for graph nodes that follow a Transport's timeline, like
      # ClipNode (clips), TempoNode (tempo-synced frequencies and delay
      # times), and the LFOs built on them.
      #
      # Session finds these nodes in every graph it plays (including master
      # effects chains) and calls #start_at when the graph starts, when the
      # timeline jumps (seeks), and when playback resumes after the timeline
      # was paused, so the node can line itself up with the timeline and
      # follow the session's transport (e.g. a render's own transport).
      #
      # Including classes implement #timeline_start, and may set
      # @transport in their constructor (Sequence.transport by default).
      module TimelineNode
        # Starts following the timeline at position +time+ (in whole notes)
        # for a graph launched at timeline position +origin+.  If a
        # +transport+ is given, this node follows it from now on.  Returns
        # self.
        def start_at(time, origin: time, transport: nil)
          @transport = transport if transport
          @timeline_paused = false
          timeline_start(time.to_r, origin.to_r)
          self
        end

        # Called by Session for each buffer rendered while the timeline is
        # paused (nothing is playing, but e.g. master effects keep running).
        # #start_at ends the pause.
        def pause_timeline
          @timeline_paused = true
        end

        # True if the timeline is paused (see #pause_timeline).
        def timeline_paused?
          !!@timeline_paused
        end

        # The Transport this node follows for tempo and position.
        def transport
          @transport ||= Sequence.transport
        end

        private

        # Called by #start_at with the timeline position and the graph's
        # launch position (both Rational whole notes).
        def timeline_start(time, origin)
          raise NotImplementedError, "#{self.class} must implement #timeline_start"
        end
      end
    end
  end
end
