module MB
  module Sound
    module UI
      # Signal handlers chained by screens (SIGWINCH): a screen wraps the
      # handler before it and, leaving, puts that back only if the handler
      # in place is still its own.  A handler installed later (Reline's,
      # for the line it reads now) stays, since restoring blindly would
      # drop it, and Reline would lose its resizes and the line being
      # edited with them (ux-1 round 3, Ctrl-] from the band).
      module Signals
        module_function

        # Traps +sig+ with +handler+ (a Proc), returning the handler it
        # replaces.
        def chain(sig, handler)
          Signal.trap(sig, &handler)
        end

        # Undoes #chain: +old+ goes back if +ours+ is still in place;
        # otherwise the handler in place stays (and whatever wrapped ours
        # keeps calling it).  Returns true if restored.
        def unchain(sig, ours, old)
          current = Signal.trap(sig, old || 'DEFAULT')
          return true if current.equal?(ours)
          Signal.trap(sig, current || 'DEFAULT')
          false
        rescue ArgumentError
          false
        end
      end
    end
  end
end
