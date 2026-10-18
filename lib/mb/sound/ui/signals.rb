module MB
  module Sound
    module UI
      # Signal handlers chained by screens (SIGWINCH): a screen wraps the
      # handler before it and, leaving, puts that back only if the handler
      # in place is still its own.  A handler installed later (Reline's,
      # for the line it reads now) stays, since restoring blindly would
      # drop it, and Reline would lose its resizes and the line being
      # edited with them (ux-1 round 3, Ctrl-] from the band).
      #
      # Handlers that call the one they replaced can loop: Reline's WINCH
      # handler calls whatever handler Reline replaced *most recently*
      # (it reads @old_winch_handler when it runs, not when it was made), so
      # once a screen has wrapped Reline's handler R1 and the next prompt
      # runs set_winch_handler again (saving the screen's wrapper W as its
      # old handler), W calls R1, R1 calls W, ... until SystemStackError
      # (seen as tiles_spec failures on the Mac, 2026-10-18, whenever a
      # WINCH came between).  #handler makes wrappers that ignore a call
      # made while they run, which ends any such cycle after one round.
      module Signals
        module_function

        # Wrappers made by #handler.
        OURS = ObjectSpace::WeakMap.new

        # A signal handler Proc running +body+ (|sig|) that ignores calls
        # made while it runs (a chain that comes back to it).
        def handler(&body)
          busy = false
          h = proc do |sig|
            unless busy
              busy = true
              begin
                body.call(sig)
              ensure
                busy = false
              end
            end
          end
          OURS[h] = true
          h
        end

        # True if +h+ was made by #handler.
        def ours?(h) = !h.nil? && OURS.key?(h)

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
