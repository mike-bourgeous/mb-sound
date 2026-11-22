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
      def start(*_names, at: nil, on: nil, in: nil, resync: false)
        unless _names.empty?
          # (ux-friction-1: the maintainer's `start :pluck`)
          n = _names.first.inspect
          return MB::Sound.live_error(ArgumentError.new(
            "start starts the transport and the loaded flow and takes no names; bg #{n} plays a track's clip again " \
            "(launch #{n}, :clip plays one of its clips; go :scene launches a scene)"
          ))
        end
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

      # True when +session+'s transport is paused (#pause) or the Session
      # is suspended (#suspend): #start, NAV Space, and a bare
      # PlaybackMethods#resume play on from there.
      def self.paused?(session)
        session.transport_paused? || (session.realtime? && session.paused?)
      end

      # True when #pause would start rather than pause or resume: nothing
      # is playing in +session+ and a flow is loaded, or it is paused (or
      # suspended).
      def self.would_start?(session)
        return true if paused?(session)
        pb = session.arrangement.playback
        return false if pb && !pb.ended?
        session.idle? && !loaded_flow(session.arrangement).nil?
      end

      # What #start says before it starts the loaded flow of +session+
      # (Arrangement#start_note), or nil when it would resume, play on, or
      # do nothing (for NAV Space's flash).
      def self.start_note(session)
        return nil if paused?(session) || !would_start?(session)
        f = loaded_flow(session.arrangement) or return nil
        session.arrangement.start_note(f)
      end

      # NAV Space's instant flash for +line+ (from #toggle_line), drawn
      # while the line still runs (ui-phase1-1): a resume says so, a start
      # of the loaded flow what it builds (#start_note's words) or that it
      # warms the tracks first, a pause nothing (the Status after the line
      # says what happened).  Reads only flags the render thread sets and
      # the Arrangement's own lock, never the render lock (the screen's
      # input thread asks; followups-1).
      def self.toggle_flash(session, line)
        return nil unless line == 'start'
        return 'resuming ...' if paused?(session)
        f = loaded_flow(session.arrangement) or return nil
        session.arrangement.start_note(f) || 'starting... (warming the tracks first)'
      end

      # The console line NAV Space runs in +session+ (recorded in the take):
      # `start` when it starts something, else `pause`.
      def self.toggle_line(session)
        would_start?(session) ? 'start' : 'pause'
      end
    end
  end
end
