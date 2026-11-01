module MB
  module Sound
    module UI
      class Keyboard
        # KEYS mode on the sound-design screen (ux-notes-2; the maintainer's
        # note 6, "Opening the keyboard in sound design mode should give me
        # control over the sound and stop whatever else was feeding it", and
        # his choice "Arm + hold the clip", 2026-11-02): entering KEYS with a
        # track inspected arms it with monitoring and holds what else plays
        # it (`hold`: its clip, cue player, and wired stream; Session::Holds)
        # until KEYS ends, which puts back what was there: the hold released
        # (the clip in time, as unmute does) and the arm as it was.  Every
        # step is a console line (journaled, undoable, in the take), printed
        # in the REPL pane.
        #
        # The keyboard plays into the input the track's monitor reads: the
        # default input, the one it was armed on (`arm :lead, input:
        # :keys`), or its wire input when it is wired (Link#input=).
        #
        # States: :off and :on (one track taken over at a time):
        #
        #   state  event   to    does
        #   off    enter   on    arm (unless monitoring), hold (unless held), the keyboard's input
        #   off    leave   off   nothing
        #   on     enter   on    nothing (already taken over)
        #   on     leave   off   unhold (if it held), the arm put back (if it armed), the input back
        class Takeover
          TABLE = {
            [:off, :enter] => :on, [:off, :leave] => :off, [:on, :enter] => :on, [:on, :leave] => :off,
          }.freeze

          # What one takeover did (to put back on leave): +session+, +track+,
          # +arm+ (nil: left as it was; [:disarm, nil]: was disarmed;
          # [:silent, input]: was armed without a monitor), +held+ (true if it held the track),
          # +input+ (the keyboard's input before).
          Taken = Data.define(:session, :track, :arm, :held, :input)

          attr_reader :state, :taken

          # +run+ runs a console line: ->(code, note) (UI::Tiles prints it
          # in the REPL pane through UI.run_line).
          def initialize(run:)
            @run = run
            @state = :off
            @taken = nil
          end

          # Takes track +track+ of +session+ over for keyboard +out+ (a
          # Keyboard::Link, or anything; only a Link's input follows).  Does
          # nothing for a track without a patch (a graph track has nothing
          # to monitor).  Returns the lines run.
          def enter(session, track, out = nil)
            go(:enter) { |was|
              next [] if was == :on
              tr = session&.arrangement&.tracks&.[](track)
              next [] unless tr.respond_to?(:patch?) && tr.patch?

              lines = []
              arm = session.arrangement.arms[track]
              undo_arm = nil
              # (a silent wired arm keeps its wire: its stream can't be
              # given again as a line)
              unless arm&.monitoring? || arm&.wired?
                undo_arm = arm ? [:silent, arm.input] : [:disarm, nil]
                lines << run("arm #{track.inspect}#{arm&.input ? ", input: #{arm.input.inspect}" : ''}", "keys: #{track} armed (its patch plays the keyboard)")
                arm = session.arrangement.arms[track]
              end
              held = false
              unless session.track_held?(track)
                lines << run("hold #{track.inspect}", "keys: #{track}'s clip held until KEYS ends")
                held = true
              end
              input = nil
              if out.respond_to?(:input=)
                input = out.input
                out.input = arm&.input
              end
              @taken = Taken.new(session: session, track: track, arm: undo_arm, held: held, input: input)
              lines
            }
          end

          # Puts back what #enter changed (what still is as it left it: a
          # hold undone meanwhile isn't released again).  Returns the lines
          # run.
          def leave(out = nil)
            go(:leave) { |was|
              t = @taken
              @taken = nil
              next [] unless was == :on && t

              out.input = t.input if out.respond_to?(:input=)
              lines = []
              s = t.session
              next lines if s.closed?
              lines << run("unhold #{t.track.inspect}", "keys: #{t.track}'s clip back in time") if t.held && s.track_held?(t.track)
              if t.arm && s.arrangement.armed?(t.track)
                how, input = t.arm
                code = how == :disarm ? "disarm #{t.track.inspect}" : "arm #{t.track.inspect}, monitor: false#{input ? ", input: #{input.inspect}" : ''}"
                lines << run(code, "keys: #{t.track} #{how == :disarm ? 'disarmed' : 'armed without a monitor'} as before")
              end
              lines
            }
          end

          # True while a track is taken over.
          def on? = @state == :on

          # The transition table as text (for help and specs).
          def self.table = TABLE

          private

          def go(event)
            was = @state
            @state = TABLE.fetch([was, event])
            yield was
          end

          def run(code, note)
            @run.call(code, note)
            code
          end
        end
      end
    end
  end
end
