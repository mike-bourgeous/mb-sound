module MB
  module Sound
    # When a foreground playback is over: one rule for every kind of sound
    # (play-ui-1, 2026-11-02; the maintainer's "bin/play.rb didn't exit
    # after cry4bass.mod ended").  PlaybackMethods#play, #play_genre,
    # #play_tracker, and bin/play.rb's Player wait on one of these.
    #
    # Each #check observes the Session and moves through the states:
    #
    #     :starting  nothing has sounded yet
    #     :playing   the sound is playing (+busy+ is true)
    #     :tail      the source is over (+over+, e.g. a form ended) while
    #                something still plays: at most MAX_TAIL_SECONDS of
    #                rendered audio more
    #     :ended     done (+leftovers+: the tail ran out with players
    #                still playing, which the caller stops)
    #     :failed    the render thread stopped with an error (#reason)
    #     :stalled   no buffer rendered for STALL_SECONDS while not
    #                paused (the output stopped taking audio)
    #     :closed    the Session was closed
    #
    # Before, each kind had its own lambda (`!started || busy`), which
    # waited forever when nothing ever started (a form whose start block
    # ran late was skipped), when the render thread died (silence, and the
    # players never left), or when the output stopped taking audio.
    #
    # Times count rendered frames (Session#frames_rendered), so a pause
    # doesn't run them out, and a virtual-clock NullOutput gives the same
    # states every run; only the stall check reads the wall clock.
    class PlaybackEnd
      # The states (see the class comment).
      STATES = %i[starting playing tail ended failed stalled closed].freeze

      # The states a playback ends in.
      ENDS = %i[ended failed stalled closed].freeze

      # What #check observes, in priority order: :closed, :failed,
      # :stalled, then :busy (something plays), :over (the source is over),
      # :tail_out (MAX_TAIL_SECONDS of tail rendered), :start_out
      # (START_SECONDS rendered without anything sounding), :waiting (not
      # yet), :quiet.
      EVENTS = %i[closed failed stalled busy over tail_out start_out waiting quiet].freeze

      # [state, event] => next state; pairs not listed keep the state.
      TABLE = {
        [:starting, :busy] => :playing, [:starting, :start_out] => :ended, [:starting, :over] => :ended,
        [:playing, :quiet] => :ended, [:playing, :over] => :tail,
        [:tail, :quiet] => :ended, [:tail, :tail_out] => :ended,
      }.freeze

      # Seconds of rendered audio a playback may take to start sounding
      # (a launch queued for the next bar, a form's first section).
      START_SECONDS = 8

      # Seconds of tail after the source is over (Session::MAX_TAIL_SECONDS).
      MAX_TAIL_SECONDS = Session::Master::MAX_TAIL_SECONDS

      # Wall-clock seconds without a rendered buffer that count as a stall.
      STALL_SECONDS = 3.0

      # The PlaybackEnd of a set played by a form (+playback+, a
      # Form::Playback): busy while players play, or, until the form ends,
      # while its scheduled blocks wait (scene launches ahead); over once
      # the form ended (its tail plays out, then leftovers stop).
      #
      # (play-ui-1: the form's last block runs ahead of its time, the end
      # of a module's one-tick :fin, and Session#schedule_waiting? counts
      # it until the timeline reaches that time; but :fin's cut left
      # nothing playing, and a live timeline paused short of it whenever
      # the last buffer ended inside the tick (5 ms of declick, then idle:
      # every time at 512-frame JACK buffers), so the old rule, which
      # counted waiting blocks whether the form had ended or not, waited
      # forever.  Forms now keep the timeline moving to their end, see
      # Form::Playback#keeps_time?; this rule holds either way.)
      def self.for_form(session, playback)
        ended = playback.respond_to?(:ended?) ? -> { playback.ended? } : -> { false }
        new(
          session,
          busy: -> { !session.idle? || (!ended.call && (session.schedule_waiting?(repeating: false) || session.schedule_due?)) },
          over: ended
        )
      end

      attr_reader :state

      # True if the tail ran out with players still playing (the caller
      # stops them).
      attr_reader :leftovers

      # +session+ the Session playing; +busy+ a Proc, true while the sound
      # plays; +over+ a Proc (or nil), true once its source is over though
      # things may still play (a form that ended).  +clock+ returns wall
      # seconds (for specs).
      def initialize(session, busy:, over: nil, clock: -> { MB::U.clock_now })
        @session = session
        @busy = busy
        @over = over
        @clock = clock
        @state = :starting
        @leftovers = false
        @start_frame = session.frames_rendered
        @tail_frame = nil
        @seen_frame = @start_frame
        @seen_at = clock.call
      end

      # Observes the Session and returns the state.
      def check
        return @state if ENDS.include?(@state)

        event = observe
        if %i[closed failed stalled].include?(event)
          @state = event
        else
          nxt = TABLE[[@state, event]]
          if nxt
            @leftovers = true if @state == :tail && event == :tail_out
            @tail_frame = @session.frames_rendered if nxt == :tail
            @state = nxt
          end
        end
        @state
      end

      # True once the playback is over (checks first).
      def over?
        ENDS.include?(check)
      end

      # What ended it, in words (nil while it plays).
      def reason
        case @state
        when :ended then @leftovers ? "the song ended; stopped what still played after #{MAX_TAIL_SECONDS} s" : nil
        when :failed
          e = @session.render_error
          e ? "the render thread stopped: #{e.class}: #{e.message}" : 'the render thread stopped'
        when :stalled then "the output took no audio for #{STALL_SECONDS} s"
        when :closed then 'the session was closed'
        end
      end

      def inspect
        "#<MB::Sound::PlaybackEnd #{@state}#{' (leftovers)' if @leftovers}>"
      end

      private

      def observe
        s = @session
        return :closed if s.closed?
        return :failed if s.render_error || (s.realtime? && !s.running?)
        return :stalled if stalled?

        rate = s.sample_rate.to_f
        frames = s.frames_rendered
        over = @over&.call
        busy = @busy.call
        if @state == :tail
          return :tail_out if frames - @tail_frame >= MAX_TAIL_SECONDS * rate
          return busy ? :busy : :quiet
        end
        return :over if over && (@state == :playing || !busy)
        return :busy if busy
        return :start_out if @state == :starting && frames - @start_frame >= START_SECONDS * rate
        @state == :starting ? :waiting : :quiet
      end

      # True if no buffer was rendered for STALL_SECONDS while the Session
      # isn't paused.
      def stalled?
        return false unless @session.realtime?
        now = @clock.call
        frames = @session.frames_rendered
        if frames != @seen_frame || @session.paused? || @session.pause_state == :paused
          @seen_frame = frames
          @seen_at = now
          return false
        end
        now - @seen_at >= STALL_SECONDS
      end
    end
  end
end
