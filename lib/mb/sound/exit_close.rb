module MB
  module Sound
    # Closes open Sessions and outputs at exit (so their threads stop and
    # their outputs drain before Ruby tears down) without keeping them
    # alive: one at_exit hook for the process, and a weak registry of what
    # it closes.
    #
    # Each realtime Session used to register its own `at_exit { close }`,
    # and that block held the Session, so every Session that ever started
    # its thread, with every graph it had played, stayed reachable until
    # the process exited, closed or not (a full spec run kept a dozen
    # Synths alive this way; see design/notes/audio_io.md).  A block
    # registered with at_exit is a GC root, so library code registers
    # objects here instead (spec/lib/mb/sound/exit_close_spec.rb checks
    # lib/ for other at_exit blocks).
    #
    # Objects are closed latest first, like separate at_exit blocks were
    # (a Session before the output it opened).
    module ExitClose
      @mutex = Mutex.new
      @registry = ObjectSpace::WeakMap.new
      @serial = 0
      @hook = false

      class << self
        # Closes +object+ (calling its #close) at exit unless it was
        # collected or #unregister-ed first.  Holds +object+ weakly.
        # Returns +object+.
        def register(object)
          @mutex.synchronize do
            unless @hook
              @hook = true
              at_exit { close_all }
            end
            @registry[object] = (@serial += 1) unless @registry.key?(object)
          end
          object
        end

        # Forgets +object+ (call from #close).  Returns +object+.
        def unregister(object)
          @mutex.synchronize { @registry.delete(object) }
          object
        end

        # Returns true if +object+ will be closed at exit.
        def registered?(object)
          @mutex.synchronize { @registry.key?(object) }
        end

        # The objects still registered, latest first.
        def objects
          list = []
          @mutex.synchronize { @registry.each { |o, n| list << [o, n] } }
          list.sort_by { |_, n| -n }.map(&:first)
        end

        # Closes every registered object, latest first, ignoring errors
        # (the at_exit hook).
        def close_all
          objects.each do |o|
            o.close
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
