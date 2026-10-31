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

      # A name with structure (s-names, omnibus17): Session names join
      # parts with a slash, the first part being the owner (a track,
      # player, or rack), the last the leaf:
      #
      # | name                | what it is                                  |
      # |---------------------|---------------------------------------------|
      # | :"lead/live"        | track :lead's monitor player (#monitor?)    |
      # | :"lead/cue"         | track :lead's cue player (#cue?)            |
      # | :"bass/level"       | player :bass's level knob (#level?)         |
      # | :"kick/key"         | player :kick's key level knob (#key?)       |
      # | :"bass/cutoff"      | a track knob (a patch param, a live literal)|
      # | :"dub/space"        | rack :dub's knob :space                     |
      # | :"bass/dub/space"   | that knob's instance in player :bass        |
      #
      # Name[x] parses a Symbol (or passes an Integer player name through:
      # its owner and leaf are itself) into this frozen value, cached per
      # name, so render paths can ask without allocating.  Every place that
      # builds or takes apart such a name goes through here (a guard spec,
      # spec/lib/mb/sound/session/name_spec.rb, fails on hand parsing).
      class Name
        # The leaf of a track's monitor player (Arrangement::Recording).
        MONITOR = 'live'

        # The leaf of a track's cue player (Session::Cue).
        CUE = 'cue'

        # The leaf of a player's level knob (Session::Faders).
        LEVEL = 'level'

        # The leaf of a player's key level knob (Session::Faders): how hard
        # it drives the sidechain readers that read it.
        KEY = 'key'

        # (parsed names; cleared when it grows past CACHE_LIMIT)
        @cache = {}
        CACHE_LIMIT = 4096

        class << self
          # The parsed Name of +name+ (a Symbol or Integer; Strings are
          # read as Symbols).
          def [](name)
            return name if name.is_a?(Name)
            hit = @cache[name]
            return hit if hit
            @cache.clear if @cache.size >= CACHE_LIMIT
            @cache[name] = new(name)
          end

          # Joins +parts+ into a name: join(:bass, :cutoff) is
          # :"bass/cutoff" (an Integer player name joins as its digits).
          def join(*parts)
            parts.join('/').to_sym
          end

          # The track whose monitor player +name+ is (:lead for
          # :"lead/live"), or nil (also for anything not a Symbol).
          def monitored(name)
            name.is_a?(Symbol) ? self[name].monitored : nil
          end

          # The name whose cue player +name+ is (:lead for :"lead/cue"), or
          # nil (also for anything not a Symbol).
          def cued(name)
            name.is_a?(Symbol) ? self[name].cued : nil
          end

          # Track +track+'s monitor player name (:"lead/live").
          def monitor(track)
            join(track, MONITOR)
          end

          # Player +name+'s cue player name (:"lead/cue").
          def cue(name)
            join(name, CUE)
          end

          # Player +name+'s level knob name (:"bass/level").
          def level(name)
            join(name, LEVEL)
          end

          # Player +name+'s key level knob name (:"kick/key").
          def key(name)
            join(name, KEY)
          end

          # Leaves that mean something of their own (#monitor?, #cue?,
          # #level?, #key?), which a track param's knob can't take.
          RESERVED_LEAVES = [MONITOR, CUE, LEVEL, KEY].freeze

          # Track +track+'s knob for patch param +param+ (:"bass/cutoff"):
          # the one knob name rule for preset params, bound literals, and
          # library entry params (knobs-1, D5: knobs are named in full, so a
          # param written with a short alias of the Param names table, like
          # a document's `param :reso`, is :"bass/resonance"; #full_name).
          # A param named like a reserved leaf gets a prefix:
          # :"bass/patch_level", since :"bass/level" is the track's level.
          def param(track, param)
            leaf = MB::Sound::Param.full_name(param.to_sym).to_s
            join(track, RESERVED_LEAVES.include?(leaf) ? "patch_#{leaf}" : leaf)
          end

          # The full knob name a short one stands for (:"bass/resonance"
          # for :"bass/reso": the leaf through Param::NAME_ALIASES), or nil
          # when +name+'s leaf is no alias (or +name+ is plain or not a
          # Symbol).  Session::Knobs resolves typed short names through it.
          def full_name(name)
            return nil unless name.is_a?(Symbol)
            nm = self[name]
            return nil if nm.plain?
            full = MB::Sound::Param::NAME_ALIASES[nm.leaf] or return nil
            join(nm.base, full)
          end

          # The hidden knob name of the send from player +name+ to bus
          # +bus+ (:"keys>verb"; Session::Buses).
          def send_knob(name, bus)
            :"#{name}>#{bus}"
          end
        end

        # The name as given (a Symbol, or an Integer player name).
        attr_reader :symbol

        # The parts (frozen Strings; one for a plain name).
        attr_reader :parts

        def initialize(name)
          name = name.to_sym if name.is_a?(String)
          raise ArgumentError, "Names are Symbols or Integers (got #{name.inspect})" unless name.is_a?(Symbol) || name.is_a?(Integer)
          @symbol = name
          @parts = (name.is_a?(Symbol) ? name.name.split('/', -1) : [name.to_s]).map(&:freeze).freeze
          @parts = [name.to_s.freeze].freeze if @parts.empty? || @parts.any?(&:empty?)
          @owner = @parts.length == 1 ? name : @parts.first.to_sym
          @leaf = @parts.length == 1 ? name : @parts.last.to_sym
          @base = @parts.length == 1 ? nil : @parts[0...-1].join('/').to_sym
          freeze
        end

        # The first part as a name (:bass for :"bass/dub/space"; the name
        # itself for a plain name).
        attr_reader :owner

        # The last part (:space for :"bass/dub/space"; the name itself for
        # a plain name).
        attr_reader :leaf

        # Everything before the leaf (:"bass/dub" for :"bass/dub/space"),
        # or nil for a plain name.
        attr_reader :base

        # True for a plain name (one part).
        def plain?
          @parts.length == 1
        end

        # True for a track's monitor player name (:"lead/live").
        def monitor?
          !plain? && @parts.last == MONITOR
        end

        # True for a cue player name (:"lead/cue").
        def cue?
          !plain? && @parts.last == CUE
        end

        # True for a player's level knob name (:"bass/level").
        def level?
          @parts.length == 2 && @parts.last == LEVEL
        end

        # True for a player's key level knob name (:"kick/key").
        def key?
          @parts.length == 2 && @parts.last == KEY
        end

        # The track whose monitor player this is (:lead for :"lead/live"),
        # or nil.
        def monitored
          monitor? ? @base : nil
        end

        # The name whose cue player this is (:lead for :"lead/cue"), or nil.
        def cued
          cue? ? @base : nil
        end

        # The player name whose strip (mute, solo, level, routes) this
        # player follows: a monitor's or cue player's track, else itself.
        def strip_owner
          monitored || cued || @symbol
        end

        def to_sym
          @symbol
        end

        def to_s
          @symbol.to_s
        end

        def inspect
          "#<Session::Name #{@symbol.inspect}>"
        end

        def ==(other)
          other.is_a?(Name) && other.symbol == @symbol
        end
        alias eql? ==

        def hash
          @symbol.hash
        end
      end
    end
  end
end
