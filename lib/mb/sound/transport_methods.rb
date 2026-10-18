module MB
  module Sound
    # The transport's start and pause (maintainer, 2026-10-18: `play`,
    # `start`, and `go` with no arguments start playback, and `pause`
    # toggles; NAV Space is the same toggle).  Also `play`, `go` with no
    # arguments (see PlaybackMethods#play, ArrangementMethods#go).
    #
    #     demo          # loads a set, paused at bar 1
    #     start         # plays its flow (or play, or go)
    #     pause         # pauses; pause again plays on
    module TransportMethods
      # What #start or #pause did: +state+ (:started a flow, :resumed,
      # :paused, :playing already, :idle with nothing to start) at +at+ (a
      # Session::Stamp), and +detail+ words.
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

      # Starts playback: a paused realtime Session plays on; else, with no
      # flow playing, the loaded flow plays (the one `demo` loaded or the
      # last one built, e.g. by `flow(play: false) { }`) from its launch
      # point (+on:+, +in:+, +at:+; now by default, as #play_form);
      # otherwise it says what is playing, or that there is nothing to
      # start.  Also available as `play`, `go`, and #start_playback with no
      # arguments.  Returns a Status.
      def start(at: nil, on: nil, in: nil)
        point = LaunchPoint.of(binding) or return nil
        s = Session.current
        if s.realtime? && s.paused?
          s.paused = false
          return Status.new(:resumed, s.stamp(s.now), nil)
        end

        arr = s.arrangement
        pb = arr.playback
        return Status.new(:playing, s.stamp(s.now), "flow #{pb}") if pb && !pb.ended?

        if (f = TransportMethods.loaded_flow(arr))
          pb = arr.play_form(f, at: point) or return nil
          return Status.new(:started, s.stamp(pb.start_time), "flow #{f.steps.map(&:first).uniq.first(6).join(' ')}#{' ...' if f.steps.map(&:first).uniq.length > 6}")
        end

        return Status.new(:playing, s.stamp(s.now), "players #{s.players.keys.map(&:inspect).join(' ')}") unless s.idle?
        Status.new(:idle, s.stamp(s.now), 'nothing to start: build a flow (flow do ... end), demo, go :scene, or bg :name, sound')
      end
      alias start_playback start

      # Toggles the transport: pauses a realtime Session that is playing,
      # plays on when it is paused, and starts the loaded flow (as #start)
      # when nothing has started yet.  NAV Space in the tiles does the same.
      # In a render (or a take's replay) only the start happens: renders
      # never pause.  Returns a Status.
      def pause
        s = Session.current
        return start if TransportMethods.would_start?(s)
        return Status.new(:playing, s.stamp(s.now), 'renders do not pause') unless s.realtime?

        s.paused = true
        Status.new(:paused, s.stamp(s.now), 'pause again (or start) plays on')
      end
      alias toggle_playback pause

      # The flow #start plays in +arrangement+ when none is playing: the
      # last one built (a demo's set builds its flow as it loads), or nil.
      def self.loaded_flow(arrangement)
        arrangement.last_form || arrangement.demo_document&.form
      end

      # True when #pause would start rather than pause or resume: nothing
      # is playing in +session+ and a flow is loaded, or it is paused.
      def self.would_start?(session)
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
