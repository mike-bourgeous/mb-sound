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
        # A named rack, its applications, the output type seen last, and
        # the macros' Specs seen last ({ name => Knob::Spec }).
        Entry = Struct.new(:rack, :uses, :out, :instances, :macros)

        def initialize(session)
          @session = session
          @entries = {}
          @mutex = Mutex.new
          # Macro instances by rack name (nil for anonymous racks): the
          # keys ([player, ordinal]) in the order they appeared, and each
          # key's Session knobs by macro name
          @macro_keys = {}
          @macro_knobs = {}
        end

        # Registers named +rack+, claiming its name.  Returns the rack, or
        # nil if the name is taken by something else (live: after a
        # warning; scripts and specs raise).
        def define(rack)
          return nil unless @session.names.claim(rack.name, :rack)
          @mutex.synchronize { @entries[rack.name] = Entry.new(rack, 0, nil, [], {}) }
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

        # Notes an application of +rack+ that returned +result+ (+app+ is
        # its Rack::Application, holding the macros it made).
        def used(rack, result, app = nil)
          @mutex.synchronize {
            e = @entries[rack.name]
            return unless e && e.rack.block.equal?(rack.block)
            e.uses += 1
            e.out = MB::Sound::Rack.output_type(result)
            e.macros = app.macros.transform_values(&:spec) if app && !app.macros.empty?
            e.instances.reject! { |w| !w.weakref_alive? }
            result = result.stream if result.is_a?(MB::Sound::Notes)
            e.instances << WeakRef.new(result) if result && !result.frozen?
          }
        end

        # The racks: name => "effect audio(sig) + audio(side) -> audio,
        # macros space 0.3 (0..1), 2 uses (in :bass)".
        def info
          entries = @mutex.synchronize { @entries.values.map(&:dup) }
          entries.to_h { |e|
            r = e.rack
            out = r.out || e.out
            used = e.uses.zero? ? 'not used yet' : "#{e.uses} use#{'s' if e.uses != 1}"
            where = players_using(e)
            used += " (in #{where.map(&:inspect).join(', ')})" unless where.empty?
            macros = e.macros.empty? ? '' : "macros #{e.macros.map { |n, spec| Racks.macro_text(n, spec) }.join(', ')}, "
            [r.name, "#{r.kind(out)} #{r.signature(out)}, #{macros}#{used}"]
          }
        end

        # "space 0.3 (0..1)", "cut 800 Hz (100..8000 exp)" for macro +name+
        # with Knob::Spec +spec+.
        def self.macro_text(name, spec)
          k = GraphNode::Knob
          "#{name} #{k.number(spec.default)}#{spec.unit ? " #{spec.unit}" : ''} (#{k.number(spec.range.begin)}..#{k.number(spec.range.end)}#{spec.curve == :exp ? ' exp' : ''})"
        end

        # The macros of named rack +name+ seen in the latest application
        # ({ macro => Knob::Spec }), or an empty Hash.
        def macro_specs(name)
          @mutex.synchronize { @entries[name]&.macros || {} }
        end

        # The Session knobs (names) of the macros of rack +name+ (nil for
        # anonymous racks), every instance's.
        def macro_knob_names(name)
          @mutex.synchronize {
            (@macro_keys[name] || []).flat_map { |key| (@macro_knobs[[name, key]] || {}).values.map(&:name) }
          }
        end

        # The Session knobs of the macros of rack +name+ by instance key
        # ({ [player, ordinal] => { macro => Knob } }).
        def macro_instances(name)
          @mutex.synchronize {
            (@macro_keys[name] || []).to_h { |key| [key, (@macro_knobs[[name, key]] || {}).dup] }
          }
        end

        # Names for macro knobs joining the Session (see
        # Session::Knobs#adopt_knobs): +knobs+ are standalone macro knobs
        # (not shared) of a graph played by +player+ (a player name, or
        # nil).  Instances are told apart by their Rack::Application, in
        # the order they appear in the graph, keyed [player, ordinal].
        # Returns [{ knob => [name, rack name, key] }, renames], where
        # renames are [session knob, new name] pairs: a named rack's
        # macros are :"dub/space" while one key uses them, and per instance
        # (:"bass/dub/space") from the second key on, which renames the
        # first key's knobs.
        def macro_names(knobs, player)
          renames = []
          out = {}.compare_by_identity
          @mutex.synchronize {
            ordinals = Hash.new(0)
            apps = {}.compare_by_identity
            key_of = {}.compare_by_identity
            knobs.each do |k|
              info = k.macro
              rack = info.rack_name
              key_of[k] = (apps[info.application] ||= begin
                ord = ordinals[rack]
                ordinals[rack] += 1
                [player, ord]
              end)
              keys = (@macro_keys[rack] ||= [])
              next if keys.include?(key_of[k])
              keys << key_of[k]
              if rack && keys.length == 2
                (@macro_knobs[[rack, keys[0]]] || {}).each { |m, knob| renames << [knob, instance_name(rack, keys[0], keys, m)] }
              end
            end
            knobs.each do |k|
              info = k.macro
              rack = info.rack_name
              key = key_of[k]
              keys = @macro_keys[rack]
              name = if rack.nil?
                       anonymous_name(key, info.macro)
                     elsif keys.length == 1
                       :"#{rack}/#{info.macro}"
                     else
                       instance_name(rack, key, keys, info.macro)
                     end
              out[k] = [name, rack, key]
            end
          }
          [out, renames]
        end

        # Remembers Session knob +knob+ as macro +macro+ of instance +key+
        # of rack +rack+ (see #macro_names).
        def macro_joined(rack, key, macro, knob)
          @mutex.synchronize { (@macro_knobs[[rack, key]] ||= {})[macro] = knob }
        end

        private

        # A per-instance macro name: :"bass/dub/space" (the second instance
        # in one player :"bass/dub.2/space"; without a player, by order:
        # :"dub.1/space").
        def instance_name(rack, key, keys, macro)
          player, ord = key
          return :"#{rack}.#{keys.index(key) + 1}/#{macro}" if player.nil?
          :"#{player}/#{rack}#{ord > 0 ? ".#{ord + 1}" : ''}/#{macro}"
        end

        # An anonymous rack's macro name: the player's (:"bass/space",
        # :"bass/rack.2/space" for a second instance), else :"rack/space".
        def anonymous_name(key, macro)
          player, ord = key
          parts = [player || 'rack']
          parts << "rack.#{ord + 1}" if ord > 0
          :"#{parts.join('/')}/#{macro}"
        end

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
