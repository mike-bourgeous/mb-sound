module MB
  module Sound
    class Session
      # The Session's top-level names (contract K2 in
      # design/notes/arrangement.md): tracks, mute groups, and (later) knobs
      # share one namespace, so a scene can say `bass: bass_a, cut: 800`
      # without saying which is which.  +master+ and +cue+ are reserved.
      # Names are Symbols in Ruby; #path joins names into the
      # `player/node/lane` paths used for display and files.
      class Names
        # Names no track, group, or knob may take.
        RESERVED = [:master, :cue].freeze

        def initialize
          @kinds = {}
          @mutex = Mutex.new
        end

        # Claims +name+ for a +kind+ (:track, :group, :knob, ...).  Claiming
        # a name again for the same kind is fine.  A name that is already
        # another kind, or reserved, goes through MB::Sound.live_error
        # (raises in scripts and specs; warns and returns nil live).
        # Returns true if the name is claimed.
        def claim(name, kind)
          raise ArgumentError, "Names must be Symbols (got #{name.inspect})" unless name.is_a?(Symbol)

          error = @mutex.synchronize {
            if RESERVED.include?(name)
              "#{name.inspect} is reserved"
            elsif @kinds[name] && @kinds[name] != kind
              "#{name.inspect} is already a #{@kinds[name]}; pick another name for the #{kind}"
            else
              @kinds[name] = kind
              nil
            end
          }

          return true if error.nil?
          MB::Sound.live_error(ArgumentError.new(error))
          false
        end

        # The kind +name+ was claimed for, or nil.
        def kind(name)
          @mutex.synchronize { @kinds[name] }
        end

        # Frees +name+.
        def release(name)
          @mutex.synchronize { @kinds.delete(name) }
        end

        # A Hash from name to kind.
        def to_h
          @mutex.synchronize { @kinds.dup }
        end

        # Joins name parts into a display path, e.g. `path(:bass, :cut, 3)`
        # is "bass/cut/3".  Paths are for display and files; Ruby code uses
        # Symbols and Arrays.
        def self.path(*parts)
          parts.join('/')
        end
      end
    end
  end
end
