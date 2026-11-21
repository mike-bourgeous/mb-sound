require 'mb/term'

module MB
  module Sound
    module UI
      # Keys of a pane's own (ux-1 round 3 item 36): a pane kind declares
      # a keymap, which the tiled screen consults first in NAV while the
      # pane is focused (the `?` overlay lists it above NAV's keys), and
      # each binding calls the pane's key_<action> method with the pane's
      # per-placement state Hash (kept in the layout; ui.save keeps what
      # the layout keeps).  A key_ method may return a String: the status
      # line flashes it.
      #
      #     class Scope < Pane
      #       keys do
      #         group 'Scope'
      #         on 'L', :cycle_look, help: 'next look (braille, quad, ...)'
      #       end
      #
      #       def key_cycle_look(state)
      #         state[:look] = ...
      #         "look #{state[:look]}"
      #       end
      #     end
      #
      # Pick keys NAV doesn't need (NAV's are listed by help :ui); a pane's
      # key shadows NAV's while the pane is focused.  Included in UI::Pane.
      #
      # A pane's own mode (ux-r4: the Router's :pane state) takes every key
      # but Esc and Ctrl-]: `mode_keys` declares them (cursor keys, Enter,
      # letters; NAV's keys don't apply there), NAV Enter on the focused
      # pane enters the mode, Esc or Ctrl-] leave it, and the per-placement
      # state has `state[:mode] == true` meanwhile (draw a cursor then).
      # Keys of `keys` work in the mode too.  `jump 'a'` gives the kind a
      # NAV jump letter (focus it and enter its mode, as Enter would; shown
      # beside its number in NAV), which Keys.check_jumps keeps clear of
      # NAV's keys and each other.
      #
      #     class Matrix < Pane
      #       jump 'a'
      #       mode_keys do
      #         group 'Clips'
      #         on :up, :move, 0, -1, help: 'move the cursor', label: 'arrows'
      #         on :enter, :launch, help: 'launch the clip at the cursor'
      #       end
      #       def key_move(state, dx, dy) = ...
      #     end
      #
      # Keys that make one line per gesture (a held arrow turning a knob:
      # UI::TurnGesture) return nothing until the gesture ends; the screen
      # asks such panes `key_wait(state)` (seconds until a line is due, or
      # nil) and `key_tick(state)` (what is due, or nil), and tells them
      # `lines_ran(state)` after running what a key or tick returned.  A
      # key_ method may return several results as an Array: Runs, a
      # Preview (a live unjournaled knob move), a Commit (a gesture's
      # line, from the Session), an Ask (a value to type on a prompt
      # line, handed to key_<answer>), a Paste (a line onto the REPL's
      # prompt, not run), a Focus (into another pane).
      module PaneKeys
        def self.included(base)
          base.extend(ClassMethods)
        end

        # A pane's kind from its class (Panes::Meters => :meters), nil for
        # nil or an anonymous class.
        def self.kind_of(pane)
          return nil if pane.nil?
          c = pane.class
          return KINDS[c] if KINDS.key?(c)
          KINDS[c] = c.name&.split('::')&.last&.downcase&.to_sym
        end

        # .kind_of by class (asked every frame by the painter's pane rates;
        # sd-ux-fixes-1).
        KINDS = {}.compare_by_identity

        module ClassMethods
          # Declares (or extends) the kind's keymap.
          def keys(&block)
            @keymap ||= MB::Term::Input::Keymap.new((name || 'pane').split('::').last.downcase.to_sym)
            @keymap.instance_exec(&block) if block
            @keymap
          end

          # The kind's keymap, or nil (inherited from superclasses).
          def keymap
            @keymap || (superclass.respond_to?(:keymap) ? superclass.keymap : nil)
          end

          # Declares (or extends) the kind's mode keymap: the keys of its
          # own mode (NAV Enter enters it, Esc leaves).
          def mode_keys(&block)
            @mode_keymap ||= MB::Term::Input::Keymap.new(:"#{(name || 'pane').split('::').last.downcase}_mode")
            @mode_keymap.instance_exec(&block) if block
            @mode_keymap
          end

          # The kind's mode keymap, or nil (inherited).
          def mode_keymap
            @mode_keymap || (superclass.respond_to?(:mode_keymap) ? superclass.mode_keymap : nil)
          end

          # The kind's NAV jump letter (with an argument: declares it).
          def jump(letter = nil)
            if letter
              raise ArgumentError, "A jump key is one character (got #{letter.inspect})" unless letter.is_a?(String) && letter.length == 1
              @jump = letter
            end
            @jump || (superclass.respond_to?(:jump) ? superclass.jump : nil)
          end
        end

        # A console line a pane key asks the screen to run (UI.run_line:
        # journaled, undoable, a take line), printing the Ruby it ran in
        # the REPL pane; +note+ is what the status line says.  Pane keys
        # that change the performance return one of these instead of
        # calling the Session (command_bus_spec).
        Run = Data.define(:code, :note) do
          def self.[](code, note = nil) = new(code: code.freeze, note: note&.freeze)
        end

        # A knob turn's console line (a `turn` a key set, a typed value,
        # a held key's gesture): run like a Run (UI.run_line: journaled,
        # undoable, a take line), but not printed in the REPL pane
        # (inspector-headers-1, the maintainer's 2026-11-02 "Too much noise
        # in the repl; knob turn code should have one line in a dedicated
        # panel if shown"): the screen keeps the latest as the pane's one
        # turn line (`state[:turn_line]`, KnobTurns#turn_line_canvas), an
        # error printing as a Run's does.  +note+ is what the status line
        # says.
        Turn = Data.define(:code, :note) do
          def self.[](code, note = nil) = new(code: code.freeze, note: note&.freeze)
        end

        # A live, unjournaled knob move a pane key asks for (a step of a
        # held-key gesture; UI::TurnGesture): the screen calls
        # Session#preview_turn.  A Commit follows.  +note+, if given, is
        # what the status line says (the tracks pane's "drums at -3 dB"),
        # else the knob and its value.
        Preview = Data.define(:knob, :value, :note) do
          def self.[](knob, value, note = nil) = new(knob: knob, value: value, note: note&.freeze)
        end

        # The end of a held-key gesture on +knob+: the screen runs
        # Session#gesture_line as the gesture's one console line (journaled
        # at its first step, one undo step, one take line); +note+ for the
        # status line.
        Commit = Data.define(:knob, :note) do
          def self.[](knob, note = nil) = new(knob: knob, note: note&.freeze)
        end

        # A value a pane key asks the user to type (the inspector's Enter):
        # the screen opens a prompt line (+prompt+, starting with +text+),
        # and on Enter calls the pane's key_<+answer+>(state, typed text),
        # whose result it handles like a key's.  Esc cancels.  With
        # +changed+ (find-as-you-type: the library picker's /), each edit of
        # the line also calls key_<+changed+>(state, text so far), and Esc
        # calls it with the starting text again.  With +select+ the starting
        # text is shown selected and the first printable key replaces it
        # (the inspector's value prompt: typing 3000.hz over the old value,
        # not after it; sd-ux-fixes-1); without, typing edits it (a bind
        # line, a find to narrow).
        Ask = Data.define(:prompt, :text, :answer, :changed, :select) do
          def self.[](prompt, text, answer, changed: nil, select: false) = new(prompt: prompt.freeze, text: text.to_s.freeze, answer: answer, changed: changed, select: select)
        end

        # Console Ruby a pane key puts on the REPL's line, not run (the
        # library picker's e: a line to edit first, like step entry's
        # Enter): the screen goes to the REPL with +code+ typed in; +note+
        # for the status line.
        Paste = Data.define(:code, :note) do
          def self.[](code, note = nil) = new(code: code.freeze, note: note&.freeze)
        end

        # Another pane a pane key goes into (tracks-enter-1: the tracks
        # pane's Enter takes its track into the knobs pane, and the knobs
        # pane's Esc comes back): the screen focuses +pane+ (a pane name or
        # kind on screen; with +rows+, a pane of that kind put in for a
        # while where none is, as a jump letter's temporary pane), goes
        # into its mode, then calls its key_<+action+>(state, *+args+, the
        # asking pane's name) when +action+ is given, handling what that
        # returns like a key's result.  +leave+ takes the asking pane away
        # if a jump or a Focus put it in for a while.  UI state only: no
        # line runs, nothing is journaled.  +note+ for the status line.
        Focus = Data.define(:pane, :action, :args, :rows, :leave, :note) do
          def self.[](pane, action = nil, *args, rows: nil, leave: false, note: nil)
            new(pane: pane, action: action, args: args.freeze, rows: rows, leave: leave, note: note&.freeze)
          end
        end

        # The pane's keymap (its kind's), or nil.
        def keymap = self.class.keymap

        # The pane's mode keymap (its kind's), or nil: with one, NAV Enter
        # enters the pane's own mode.
        def mode_keymap = self.class.mode_keymap

        # The pane's NAV jump letter, or nil.
        def jump = self.class.jump

        # What `e` says in each pane's keys (EDIT_HELP; one wording).
        EDIT_HELP = "this row's line onto the console to edit (not run)"

        # e (ui-phase1-1, the 2026-11-21 plan's "every key is a console line
        # he can read and learn from"): the console line the picked row's
        # main action would run goes onto the REPL's prompt, unrun (a
        # Paste: the screen goes to the REPL with it typed in), so it can
        # be edited and run by hand.  One implementation: a pane says which
        # line is its row's with `edit_line(state)`, returning a Run or a
        # Turn (its code goes on the prompt) or a String (why there is
        # none: flashed).  Bound as `on 'e', :edit_line, help:
        # PaneKeys::EDIT_HELP` in the panes whose modes have e free.
        def key_edit_line(state)
          r = respond_to?(:edit_line) ? edit_line(state) : nil
          return r if r.is_a?(String)
          return "#{name}: no line to edit here" unless r.respond_to?(:code)
          Paste[r.code, 'on the console line: edit it, Enter runs it']
        end

        # Runs the key_<action> method for a keymap binding.  Returns its
        # result (a String flashes), or a note if the pane has none.
        def key_action(action, state, *args)
          m = :"key_#{action}"
          return "#{name}: no #{action} here" unless respond_to?(m)
          public_send(m, state, *args)
        end
      end

      Pane.include(PaneKeys)

      # Every pane is enterable (maintainer, 2026-10-18: "Every panel should
      # be enterable; it's weird to be stuck in NAV on some panels but not
      # others"): NAV Enter goes into any pane, Esc or Ctrl-] comes back.
      # Panes without keys of their own get these: copy the pane's text,
      # and scroll where the pane has more than it shows (#key_scroll).
      Pane.mode_keys do
        group 'Pane'
        on 'y', :copy_text, help: "copy the pane's text (OSC 52)"
        on [:up, :down, :page_up, :page_down], :scroll, 0, help: 'scroll (panes that have more than they show)', label: 'arrows PgUp PgDn'
      end

      class Pane
        # Scrolls the pane (the view mode's arrows); panes with more than
        # they show override it.
        def key_scroll(_state, *_)
          "#{name}: shows all it has (nothing to scroll)"
        end
      end
    end
  end
end
