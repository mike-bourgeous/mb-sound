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
      module PaneKeys
        def self.included(base)
          base.extend(ClassMethods)
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

          # Declares (or extends) the keys of the pane's own mode (NAV
          # Enter on the focused pane; ux-r4-nav's Router :pane state):
          # cursor keys, Enter, letters.  Esc is reserved (back to NAV).
          # (The same declaration as ux-r4-nav's; at merge, nav's wins.)
          def mode_keys(&block)
            @mode_keymap ||= Input::Keymap.new(:"#{(name || 'pane').split('::').last.downcase}_mode")
            @mode_keymap.instance_exec(&block) if block
            @mode_keymap
          end

          # The kind's mode keymap, or nil.
          def mode_keymap
            @mode_keymap || (superclass.respond_to?(:mode_keymap) ? superclass.mode_keymap : nil)
          end

          # The NAV letter that jumps to this pane kind (with no argument:
          # the letter, or nil).
          def jump(letter = nil)
            return @jump || (superclass.respond_to?(:jump) ? superclass.jump : nil) if letter.nil?
            @jump = letter
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

        # The pane's mode keymap (its kind's), or nil.
        def mode_keymap = self.class.mode_keymap

        # The pane's keymap (its kind's), or nil.
        def keymap = self.class.keymap

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
