module MB
  module Sound
    # The transport's start and pause (maintainer, 2026-10-18: `play`,
    # `start`, and `go` with no arguments start playback, and `pause`
    # toggles; NAV Space is the same toggle).  Also `play`, `go` with no
    # arguments (see PlaybackMethods#play, ArrangementMethods#go).
    #
    # Pausing stops the transport and releases sounding notes while
    # effects ring out (maintainer, 2026-11-21; Session::TransportPause);
    # the old freeze (silence, nothing rendered) is #suspend.
    #
    #     demo               # loads a set, paused at bar 1
    #     start              # plays its flow (or play, or go)
    #     pause              # the bar stops, notes release, echoes ring out; pause again plays on
    #     start resync: true # plays on with tempo-synced LFOs back on the bar grid
    #     suspend            # the old freeze: silence, nothing renders; suspend again plays on
    module TransportMethods
      # What #start, #pause, or #suspend did: +state+ (:started a flow,
      # :resumed, :paused, :suspended, :playing already, :idle with nothing
      # to start) at +at+ (a Session::Stamp), and +detail+ words.
      Status = Data.define(:state, :at, :detail) do
        def to_s
          "#{state} at #{at}#{"; #{detail}" if detail}"
        end

        def inspect
          "#<transport #{self}>"
        end

        def pretty_print(q)
          q.text(inspect)
        end
      end

      # Starts playback: a paused transport (see #pause) plays on from
      # where it stopped, tempo-synced LFOs and delays put back on the bar
      # grid with +resync+ true (they kept running meanwhile), and a
      # suspended Session (#suspend) plays on; else, with no flow playing,
      # the loaded flow plays (the one `demo` loaded or the last one built,
      # e.g. by `flow(play: false) { }`) from its launch point (+on:+,
      # +in:+, +at:+; now by default, as #play_form); otherwise it says
      # what is playing, or that there is nothing to start.  Also
      # available as `play`, `go`, and #start_playback with no arguments.
      # Returns a Status.
      def start(at: nil, on: nil, in: nil, resync: false)
        point = LaunchPoint.of(binding) or return nil
        s = Session.current
        if s.realtime? && s.paused?
          s.paused = false
          return Status.new(:resumed, s.stamp(s.now), 'suspend ended') unless s.transport_paused?
        end
        if s.transport_paused?
          s.play_on(resync: resync)
          return Status.new(:resumed, s.stamp(s.now), resync ? 'tempo-synced LFOs back on the grid' : nil)
        end

        arr = s.arrangement
        pb = arr.playback
        return Status.new(:playing, s.stamp(s.now), "flow #{pb}") if pb && !pb.ended?

        if (f = TransportMethods.loaded_flow(arr))
          pb = arr.play_form(f, at: point) or return nil
          names = f.generative? ? f.sections.keys : f.steps.map(&:first).uniq
          return Status.new(:started, s.stamp(pb.start_time), "flow #{names.first(6).join(' ')}#{' ...' if names.length > 6}")
        end

        return Status.new(:playing, s.stamp(s.now), "players #{s.players.keys.map(&:inspect).join(' ')}") unless s.idle?
        Status.new(:idle, s.stamp(s.now), 'nothing to start: build a flow (flow do ... end), demo, go :scene, or bg :name, sound')
      end
      alias start_playback start

      # Toggles the transport: pauses a Session that is playing, plays on
      # when it is paused, and starts the loaded flow (as #start) when
      # nothing has started yet.  NAV Space in the tiles does the same.
      #
      # Pausing stops the transport on the next sample (bars, scheduled
      # blocks, the flow, and launches wait) and releases the notes
      # sounding there; audio clips, loops, drones, and other sources
      # without notes fade out over 10 ms and hold their place, and track,
      # bus, and master effects ring out (Session::TransportPause).  Playing
      # on continues from the same place without retriggering notes (see
      # #start for +resync+).  The old freeze is #suspend.  Renders
      # (PlaybackMethods#render) never pause (a take's replay does, as it
      # was played).  Returns a Status.
      def pause
        s = Session.current
        return start if TransportMethods.would_start?(s)
        return Status.new(:playing, s.stamp(s.now), 'renders do not pause') if TransportMethods.rendering?(s)

        s.pause_transport
        Status.new(:paused, s.stamp(s.now), 'effects ring out; pause again (or start) plays on')
      end
      alias toggle_playback pause

      # The old pause (until 2026-11-21): toggles a freeze of a realtime
      # Session's render thread.  While suspended the output plays silence
      # (after a 5 ms fade) and nothing renders, so the timeline, players,
      # effect tails, and scheduled blocks all wait where they are;
      # suspend again (or #start) plays on from the next sample.  Renders
      # don't suspend.  Returns a Status.
      def suspend
        s = Session.current
        return Status.new(:playing, s.stamp(s.now), 'renders do not suspend') unless s.realtime?

        if s.paused?
          s.paused = false
          return Status.new(:resumed, s.stamp(s.now), "suspend ended#{'; the transport is still paused (start plays on)' if s.transport_paused?}")
        end
        s.paused = true
        Status.new(:suspended, s.stamp(s.now), 'silence, nothing renders; suspend again (or start) plays on')
      end
      alias suspend_playback suspend

      # True if +session+ is in a render that keeps time while idle (see
      # PlaybackMethods#render: a pause there would hold the timeline short
      # of its end bar for good), where #pause does nothing; a take's
      # replay pauses as it was played, and a realtime or console-driven
      # Session pauses.
      def self.rendering?(session)
        !session.realtime? && session.advance_idle? && !Session.context&.replaying?
      end

      # The flow #start plays in +arrangement+ when none is playing: the
      # last one built (a demo's set builds its flow as it loads), or nil.
      def self.loaded_flow(arrangement)
        arrangement.last_form || arrangement.demo_document&.form
      end

      # True when #pause would start rather than pause or resume: nothing
      # is playing in +session+ and a flow is loaded, or it is paused (or
      # suspended).
      def self.would_start?(session)
        return true if session.transport_paused?
        return true if session.realtime? && session.paused?
        pb = session.arrangement.playback
        return false if pb && !pb.ended?
        session.idle? && !loaded_flow(session.arrangement).nil?
      end

      # The console line NAV Space runs in +session+ (recorded in the take):
      # `start` when it starts something, else `pause`.
      def self.toggle_line(session)
        would_start?(session) ? 'start' : 'pause'
      end
    end
  end
end
