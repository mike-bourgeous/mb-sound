require 'weakref'

module MB
  module Sound
    class Session
      # The Session's named racks (MB::Sound::Rack; console
      # MB::Sound::RackMethods): names share the Session namespace
      # (Session::Names, kind :rack; collisions go through
      # MB::Sound.live_error), and each application of a named rack is
      # remembered (weakly) so #info can say where it plays.
      #
      # Defining a named rack again replaces it for later applications;
      # instances already built keep playing as they were (live swaps of
      # racks and slots are a later phase).
      class Racks
        # A named rack, its applications, and the output type seen last.
        Entry = Struct.new(:rack, :uses, :out, :instances)

        def initialize(session)
          @session = session
          @entries = {}
          @mutex = Mutex.new
        end

        # Registers named +rack+, claiming its name.  Returns the rack, or
        # nil if the name is taken by something else (live: after a
        # warning; scripts and specs raise).
        def define(rack)
          return nil unless @session.names.claim(rack.name, :rack)
          @mutex.synchronize { @entries[rack.name] = Entry.new(rack, 0, nil, []) }
          rack
        end

        # The rack named +name+, or nil.
        def [](name)
          @mutex.synchronize { @entries[name]&.rack }
        end

        # The rack named +name+; raises KeyError (with did_you_mean) if
        # there is none.
        def fetch(name)
          self[name] || raise(KeyError, "No rack named #{name.inspect}#{MB::Sound::Rack.suggest(name, names)}#{" (racks: #{names.join(', ')})" unless names.empty?}")
        end

        # The rack names.
        def names
          @mutex.synchronize { @entries.keys }
        end

        # Notes an application of +rack+ that returned +result+.
        def used(rack, result)
          @mutex.synchronize {
            e = @entries[rack.name]
            return unless e && e.rack.block.equal?(rack.block)
            e.uses += 1
            e.out = MB::Sound::Rack.output_type(result)
            e.instances.reject! { |w| !w.weakref_alive? }
            result = result.stream if result.is_a?(MB::Sound::Notes)
            e.instances << WeakRef.new(result) if result && !result.frozen?
          }
        end

        # The racks: name => "effect audio(sig) + audio(side) -> audio,
        # 2 uses (in :bass)".
        def info
          entries = @mutex.synchronize { @entries.values.map(&:dup) }
          entries.to_h { |e|
            r = e.rack
            out = r.out || e.out
            used = e.uses.zero? ? 'not used yet' : "#{e.uses} use#{'s' if e.uses != 1}"
            where = players_using(e)
            used += " (in #{where.map(&:inspect).join(', ')})" unless where.empty?
            [r.name, "#{r.kind(out)} #{r.signature(out)}, #{used}"]
          }
        end

        private

        # Names of the current players whose graphs hold an instance of
        # entry +e+.
        def players_using(e)
          insts = e.instances.filter_map { |w| w.__getobj__ if w.weakref_alive? }
          return [] if insts.empty?

          players = @session.instance_variable_get(:@players)
          list = @session.instance_variable_get(:@mutex).synchronize { players.values.select(&:current?) }
          list.select { |p|
            p.input.nodes.any? { |n|
              nodes = n.respond_to?(:graph) ? n.graph : [n]
              insts.any? { |i| nodes.any? { |x| x.equal?(i) } }
            }
          }.map(&:name).uniq
        rescue StandardError
          []
        end
      end
    end
  end
end
