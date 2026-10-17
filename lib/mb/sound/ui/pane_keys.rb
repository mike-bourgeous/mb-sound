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
        end

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
