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
        # the knobs' Specs seen last ({ name => Knob::Spec }).
        Entry = Struct.new(:rack, :uses, :out, :instances, :knobs)

        def initialize(session)
          @session = session
          @entries = {}
          @mutex = Mutex.new
          # Knob instances by rack name (nil for anonymous racks): the
          # keys ([player, ordinal]) in the order they appeared, and each
          # key's Session knobs by knob name
          @knob_keys = {}
          @instance_knobs = {}
          # Named racks whose knobs are per instance (see #instance_knob_names),
          # and the group names standing for every instance's knob
          # (:"dub/space" => [:dub, :space])
          @per_instance = {}
          @knob_groups = {}
          # Instance keys given to rack Applications (see
          # #instance_member_names), and slots by rack name and key
          # ({ [rack, key] => { short => Slot } }), slot group names
          # (:"dub/color" => [:dub, :color]), and slots outside racks by
          # Session name
          @app_keys = ObjectSpace::WeakMap.new
          @instance_slots = {}
          @slot_groups = {}
          @plain_slots = {}
        end

        # Registers named +rack+, claiming its name.  Returns the rack, or
        # nil if the name is taken by something else (live: after a
        # warning; scripts and specs raise).
        def define(rack)
          return nil unless @session.names.claim(rack.name, :rack)
          @mutex.synchronize { @entries[rack.name] = Entry.new(rack, 0, nil, [], {}) }
          rack
        end

        # Replaces the definition of rack +name+ with +rack+ as one undo
        # step labeled +label+ (instances already built keep playing as they
        # were; later applications use +rack+).  Returns +rack+.
        def replace(name, rack, label:)
          before = self[name]
          Session.with_context(session: @session) {
            @session.command(label) {
              define(rack)
              @session.note_undo_extra(self, { name => before }, { name => rack })
            }
          }
          rack
        end

        # Puts rack definitions back (undo and redo of #replace): +state+
        # maps names to Racks (nil: no rack).
        def restore_undo_state(state)
          state.each do |name, rack|
            @mutex.synchronize {
              if rack.nil?
                @entries.delete(name)
              elsif (e = @entries[name])
                e.rack = rack
              else
                @entries[name] = Entry.new(rack, 0, nil, [], {})
              end
            }
          end
        end

        # The first free name +base+_2, +base+_3, ... (free of racks and of
        # every other Session name).
        def free_name(base)
          (2..).each do |i|
            n = :"#{base}_#{i}"
            return n if self[n].nil? && @session.names.kind(n).nil?
          end
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

        # The output type the latest application of rack +name+ returned,
        # or nil.
        def output_of(name)
          @mutex.synchronize { @entries[name]&.out }
        end

        # The rack names.
        def names
          @mutex.synchronize { @entries.keys }
        end

        # Notes an application of +rack+ that returned +result+ (+app+ is
        # its Rack::Application, holding the knobs it made).
        def used(rack, result, app = nil)
          @mutex.synchronize {
            e = @entries[rack.name]
            return unless e && e.rack.block.equal?(rack.block)
            e.uses += 1
            e.out = MB::Sound::Rack.output_type(result)
            e.knobs = app.knobs.transform_values(&:spec) if app && !app.knobs.empty?
            e.instances.reject! { |w| !w.weakref_alive? }
            result = result.stream if result.is_a?(MB::Sound::Notes)
            e.instances << WeakRef.new(result) if result && !result.frozen?
          }
        end

        # The racks: name => "effect audio(sig) + audio(side) -> audio,
        # knobs space 0.3 (0..1), 2 uses (in :bass)".
        def info
          entries = @mutex.synchronize { @entries.values.map(&:dup) }
          entries.to_h { |e|
            r = e.rack
            out = r.out || e.out
            used = uses_text(e)
            list = e.knobs.empty? ? '' : "knobs #{e.knobs.map { |n, spec| Racks.spec_text(n, spec) }.join(', ')}, "
            [r.name, "#{r.kind(out)} #{r.signature(out)}, #{list}#{used}"]
          }
        end

        # "2 uses (in :bass, :keys)" for rack +name+ (nil if there is no
        # such rack).
        def uses(name)
          e = @mutex.synchronize { @entries[name]&.dup }
          e && uses_text(e)
        end

        # Frozen RackInfo values for the named racks, for rack panes and
        # other threads (no render lock; the rack's latency comes from a
        # stand-in build the first time, then is remembered): { name =>
        # [RackInfo, ...] }, one per instance with knobs in the Session
        # (path :"bass/dub", or :dub while one instance uses them), else
        # one for the rack (path nil).
        def rack_info
          entries = @mutex.synchronize { @entries.values.map(&:dup) }
          entries.to_h { |e|
            r = e.rack
            instances = knob_instances(r.name)
            specs = e.knobs.empty? ? (r.knob_specs rescue {}) : e.knobs
            infos = if instances.empty?
                      [r.info(specs: specs, out: e.out)]
                    else
                      instances.map { |key, knobs|
                        names = knobs.values.map(&:name)
                        path = Name[names.first].base
                        r.info(path: path, knobs: names, specs: specs, out: e.out)
                      }
                    end
            [r.name, infos.freeze]
          }.freeze
        end

        # "space 0.3 (0..1)", "cut 800 Hz (100..8000 exp)" for knob +name+
        # with Knob::Spec +spec+.
        def self.spec_text(name, spec)
          k = GraphNode::Knob
          "#{name} #{k.number(spec.default)}#{spec.unit ? " #{spec.unit}" : ''} (#{k.number(spec.range.begin)}..#{k.number(spec.range.end)}#{spec.curve == :exp ? ' exp' : ''})"
        end

        # The knobs of named rack +name+ seen in the latest application
        # ({ knob => Knob::Spec }), or an empty Hash.
        def knob_specs(name)
          @mutex.synchronize { @entries[name]&.knobs || {} }
        end

        # The Session knobs (names) of the knobs of rack +name+ (nil for
        # anonymous racks), every instance's.
        def knob_names(name)
          @mutex.synchronize {
            (@knob_keys[name] || []).flat_map { |key| (@instance_knobs[[name, key]] || {}).values.map(&:name) }
          }
        end

        # The Session knobs of the knobs of rack +name+ by instance key
        # ({ [player, ordinal] => { knob => Knob } }).
        def knob_instances(name)
          @mutex.synchronize {
            (@knob_keys[name] || []).to_h { |key| [key, (@instance_knobs[[name, key]] || {}).dup] }
          }
        end

        # Names for rack knobs joining the Session (see
        # Session::Knobs#adopt_knobs): +knobs+ are standalone rack knobs
        # (not shared) of a graph played by +player+ (a player name, or
        # nil).  Instances are told apart by their Rack::Application, in
        # the order they appear in the graph, keyed [player, ordinal].
        # Returns [{ knob => [name, rack name, key] }, renames], where
        # renames are [session knob, new name] pairs: a named rack's
        # knobs are :"dub/space" while one key uses them, and per instance
        # (:"bass/dub/space") from the second key on, which renames the
        # first key's knobs.
        def instance_knob_names(knobs, player)
          instance_member_names(knobs, player)
        end

        # #instance_knob_names for rack knobs and slots (GraphNode::Slot
        # made inside a rack: racks R3) alike, so a rack's knobs and slots
        # share their instance's key and path (:"bass/dub/space" and
        # :"bass/dub/color").  Keys given to an Application once are kept
        # for it (a slot's content swapped in later joins the same key).
        # Renames hold knobs and slots.
        def instance_member_names(members, player)
          renames = []
          out = {}.compare_by_identity
          @mutex.synchronize {
            used = Hash.new { |h, k| h[k] = [] }
            apps = {}.compare_by_identity
            key_of = {}.compare_by_identity
            members.each do |m|
              rack, app, = Racks.member_info(m)
              key_of[m] = (apps[app] ||= begin
                key = @app_keys[app]
                if key.nil? || key[0] != player
                  ord = 0
                  ord += 1 while used[rack].include?(ord)
                  key = [player, ord]
                  @app_keys[app] = key
                end
                used[rack] << key[1]
                key
              end)
              keys = (@knob_keys[rack] ||= [])
              next if keys.include?(key_of[m])
              keys << key_of[m]
              if rack && keys.length >= 2 && !@per_instance[rack]
                @per_instance[rack] = true
                keys.each { |key|
                  (@instance_knobs[[rack, key]] || {}).each { |short, knob| renames << [knob, instance_name(rack, key, keys, short)] }
                  (@instance_slots[[rack, key]] || {}).each { |short, slot| renames << [slot, instance_name(rack, key, keys, short)] }
                }
              end
            end
            members.each do |m|
              rack, _, short = Racks.member_info(m)
              key = key_of[m]
              keys = @knob_keys[rack]
              name = if rack.nil?
                       anonymous_name(key, short)
                     elsif !@per_instance[rack]
                       Name.join(rack, short)
                     else
                       instance_name(rack, key, keys, short)
                     end
              out[m] = [name, rack, key]
            end
          }
          [out, renames]
        end

        # [rack name, Rack::Application, short name] of rack knob or slot
        # +m+.
        def self.member_info(m)
          if m.is_a?(GraphNode::Slot)
            [m.rack&.name, m.application, m.name]
          else
            info = m.rack_knob
            [info.rack_name, info.application, info.knob]
          end
        end

        # Remembers Session knob +knob+ as the rack knob +short+ of instance +key+
        # of rack +rack+ (see #instance_knob_names).  Returns the group name to
        # claim (:"dub/space", once the rack's knobs are per instance) or
        # nil.
        def knob_joined(rack, key, short, knob)
          @mutex.synchronize {
            (@instance_knobs[[rack, key]] ||= {})[short] = knob
            next nil unless rack && @per_instance[rack]
            group = Name.join(rack, short)
            next nil if @knob_groups.key?(group)
            @knob_groups[group] = [rack, short]
            group
          }
        end

        # True if +name+ is a knob group: a rack's short knob name
        # (:"dub/space") standing for every instance's knob once the
        # knobs are per instance.
        def knob_group?(name)
          @mutex.synchronize { @knob_groups.key?(name) }
        end

        # The Session knobs a knob group stands for (see #knob_group?),
        # or nil if +name+ isn't one.
        def group_members(name)
          @mutex.synchronize {
            rack, short = @knob_groups[name]
            next nil unless rack
            (@knob_keys[rack] || []).filter_map { |key| @instance_knobs[[rack, key]]&.[](short) }
          }
        end

        # Drops the knob instances of players that are gone (forgotten:
        # neither playing, stopped for resume, nor an arrangement track),
        # so names don't go stale.  The block tells whether a player name
        # is still around.  Returns [knobs to forget, group names to
        # release] (a rack left with no instances goes back to plain
        # names).
        def prune_knob_instances
          gone = []
          groups = []
          slots = []
          @mutex.synchronize {
            @knob_keys.each do |rack, keys|
              keys.reject! { |key|
                player = key[0]
                next false if player.nil? || yield(player)
                gone.concat((@instance_knobs.delete([rack, key]) || {}).values)
                slots.concat((@instance_slots.delete([rack, key]) || {}).values)
                true
              }
              next unless keys.empty?
              @per_instance.delete(rack)
              @knob_groups.reject! { |g, (r, _)| r == rack && groups << g }
              @slot_groups.reject! { |g, (r, _)| r == rack && groups << g }
            end
            @plain_slots.reject! { |_, slot| slot.player && !yield(slot.player) && slots << slot }
          }
          [gone, groups, slots]
        end

        # Remembers +slot+ as slot +short+ of instance +key+ of rack +rack+
        # (see #instance_member_names; nil +rack+ for an anonymous rack's).
        # Returns the group name to claim (:"dub/color", once the rack's
        # slots are per instance) or nil.
        def slot_joined(rack, key, short, slot)
          @mutex.synchronize {
            (@instance_slots[[rack, key]] ||= {})[short] = slot
            next nil unless rack && @per_instance[rack]
            group = Name.join(rack, short)
            next nil if @slot_groups.key?(group)
            @slot_groups[group] = [rack, short]
            group
          }
        end

        # Remembers +slot+ (outside any rack) under its Session name.
        def plain_slot_joined(slot)
          @mutex.synchronize { @plain_slots[slot.path] = slot }
        end

        # The slots Session name +name+ stands for: one slot, every
        # instance's slot of a group (:"dub/color" once the rack plays in
        # several players), or an empty Array.
        def slots_for(name)
          @mutex.synchronize {
            if (s = @plain_slots[name])
              next [s]
            end
            if (rack, short = @slot_groups[name])
              next (@knob_keys[rack] || []).filter_map { |key| @instance_slots[[rack, key]]&.[](short) }
            end
            @instance_slots.each_value.filter_map { |by| by.each_value.find { |sl| sl.path == name } }.first(1)
          }
        end

        # Every slot in the Session ({ name => Slot }), groups left out.
        def slots
          @mutex.synchronize {
            list = @plain_slots.dup
            @instance_slots.each_value { |by| by.each_value { |sl| list[sl.path] = sl } }
            list
          }
        end

        # Slot and slot group names (for messages).
        def slot_names
          slots.keys + @mutex.synchronize { @slot_groups.keys }
        end

        # True if +name+ is a slot group (see #slots_for).
        def slot_group?(name)
          @mutex.synchronize { @slot_groups.key?(name) }
        end

        # The slots of named rack +name+, every instance's: { path => Slot }.
        def rack_slots(name)
          @mutex.synchronize {
            (@knob_keys[name] || []).each_with_object({}) { |key, h|
              (@instance_slots[[name, key]] || {}).each_value { |sl| h[sl.path] = sl }
            }
          }
        end

        private

        def uses_text(e)
          used = e.uses.zero? ? 'not used yet' : "#{e.uses} use#{'s' if e.uses != 1}"
          where = players_using(e)
          used += " (in #{where.map(&:inspect).join(', ')})" unless where.empty?
          used
        end

        # A per-instance knob name: :"bass/dub/space" (the second instance
        # in one player :"bass/dub.2/space"; without a player, by order:
        # :"dub.1/space").
        def instance_name(rack, key, keys, short)
          player, ord = key
          return Name.join("#{rack}.#{keys.index(key) + 1}", short) if player.nil?
          Name.join(player, "#{rack}#{ord > 0 ? ".#{ord + 1}" : ''}", short)
        end

        # An anonymous rack's knob name: the player's (:"bass/space",
        # :"bass/rack.2/space" for a second instance), else :"rack/space".
        def anonymous_name(key, short)
          player, ord = key
          parts = [player || 'rack']
          parts << "rack.#{ord + 1}" if ord > 0
          Name.join(*parts, short)
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
