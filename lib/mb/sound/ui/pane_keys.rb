require_relative 'input/events'

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
      # NAV's and the Ctrl-W window keys.
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
      module PaneKeys
        def self.included(base)
          base.extend(ClassMethods)
        end

        # A pane's kind from its class (Panes::Meters => :meters), nil for
        # nil or an anonymous class.
        def self.kind_of(pane)
          pane&.class&.name&.split('::')&.last&.downcase&.to_sym
        end

        module ClassMethods
          # Declares (or extends) the kind's keymap.
          def keys(&block)
            @keymap ||= Input::Keymap.new((name || 'pane').split('::').last.downcase.to_sym)
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
            @mode_keymap ||= Input::Keymap.new(:"#{(name || 'pane').split('::').last.downcase}_mode")
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

        # The pane's keymap (its kind's), or nil.
        def keymap = self.class.keymap

        # The pane's mode keymap (its kind's), or nil: with one, NAV Enter
        # enters the pane's own mode.
        def mode_keymap = self.class.mode_keymap

        # The pane's NAV jump letter, or nil.
        def jump = self.class.jump

        # Runs the key_<action> method for a keymap binding.  Returns its
        # result (a String flashes), or a note if the pane has none.
        def key_action(action, state, *args)
          m = :"key_#{action}"
          return "#{name}: no #{action} here" unless respond_to?(m)
          public_send(m, state, *args)
        end
      end

      Pane.include(PaneKeys)
    end
  end
end
