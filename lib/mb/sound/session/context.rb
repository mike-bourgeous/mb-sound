module MB
  module Sound
    class Session
      # Who issued the commands running on a thread, and when
      # (session-core-1; arch-session review section 5;
      # design/notes/arrangement.md, "Command context"): one frozen record
      # per thread (Session.context) in place of eight thread-local keys.
      # Each helper sets only its own fields while its block runs and puts
      # them back afterwards (Session.with_context_fields), as the separate
      # keys did, so nested helpers compose in any order.
      #
      # The issuing context (Session.with_context sets all four):
      # - +session+: the Session commands use (Session.current; nil: the
      #   default Session)
      # - +time+: a scheduled block's or set action's timeline time
      # - +batch+: a scheduled block's Batch of commands, run after it
      # - +source+: the change source (:schedule, :set, :replay)
      #
      # A take replay or an undo (Session.with_perform):
      # - +perform_session+: the replaying Session
      # - +perform_source+: the source of its changes (:replay, :undo)
      # - +forced+: the replayed line's recorded landings (Forced)
      # - +now+: the replayed line's logical issue time
      #
      # Others:
      # - +command+: the undo group of the running command (Undo#command)
      # - +take_line+: [take, line], the console line being recorded (Take)
      # - +choices+: a replaying line's recorded answers (Take.replay_choice)
      # - +deadline+: [session, description] of the scheduled block that
      #   must finish by its time (Changes#check_late)
      # - +patch_track+: [track name, session] whose patch is building
      #   (Arrangement::TrackKnobs)
      # - +song_replay+: the song script a take replays (ScriptRunner)
      # - +tempo_anchor+: [session, position] where a form pass that a seek
      #   entered mid-way began: its tempo ramps are placed from there
      #   (TempoChanges#change_tempo_map), so the seek hears what the ramp
      #   reaches where it lands
      Context = Data.define(:session, :time, :batch, :source, :perform_session, :perform_source, :forced, :now,
                            :command, :take_line, :choices, :deadline, :patch_track, :song_replay, :tempo_anchor) do
        # The logical timeline position commands for +session+ resolve
        # launch points from, or nil to use its transport position: a
        # replayed line's issue time, else a scheduled block's time (see
        # Changes#now).
        def now_for(session)
          return now if now && perform_session.equal?(session)
          return time if time && self.session.equal?(session)
          nil
        end

        # A scheduled block's or set action's time if +session+ issues it,
        # else nil.
        def time_for(session)
          time && self.session.equal?(session) ? time : nil
        end

        # The source of changes made in +session+ (journal entries).
        def source_for(session)
          (perform_session.equal?(session) ? perform_source : nil) || source || :console
        end

        # True while a take replays on this thread.
        def replaying?
          perform_source == :replay
        end

        def inspect
          "#<Session::Context #{to_h.compact.map { |k, v| "#{k}: #{v.inspect}" }.join(', ')}>"
        end
      end

      # The record with nothing set.
      Context::NONE = Context.new(**Context.members.to_h { |m| [m, nil] })

      # A replayed line's recorded landing times, taken in order by
      # Changes#change (see Take::Replay).
      class Forced
        # True once a change the take didn't have was told so (once a line).
        attr_accessor :warned

        def initialize(lands)
          @lands = lands.dup
          @warned = false
        end

        # The next landing time (or [time, given]; see Take.note_change),
        # or nil once they're used up.
        def shift
          @lands.shift
        end
      end

      # A scheduled block's commands, collected while it runs and run after
      # it as one undo step (Scheduler#run), and the tempo a `bpm` inside it
      # queued (Sequence.current_transport builds at it).
      class Batch
        # The tempo a `bpm` in the block queued, or nil.
        attr_accessor :pending_bpm

        # A Transport at #pending_bpm for build-time conversions (cached).
        attr_accessor :pending_transport

        def initialize
          @actions = []
          @pending_bpm = nil
          @pending_transport = nil
        end

        # Adds a command (a Proc) to run after the block.
        def <<(action)
          @actions << action
          self
        end

        def each(&)
          @actions.each(&)
        end

        def empty?
          @actions.empty?
        end
      end

      # The current thread's Context, or nil before anything set one.
      def self.context
        Thread.current[:mb_sound_context]
      end

      # Sets the current thread's issuing context (see Context) while the
      # block runs: commands use +session+ (Session.current), and a
      # scheduled block's +time+, +batch+, and +source+ (nil unless given).
      def self.with_context(session:, time: nil, batch: nil, source: nil, &block)
        with_context_fields(session: session, time: time, batch: batch, source: source, &block)
      end

      # Sets the current thread's take replay or undo fields (see Context)
      # while the block runs: those given (+session+, +forced+, +now+,
      # +source+), the others kept.
      def self.with_perform(**settings, &block)
        fields = settings.to_h { |k, v|
          case k
          when :session then [:perform_session, v]
          when :source then [:perform_source, v]
          when :forced then [:forced, v && Forced.new(v)]
          when :now then [:now, v]
          else raise ArgumentError, "Unknown perform setting #{k.inspect} (session, forced, now, source)"
          end
        }
        with_context_fields(**fields, &block)
      end

      # Sets +fields+ of the current thread's Context while the block runs,
      # then puts those fields back (others set inside stay as their own
      # helpers leave them).
      def self.with_context_fields(**fields)
        old = Thread.current[:mb_sound_context] || Context::NONE
        Thread.current[:mb_sound_context] = old.with(**fields)
        yield
      ensure
        if old
          cur = Thread.current[:mb_sound_context] || Context::NONE
          Thread.current[:mb_sound_context] = cur.with(**fields.to_h { |k, _| [k, old.public_send(k)] })
        end
      end

      # Sets +fields+ of the current thread's Context until changed again
      # (for state that doesn't follow a block, like the console line a
      # take records between Pry's hooks).
      def self.set_context_fields(**fields)
        Thread.current[:mb_sound_context] = (Thread.current[:mb_sound_context] || Context::NONE).with(**fields)
      end
    end
  end
end
