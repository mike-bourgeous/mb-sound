require_relative '../node_traits'

module MB
  module Sound
    module Sequence
      # Mixin for graph nodes that follow a Transport's timeline, like
      # MIDI::ClipSource (clips), TempoNode (tempo-synced frequencies and delay
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
        # for a graph launched at timeline position +origin+ (the start of
        # the graph's first sample).  +launch+ is the exact launch time the
        # graph was scheduled for (e.g. a bar line), which can fall up to a
        # sample after +origin+; launch-aligned looping clips count their
        # cycles from it (see Sequence::Clip#loop).  If a +transport+ is
        # given, this node follows it from now on.  Returns self.
        def start_at(time, origin: time, launch: origin, transport: nil)
          @transport = transport if transport
          @timeline_paused = false
          @timeline_launch = launch.to_r
          timeline_start(time.to_r, origin.to_r)
          self
        end

        # The exact launch time given to the last #start_at (whole notes), or
        # nil before the first.
        def timeline_launch
          @timeline_launch
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

        # How this node holds while the transport is paused
        # (Session::TransportPause; pause-tails-1, 2026-11-21): :native
        # for nodes that hold their place themselves through
        # #timeline_hold (clip sources, loop and region players, time
        # limits), :runs for nodes that keep running in wall time
        # (TempoNode: synced LFO rates and delay times; re-placed on resume
        # only with a resync), and :restart (the default) for nodes that
        # are re-placed at the held position by #start_at on resume
        # (timeline-following MIDI transforms).
        def timeline_hold_mode
          :restart
        end

        # Holds (+on+ true) or releases this node's place on the timeline
        # while the transport is paused, fading over +fade_frames+ where
        # the node makes sound (see #timeline_hold_mode).  The Session
        # calls it with every span while paused (so holding is idempotent)
        # and once on resume.  Does nothing unless the node holds natively.
        # Returns self.
        def timeline_hold(on, fade_frames: 0)
          self
        end

        # True while this node holds its place (see #timeline_hold).
        def timeline_held?
          false
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

# Timeline nodes say how they follow the timeline (NodeTraits' +timeline+).
MB::Sound::NodeTraits.attach(MB::Sound::Sequence::TimelineNode)
