module MB
  module Sound
    class Session
      # Knobs on a Session (contract K6; see GraphNode::Knob and
      # design/notes/arrangement.md): named values that graphs read with
      # `knob(:cut)` and performers move with #turn, through the change
      # queue like every other change (exact landing frames, journaled,
      # undoable, replayed exactly by takes).  Knob names share the
      # Session's namespace with tracks and mute groups (see Names).
      #
      # The Session advances every knob once per buffer, before its players
      # render, so readers in any number of graphs (asleep or not) see the
      # same values, and ramps land on the same frames at any buffer size.
      #
      # Snapshots (#snap, #recall, #xfade) remember and morph between the
      # values of every knob.
      module Knobs
        # The subject of a knob change for undo snapshots (knob names share
        # the namespace with tracks, but a raw `bg :name` player could use
        # one).
        KnobSubject = Data.define(:name)

        # A knob's state around a change, for undo (see Knob#state_at).
        KnobState = Struct.new(:mode, :value, keyword_init: true)

        # The first frame of the buffer (span) being rendered, while knobs
        # and players render it (nil otherwise).  Knob readers read this
        # frame's values.
        attr_reader :knob_frame

        # What knobs listen to for controllers (#learn, cc:): the Session's
        # default MIDI input (see MidiIn#midi_in; the console attaches live
        # input to it) unless set to another MIDI::Stream or MidiInput.
        def knob_midi
          @knob_midi || midi_in
        end

        attr_writer :knob_midi

        # Defines a knob named +name+ starting at +default+ (see
        # GraphNode::Knob::Spec for the options: range:, curve:, unit:, cc:,
        # takeover:, smooth:), or returns the existing one.  Defining a knob
        # again changes its options and keeps its value (graphs keep reading
        # the same knob).  Without a default or options, an unknown name
        # raises with suggestions.  The name is claimed in #names (a name
        # used by a track or group goes through MB::Sound.live_error).
        def knob(name, default = nil, **spec)
          raise ArgumentError, "Knob names must be Symbols (got #{name.inspect})" unless name.is_a?(Symbol)

          existing = @knob_lock.synchronize { @knobs[name] }
          if existing
            options = spec.dup
            options[:default] = default unless default.nil?
            existing.respec(**options) unless options.empty?
            return existing
          end

          if default.nil? && spec.empty?
            raise ArgumentError, "No knob #{name.inspect}#{knob_suggestion(name)}; define it with `knob #{name.inspect}, value, range: lo..hi`"
          end

          return nil unless @names.claim(name, :knob)

          rate = output_open? ? sample_rate : 48000
          k = nil
          @render_lock.synchronize {
            k = GraphNode::Knob.new(name, default, session: self, sample_rate: rate, frame: @frame, **spec)
            @knob_lock.synchronize { @knobs[name] = k }
          }
          k
        end

        # The knob named +name+, raising with suggestions if there is none.
        def knob!(name)
          return name.knob if name.is_a?(GraphNode::Knob::Reader)
          return name if name.is_a?(GraphNode::Knob)
          @knob_lock.synchronize { @knobs[name] } or raise ArgumentError, "No knob #{name.inspect}#{knob_suggestion(name)}"
        end

        # The knobs (a Hash from name to GraphNode::Knob).
        def knobs
          @knob_lock.synchronize { @knobs.dup }
        end

        # Brings the standalone knobs in +sound+ (a graph, bundle, or Array
        # of graphs; e.g. a graph document's `knob` lines, which load as
        # GraphNode::Knobs belonging to no Session) into this Session, so
        # #turn, scenes, snapshots, and #learn work on them (omnibus6,
        # maintainer: "join knobs and live_error").  #add calls this for
        # every graph it plays; the console's `preset` when it loads.
        #
        # - A new name: the knob itself joins (claiming the name in #names;
        #   a track or group of that name goes through MB::Sound.live_error,
        #   and live the knob stays standalone), keeping its value.
        # - The name of a Session knob with the same range and curve: the
        #   graph reads the Session's knob instead (it keeps its value, so a
        #   document loaded twice, or two documents with a :cut knob, share
        #   one knob that `turn :cut` moves).  A different range or curve
        #   goes through MB::Sound.live_error (live: stays standalone).
        #
        # Knobs with a MIDI controller (+cc:+) listen to #knob_midi (the
        # console attaches live input to it; see KnobMethods).  Knobs of
        # this or another Session are left alone.  Returns the Session knobs
        # the graph now reads (a Hash from name to Knob).
        #
        # Rack macros (RackMethods#macro) are named here, for player
        # +player+ (see Racks#macro_names): :"dub/space" for a rack in one
        # player, per instance (:"bass/dub/space") once it plays in
        # several, renaming the first instance's knobs.  A macro instance
        # joining its own earlier knob (the same player playing the rack
        # again) takes the macro's new range and curve.  Macros with
        # +follow:+ start following their Session knob when they join.
        def adopt_knobs(sound, player: nil)
          nodes = to_nodes(sound)
          found = nodes.flat_map { |n| [n, *n.graph] }
          readers = found.grep(GraphNode::Knob::Reader)
          own = {}.compare_by_identity
          (readers.map(&:knob) + found.grep(GraphNode::Knob)).each { |k| own[k] = true }

          macros = own.keys.select { |k| k.macro && !k.session && !k.macro.share }
          macro_keys = {}.compare_by_identity
          unless macros.empty?
            prune_macros
            names, renames = racks.macro_names(macros, player)
            renames.each { |k, name| rename_knob(k, name) }
            names.each { |k, (name, rack, key)|
              k.respec(name: name)
              macro_keys[k] = [rack, key]
            }
          end

          joined = {}
          fresh = []
          own.each_key do |k|
            if k.session
              joined[k.name] = k if k.session.equal?(self)
              next
            end

            existing = @knob_lock.synchronize { @knobs[k.name] }
            if existing && existing.macro && k.macro && macro_keys.key?(k) && !k.macro.share
              # The same instance again (a player replaying the rack): the
              # rack's current range and curve
              if existing.range != k.range || existing.spec.curve != k.spec.curve
                existing.respec(range: k.range, curve: k.spec.curve)
                existing.set(existing.target || existing.value, frame: @frame, smooth: 0) unless existing.mode == :follow
              end
            end
            if existing
              if existing.range != k.range || existing.spec.curve != k.spec.curve
                MB::Sound.live_error(ArgumentError.new(
                  "The graph's knob #{k.name.inspect} (#{k.range} #{k.spec.curve}) doesn't match the session's (#{existing.range} #{existing.spec.curve}); rename one of them"
                ))
                next
              end

              readers.each { |r| r.rebind(existing) if r.knob.equal?(k) }
              k.redirect(existing)
              ([sound] + found).each { |n|
                doc = GraphIO.document_of(n)
                doc.knob_nodes[k.name] = [existing] if doc && doc.knob_nodes[k.name]&.any? { |x| x.equal?(k) }
              }
              joined[k.name] = existing
            else
              next unless @names.claim(k.name, :knob)
              @render_lock.synchronize {
                k.attach(self, frame: @frame, sample_rate: output_open? ? sample_rate : k.sample_rate)
                @knob_lock.synchronize { @knobs[k.name] = k }
              }
              joined[k.name] = k
              fresh << k
            end
            if (rk = macro_keys[k]) && joined[k.name]
              group = racks.macro_joined(rk[0], rk[1], k.macro.macro, joined[k.name])
              @names.claim(group, :macro_group) if group
            end
          end

          fresh.each { |k| follow_macro(k) if k.macro&.follow }
          joined.each_value { |k| k.listen(knob_midi) if k.cc && !k.listening }
          joined
        end

        # Drops the macro knobs of players that are gone (see
        # Racks#prune_macro_instances): forgotten players' instances leave
        # the session's knobs and names, so listings and group turns don't
        # go stale.  Called when graphs join (#adopt_knobs) and when players
        # are forgotten.
        def prune_macros
          gone, groups = racks.prune_macro_instances { |player| player_around?(player) }
          gone.each do |k|
            removed = @knob_lock.synchronize { @knobs.delete(k.name) if @knobs[k.name].equal?(k) }
            @names.release(k.name) if removed
          end
          groups.each { |g| @names.release(g) if @names.kind(g) == :macro_group }
        end

        # True if player +name+ is playing, stopped for #resume, waiting to
        # start in the change queue, or an arrangement track.
        def player_around?(name)
          @mutex.synchronize { @players.values.any? { |p| p.name == name && p.current? } || @stopped.key?(name) } ||
            @changes.dup.any? { |c| c.subject == name && c.starts } ||
            !!@arrangement&.tracks&.key?(name)
        end

        # Renames Session knob +k+ to +name+ (a rack's macros becoming per
        # instance; see #adopt_knobs), keeping its value, readers, and
        # snapshot values.
        def rename_knob(k, name)
          old = k.name
          return if old == name
          raise ArgumentError, "Knob #{name.inspect} exists already" if @knob_lock.synchronize { @knobs.key?(name) }
          return unless @names.claim(name, :knob)

          @knob_lock.synchronize {
            @knobs.delete(old)
            @knobs[name] = k
            @snapshots.transform_values! { |snap| snap.key?(old) ? snap.to_h { |n, v| [n == old ? name : n, v] }.freeze : snap }
          }
          @names.release(old)
          k.respec(name: name)
          puts "Knob #{old.inspect} is #{name.inspect} now (rack #{k.macro.rack_name.inspect} plays in more than one place)" if MB::Sound.live?
        end

        # Makes macro knob +k+ follow the Session knob its +follow:+ names,
        # through the macro's own range and curve (the knob's position in
        # its range is the macro's position in its own).  A missing knob
        # goes through MB::Sound.live_error (live: the macro holds its
        # value).
        def follow_macro(k)
          src_name = k.macro.follow
          src = @knob_lock.synchronize { @knobs[src_name] }
          unless src
            MB::Sound.live_error(ArgumentError.new(
              "Macro #{k.name.inspect} follows knob #{src_name.inspect}, which the session doesn't have#{knob_suggestion(src_name)}; define it first (knob #{src_name.inspect}, 0.5)"
            ))
            return
          end
          from = src.spec
          to = k.spec
          map = ->(x) { to.value(from.positions(x).clip(0.0, 1.0)) }
          k.follow(src, frame: @frame, map: map, label: "knob(#{src_name.inspect}) through #{to.range.begin}..#{to.range.end}")
        end

        # Moves knob +name+ at the launch point (+on:+, +in:+, +at:+; see
        # LaunchPoint; right away by default, like mutes): to +value+ (a
        # number, limited to the knob's range; gliding over the knob's
        # +smooth:+ time, or +smooth:+ seconds here), over +over:+ (bars, a
        # Duration, or a Length) shaped by +curve:+ (a Curve name or
        # MB::Sound::Curve) in the knob's scale (from where it is, or
        # +from:+ a value), or following a graph node
        # (+value+ or +follow:+ a node or another knob's name) until it is
        # turned again.  Returns the Change (see Changes#change).
        #
        # A rack's macro group name (:"dub/space" once the rack plays in
        # several players; see Racks#macro_group?) turns every instance's
        # knob, returning the Changes.
        def turn(name, value = nil, at: nil, on: nil, in: nil, over: nil, curve: nil, from: nil, follow: nil, smooth: nil, start_time: nil)
          if name.is_a?(Symbol) && (members = racks.group_members(name))
            offset = binding.local_variable_get(:in)
            return members.map { |k| turn(k.name, value, at: at, on: on, in: offset, over: over, curve: curve, from: from, follow: follow, smooth: smooth, start_time: start_time) }
          end
          point = LaunchPoint.of(binding) or return nil
          k = knob!(name)
          value = follow unless follow.nil?
          raise ArgumentError, "Turn #{k.name.inspect} to a number or a node (got nil)" if value.nil?
          check_turn_value(k, value)
          raise ArgumentError, "from: needs over: (a ramp)" if from && !over
          raise ArgumentError, "from: must be a number (got #{from.inspect})" unless from.nil? || (from.is_a?(Numeric) && from.real?)
          warn_clamp(k, value) if value.is_a?(Numeric)

          time = start_time ? start_time.to_r : launch_time(point, [], default: nil)
          knob_change(k, time, turn_data(value, over, curve).merge(from ? { from: from } : {})) { |kn, frame, t|
            apply_turn(kn, value, frame, t, over: over, curve: curve, smooth: smooth, from: from)
          }
        end

        # Remembers every knob's value (or where it is heading, while it
        # ramps) as snapshot +name+, when the launch point arrives (now by
        # default).  Returns the Change.
        def snap(name, at: nil, on: nil, in: nil, start_time: nil, knobs: nil)
          point = LaunchPoint.of(binding) or return nil
          raise ArgumentError, "Snapshot names must be Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          only = knobs&.map { |n| knob!(n).name }

          time = start_time ? start_time.to_r : launch_time(point, [], default: nil)
          change(:snap, name, time, data: only ? { knobs: only } : {}) { |_t|
            frame = @landing_frame || @frame
            list = self.knobs
            list = list.slice(*only) if only
            values = list.transform_values { |k| st = k.state_at(frame); st[0] == :follow ? k.value : st[1] }
            @knob_lock.synchronize { @snapshots[name] = values.freeze }
          }
        end

        # The snapshots (a Hash from name to a Hash of knob values).
        def snapshots
          @knob_lock.synchronize { @snapshots.dup }
        end

        # Turns every knob in snapshot +name+ back to its value there (see
        # #turn for the options).  +only:+ and +except:+ (knob names, or a
        # rack's macro names: :space matches :"dub/space") limit the recall
        # to some knobs (a partial recall).  Returns the Changes.
        def recall(name, at: nil, on: nil, in: nil, over: nil, curve: nil, smooth: nil, start_time: nil, only: nil, except: nil)
          point = LaunchPoint.of(binding) or return nil
          names = filter_knob_names(snapshot_knob_names(name), only, except)
          names &= knobs.keys # (macros of forgotten players are gone)
          time = start_time ? start_time.to_r : launch_time(point, [], default: nil)

          names.map { |n|
            k = knob!(n)
            knob_change(k, time, { recall: name, over: over }.compact) { |kn, frame, t|
              v = snapshot_value(name, kn)
              apply_turn(kn, v, frame, t, over: over, curve: curve, smooth: smooth) unless v.nil?
            }
          }
        end

        # Moves every knob to +amount+ of the way from snapshot +a+ to
        # snapshot +b+ (0 is +a+, 1 is +b+), in each knob's scale.  +amount+
        # may be a node or a knob name: the knobs then follow it (an
        # Octatrack-style crossfader: `knob :morph, 0; xfade :dark, :bright,
        # :morph; turn :morph, 1, over: 8.bars`).  Knobs missing from a
        # snapshot use their value when the crossfade lands.  See #turn for
        # the other options.  Returns the Changes.
        def xfade(a, b, amount = 0.5, at: nil, on: nil, in: nil, over: nil, curve: nil, smooth: nil, start_time: nil)
          point = LaunchPoint.of(binding) or return nil
          names = (snapshot_knob_names(a) + snapshot_knob_names(b)).uniq
          source = amount.is_a?(Symbol) ? knob!(amount) : amount
          if source.is_a?(Numeric)
            raise ArgumentError, "xfade amount must be a number from 0 to 1, a node, or a knob name (got #{amount.inspect})" unless source.real?
          elsif !source.respond_to?(:sample)
            raise ArgumentError, "xfade amount must be a number from 0 to 1, a node, or a knob name (got #{amount.inspect})"
          end

          time = start_time ? start_time.to_r : launch_time(point, [], default: nil)
          # A crossfader knob in the snapshots stays where it is
          names -= [source.name] if source.is_a?(GraphNode::Knob)
          names.map { |n|
            k = knob!(n)

            knob_change(k, time, { xfade: [a, b], amount: source.is_a?(Numeric) ? source : GraphNode::Knob.label_of(source), over: over }.compact) { |kn, frame, t|
              va = snapshot_value(a, kn) || kn.value
              vb = snapshot_value(b, kn) || kn.value
              if source.is_a?(Numeric)
                apply_turn(kn, crossfade_value(kn.spec, va, vb, source.to_f), frame, t, over: over, curve: curve, smooth: smooth)
              else
                spec = kn.spec
                map = ->(x) { crossfade_values(spec, va, vb, x.clip(0.0, 1.0)) }
                kn.follow(source, frame: frame, map: map, time: t, transport: @transport, label: "xfade #{a.inspect}..#{b.inspect} by #{GraphNode::Knob.label_of(source)}")
              end
            }
          }
        end

        # Makes knob +name+ wait for the next MIDI controller moved on
        # #knob_midi (or +stream+) and follow it from then on (see
        # GraphNode::Knob#listen for pickup and jump takeover).  Learning
        # starts through the change queue (a :learn change landing now), so
        # a take replays it on the same frame.  Returns the knob.
        def learn(name, stream: nil)
          k = knob!(name)
          explicit = !stream.nil?
          stream ||= knob_midi
          k.listen(stream) if k.listening.nil? || (explicit && !stream.equal?(k.listening))
          change(:learn, k.name, now, data: {}) { |_t| k.learn(from_frame: @landing_frame || @frame) }
          k
        end

        # Makes knob +name+ follow MIDI controller +cc+ on #knob_midi (or
        # +stream+).  Returns the knob.
        def bind_cc(name, cc, stream: nil)
          k = knob!(name)
          stream ||= knob_midi
          k.listen(stream) if k.listening.nil?
          k.cc = cc
          k
        end

        # A listing of the knobs: name => "800 Hz (100..8000 exp) cc74 -> 3000".
        def knob_info
          knobs.transform_values { |k|
            parts = [k.value_string, "(#{GraphNode::Knob.number(k.range.begin)}..#{GraphNode::Knob.number(k.range.end)}#{k.spec.curve == :exp ? ' exp' : ''})"]
            parts << "cc#{k.cc}" if k.cc
            parts << 'learning' if k.learning?
            parts << "-> #{GraphNode::Knob.number(MB::M.sigfigs(k.target, 4))}" if k.mode == :ramp
            parts << "following #{k.instance_variable_get(:@segment).label}" if k.mode == :follow
            parts.join(' ')
          }
        end

        private

        def init_knobs
          @knobs = {}
          @snapshots = {}
          @knob_lock = Mutex.new
          @knob_frame = nil
          @knob_midi = nil
        end

        def knob_suggestion(name)
          names = @knob_lock.synchronize { @knobs.keys }
          return '' if names.empty?
          " (knobs: #{names.map(&:inspect).join(', ')})#{Form.suggest(name, names)}"
        end

        # Queues a change to knob +k+ at +time+ (now if nil), calling the
        # block with the knob, its landing frame, and the landing position.
        def knob_change(k, time, data, &apply)
          change(:turn, k.name, time, data: data) { |t|
            apply.call(k, @landing_frame || @frame, t)
          }
        end

        # Advances every knob over the span [+frame+, +frame+ + +count+)
        # before players read them (called by #render_span).  Nodes that
        # knobs follow keep their own time across seeks (they count from
        # the turn; see GraphNode::Knob#follow).
        def advance_knobs(frame, count)
          @knob_frame = frame
          list = @knob_lock.synchronize { @knobs.values }
          list.each { |k| k.read(frame, count) }
        end

        def check_turn_value(k, value)
          case value
          when Numeric
            raise ArgumentError, "Turn #{k.name.inspect} to a real number (got #{value.inspect})" unless value.real? && value.finite?
          when Symbol
            knob!(value)
          else
            raise ArgumentError, "Turn #{k.name.inspect} to a number or a node (got #{value.inspect})" unless value.respond_to?(:sample) && value.respond_to?(:get_sampler)
          end
        end

        # Warns once per knob when a turn goes past its range (the value
        # is limited to it; ux-1 item 30: `turn :drive, 100` on a 0..1
        # knob "doesn't apply any amplification", silently).
        def warn_clamp(k, value)
          r = k.range
          return if value.between?(r.begin, r.end)
          @clamp_warned ||= {}
          return if @clamp_warned[k.name]
          @clamp_warned[k.name] = true
          n = GraphNode::Knob.method(:number)
          warn "turn #{k.name.inspect}, #{n.(value)}: limited to #{n.(value.to_f.clamp(r.begin, r.end))} (knob #{k.name.inspect} goes #{n.(r.begin)}..#{n.(r.end)}; " \
               "knob #{k.name.inspect}, #{n.(k.spec.default)}, range: #{widened(r, value)} widens it)"
        end

        # +range+ widened to hold +value+, to a round number.
        def widened(range, value)
          n = GraphNode::Knob.method(:number)
          round = ->(v) { m = 10**Math.log10([v.abs, 1e-9].max).floor; (v.to_f / m).ceil * m }
          value > range.end ? "#{n.(range.begin)}..#{n.(round.(value))}" : "#{n.(-round.(-value))}..#{n.(range.end)}"
        end

        # Journal data for a turn.
        def turn_data(value, over, curve)
          what = value.is_a?(Numeric) ? { value: value } : { follow: value.is_a?(Symbol) ? "knob(#{value.inspect})" : GraphNode::Knob.label_of(value) }
          what.merge({ over: over, curve: curve }.compact)
        end

        # Applies a turn to knob +k+ on frame +frame+ (landing position +t+).
        def apply_turn(k, value, frame, t, over:, curve:, smooth:, from: nil)
          value = knob!(value) if value.is_a?(Symbol)

          if value.is_a?(Numeric)
            if over
              k.ramp_to(value, frames: knob_frames(over), frame: frame, curve: curve, from: from)
            else
              k.set(value, frame: frame, smooth: smooth)
            end
          else
            k.follow(value, frame: frame, time: t, transport: @transport)
          end
        end

        # The number of frames in +over+ (bars, a Duration, or a Length) at
        # the current tempo.
        def knob_frames(over)
          rate = output_open? ? sample_rate : 48000
          case over
          when Length
            Length.samples(over, sample_rate: rate, transport: @transport).round
          when Numeric
            raise ArgumentError, "over: must be a positive number of bars (got #{over.inspect})" unless over.real? && over.finite? && over >= 0
            (@transport.seconds(over.to_r * @transport.bar_length) * rate).round
          else
            raise ArgumentError, "over: must be bars, a Duration, or a Length (got #{over.inspect})"
          end
        end

        # The names of the knobs in snapshot +name+ (every knob if it
        # doesn't exist yet but a snap of it is queued).
        def snapshot_knob_names(name)
          snap = @knob_lock.synchronize { @snapshots[name] }
          return snap.keys if snap
          return knobs.keys if queued(name).any? { |e| e.kind == :snap }

          known = snapshots.keys
          raise ArgumentError, "No snapshot #{name.inspect}#{known.empty? ? '' : " (snapshots: #{known.map(&:inspect).join(', ')})#{Form.suggest(name, known)}"}"
        end

        # +names+ (knob names) limited by +only+ and +except+ (Arrays of
        # knob names or macro names; a macro name matches the last part of
        # a rack knob's path).
        def filter_knob_names(names, only, except)
          match = ->(n, list) {
            Array(list).any? { |x|
              x = x.to_sym
              n == x || (n.to_s.include?('/') && n.to_s.split('/').last == x.to_s)
            }
          }
          if only
            picked = names.select { |n| match.(n, only) }
            missing = Array(only).reject { |x| names.any? { |n| match.(n, [x]) } }
            raise ArgumentError, "only: #{missing.map(&:inspect).join(', ')} #{missing.length > 1 ? 'aren\'t' : 'isn\'t'} in the snapshot (#{names.map(&:inspect).join(', ')})" unless missing.empty?
            names = picked
          end
          names = names.reject { |n| match.(n, except) } if except
          names
        end

        # Knob +k+'s value in snapshot +name+ when it lands, or nil.
        def snapshot_value(name, k)
          @knob_lock.synchronize { @snapshots[name]&.[](k.name) }
        end

        # +amount+ of the way from +a+ to +b+ in +spec+'s scale.
        def crossfade_value(spec, a, b, amount)
          return a + (b - a) * amount if spec.curve == :linear
          pa = spec.position(a)
          spec.value(pa + (spec.position(b) - pa) * amount)
        end

        # #crossfade_value for a Numo::DFloat of amounts.
        def crossfade_values(spec, a, b, amount)
          return amount * (b - a) + a if spec.curve == :linear
          pa = spec.position(a)
          spec.value(amount * (spec.position(b) - pa) + pa)
        end

        # A knob's state just before the change landing now (for undo).
        def knob_snapshot(subject)
          k = @knob_lock.synchronize { @knobs[subject.name] } or return nil
          mode, value = k.state_at(@landing_frame || @frame)
          KnobState.new(mode: mode, value: value)
        end

        # Puts knob +name+ back to +state+ (a KnobState) on the landing
        # frame: a held value (with the knob's declick glide) or the node
        # it followed.
        def restore_knob(name, state)
          k = knob!(name)
          return if state.nil?
          frame = @landing_frame || @frame
          if state.mode == :follow
            k.refollow(state.value, frame: frame)
          else
            k.set(state.value, frame: frame)
          end
        end

        # True if +c+ changes a knob (a turn, or the undo of one).
        def knob_change?(c)
          c.kind == :turn || (c.kind == :restore && c.entry&.data&.[](:knob))
        end
      end
    end
  end
end
