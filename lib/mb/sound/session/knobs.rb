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

        # A live knob gesture (a held key in the racks pane; see
        # #preview_turn): the knob's name, the frame and timeline position
        # of its first step, the knob's state before it (for undo), its
        # steps ([frames after the first, value], one per span at most), the
        # timeline's whole notes per frame there (for printing times), and
        # the fitted MB::Sound::Gesture its line printed (see
        # #gesture_line).
        KnobGesture = Struct.new(:name, :frame, :pos, :before, :steps, :per_sample, :fitted, keyword_init: true)

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
            unless options.empty?
              # An implicit knob (below) defined at last: its readers keep
              # reading it, and it moves to the new default
              was_implicit = existing.implicit
              existing.implicit = false
              # (as a new knob: the implicit 0..1 range doesn't carry over)
              existing.respec(**(was_implicit ? { range: nil, curve: :linear }.merge(options) : options))
              existing.set(existing.spec.default, frame: @frame) if was_implicit && !existing.spec.default.nil?
            end
            return existing
          end

          if default.nil? && spec.empty?
            return implicit_knob(name) if MB::Sound.live?
            raise ArgumentError, "No knob #{name.inspect}#{knob_suggestion(name, define: true)}"
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

        # The default of a knob read before it was defined (live; see
        # #implicit_knob).
        IMPLICIT_DEFAULT = 0.5

        # The range of a knob read before it was defined.
        IMPLICIT_RANGE = 0.0..1.0

        # Live mode (MB::Sound.live?), a graph reading knob +name+ before it
        # was defined defines it (omnibus9; the maintainer's ux-r4 note 5):
        # IMPLICIT_DEFAULT of IMPLICIT_RANGE, flagged GraphNode::Knob#implicit
        # (knob_info says so), with a one-line note.  A later `knob :x, ...`
        # gives it its range, curve, and default without losing its readers.
        # Scripts and specs stay strict (#knob raises with a hint).
        def implicit_knob(name)
          return nil unless @names.claim(name, :knob)

          rate = output_open? ? sample_rate : 48000
          k = nil
          @render_lock.synchronize {
            k = GraphNode::Knob.new(name, IMPLICIT_DEFAULT, session: self, sample_rate: rate, frame: @frame, range: IMPLICIT_RANGE)
            k.implicit = true
            @knob_lock.synchronize { @knobs[name] = k }
          }
          warn "knob #{name.inspect} wasn't defined: made it #{IMPLICIT_DEFAULT} of #{IMPLICIT_RANGE} for now; " \
            "`knob #{name.inspect}, value, range: lo..hi` sets it (what reads it keeps reading it)#{knob_suggestion(name)}"
          k
        end

        # The name of the control +name+ stands for (ux-fix-1, the one
        # resolution rule; design/notes/arrangement.md "Names that stand for
        # controls"): a name resolves through its owner's kind in the
        # shared namespace (Session::Names): a knob's name is the knob; a
        # rack knob group's name stands for every instance's knob (#turn
        # turns them all; Session::Racks#group_members); any other owner
        # with a primary control (#primary_control: a trigger track's on/off
        # level, :"pump/level") stands for that control.  Every command
        # taking knob names (turn, snap knobs:, recall only:/except:, xfade,
        # learn, bind_cc, scene and section values) resolves through here
        # or #knob!.  Other values pass through.
        def control_name(name)
          return name unless name.is_a?(Symbol)
          return name if @knob_lock.synchronize { @knobs.key?(name) }
          primary_control(name) || name
        end

        # True if +name+ names a track's level knob (:"bass/level"), made
        # yet or not (see Faders).
        def track_level_name?(name)
          return false unless name.is_a?(Symbol)
          nm = Name[name]
          nm.level? && @names.kind(nm.owner) == :track
        end

        # The knob name of the primary control of +name+'s owner (see
        # #control_name), or nil: a track's level (Faders: :"bass/level",
        # whether or not it was made yet), so `turn :bass, 0.5` and scene
        # values `bass: -6.db` set it, and a trigger track's `pump: 0`
        # turns its pump off.  Buses have none (their chain is the level).
        def primary_control(name)
          return nil unless name.is_a?(Symbol) && @names.kind(name) == :track
          level_name(name)
        end

        # Names that stand for controls (#control_name): the knobs and the
        # owners with a primary control (scenes and sections take both).
        def control_names
          names = @knob_lock.synchronize { @knobs.keys }
          owners = @names.to_h.keys.select { |n| primary_control(n) }
          (names + owners + owners.map { |n| level_name(n) }).uniq
        end

        # The knob named +name+ (or the control it stands for: see
        # #control_name), raising with suggestions if there is none.
        def knob!(name)
          return name.knob if name.is_a?(GraphNode::Knob::Reader)
          return name if name.is_a?(GraphNode::Knob)
          name = control_name(name)
          k = @knob_lock.synchronize { @knobs[name] }
          # (a track's level knob is made at unity when first used; Faders)
          k ||= fader!(Name[name].owner) if track_level_name?(name)
          k or raise ArgumentError, "No knob #{name.inspect}#{knob_suggestion(name, define: true)}"
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
        # Rack knobs (RackMethods#rack_knob) are named here, for player
        # +player+ (see Racks#instance_knob_names): :"dub/space" for a rack in one
        # player, per instance (:"bass/dub/space") once it plays in
        # several, renaming the first instance's knobs.  A knob instance
        # joining its own earlier knob (the same player playing the rack
        # again) takes the knob's new range and curve.  Knobs with
        # +follow:+ start following their Session knob when they join.
        def adopt_knobs(sound, player: nil)
          nodes = to_nodes(sound)
          found = nodes.flat_map { |n| [n, *n.graph] }
          readers = found.grep(GraphNode::Knob::Reader)
          own = {}.compare_by_identity
          (readers.map(&:knob) + found.grep(GraphNode::Knob)).each { |k| own[k] = true }

          rack_knobs = own.keys.select { |k| k.rack_knob && !k.session && !k.rack_knob.share }
          rack_knob_keys = {}.compare_by_identity
          unless rack_knobs.empty?
            prune_rack_knobs
            names, renames = racks.instance_knob_names(rack_knobs, player)
            renames.each { |k, name| rename_knob(k, name) }
            names.each { |k, (name, rack, key)|
              k.respec(name: name)
              rack_knob_keys[k] = [rack, key]
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
            if existing && existing.rack_knob && k.rack_knob && rack_knob_keys.key?(k) && !k.rack_knob.share
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
            if (rk = rack_knob_keys[k]) && joined[k.name]
              group = racks.knob_joined(rk[0], rk[1], k.rack_knob.knob, joined[k.name])
              @names.claim(group, :knob_group) if group
            end
          end

          fresh.each { |k| follow_rack_knob(k) if k.rack_knob&.follow }
          joined.each_value { |k| k.listen(knob_midi) if k.cc && !k.listening }
          joined
        end

        # Drops the rack knobs of players that are gone (see
        # Racks#prune_knob_instances): forgotten players' instances leave
        # the session's knobs and names, so listings and group turns don't
        # go stale.  Called when graphs join (#adopt_knobs) and when players
        # are forgotten.
        def prune_rack_knobs
          gone, groups = racks.prune_knob_instances { |player| player_around?(player) }
          gone.each do |k|
            removed = @knob_lock.synchronize { @knobs.delete(k.name) if @knobs[k.name].equal?(k) }
            @names.release(k.name) if removed
          end
          groups.each { |g| @names.release(g) if @names.kind(g) == :knob_group }
        end

        # True if player +name+ is playing, stopped for #resume, waiting to
        # start in the change queue, or an arrangement track.
        def player_around?(name)
          @mutex.synchronize { @players.values.any? { |p| p.name == name && p.current? } || @stopped.key?(name) } ||
            @changes.dup.any? { |c| c.subject == name && c.starts } ||
            !!@arrangement&.tracks&.key?(name)
        end

        # Renames Session knob +k+ to +name+ (a rack's knobs becoming per
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
          puts "Knob #{old.inspect} is #{name.inspect} now (rack #{k.rack_knob.rack_name.inspect} plays in more than one place)" if MB::Sound.live?
        end

        # Makes rack knob +k+ follow the Session knob its +follow:+ names,
        # through the knob's own range and curve (the knob's position in
        # its range is the knob's position in its own).  A missing knob
        # goes through MB::Sound.live_error (live: the knob holds its
        # value).
        def follow_rack_knob(k)
          src_name = k.rack_knob.follow
          src = @knob_lock.synchronize { @knobs[src_name] }
          unless src
            MB::Sound.live_error(ArgumentError.new(
              "Knob #{k.name.inspect} follows knob #{src_name.inspect}, which the session doesn't have#{knob_suggestion(src_name)}; define it first (knob #{src_name.inspect}, 0.5)"
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
        # A rack's knob group name (:"dub/space" once the rack plays in
        # several players; see Racks#knob_group?) turns every instance's
        # knob, returning the Changes.
        #
        # Keyframes (gesture-curves): `turn :space, 0 => 0.30, 1.n8 => 0.50,
        # 1.n4 => 0.62` moves through the values at those times after the
        # launch point (0, note lengths, Lengths, or bars), joined by a
        # monotone cubic in the knob's scale, or by +curve:+ (:linear,
        # :step, or a Curve name per segment; see MB::Sound::Gesture).  A
        # racks-pane gesture's line (#gesture_line) is this form.
        #
        # A build knob (one a track's patch reads while building, such as
        # the init voice's sync; Arrangement::BuildKnobs) takes plain values
        # only, and turning it rebuilds those tracks at their launch points
        # (+build: true+ is that rebuild's own turn).
        def turn(name, value = nil, at: nil, on: nil, in: nil, over: nil, curve: nil, from: nil, follow: nil, smooth: nil, start_time: nil, build: false, **keys)
          name = control_name(name)
          if name.is_a?(Symbol) && (members = racks.group_members(name))
            offset = binding.local_variable_get(:in)
            return members.map { |k| turn(k.name, value, at: at, on: on, in: offset, over: over, curve: curve, from: from, follow: follow, smooth: smooth, start_time: start_time, **keys) }
          end
          check_turn_keywords(keys)
          point = LaunchPoint.of(binding) or return nil
          k = knob!(name)
          if !build && @arrangement&.build_knob?(k.name) && !(rebuilds = @arrangement.build_knob_tracks(k.name)).empty?
            unless keys.empty? && over.nil? && follow.nil? && from.nil? && value.is_a?(Numeric)
              now = k.value.to_f == k.value.round ? k.value.round : k.value
              return MB::Sound.live_error(ArgumentError.new("#{k.name.inspect} is read when #{rebuilds.join(', ')} build#{'s' if rebuilds.length == 1}, so it takes plain values (turn #{k.name.inspect}, #{now}): each turn rebuilds"))
            end
            value = knob_value(k, value)
            check_turn_value(k, value)
            warn_clamp(k, value)
            # (to the value it has: a plain turn, nothing to rebuild)
            return @arrangement.turn_build_knob(k, k.spec.clamp(value), rebuilds, point: point) unless k.spec.clamp(value) == k.value
          end
          unless keys.empty?
            raise ArgumentError, "Turn #{k.name.inspect} with keyframes (0 => a, 1.n8 => b) or a value, not both" unless value.nil? && over.nil? && follow.nil? && from.nil?
            return turn_keys(k, keys, curve, point, start_time)
          end
          return turn_keys(k, { 0 => value }, nil, point, start_time) if gesture_for?(k, value, over, follow, point)
          value = follow unless follow.nil?
          raise ArgumentError, "Turn #{k.name.inspect} to a number or a node (got nil)" if value.nil?
          value = knob_value(k, value)
          check_turn_value(k, value)
          raise ArgumentError, "from: needs over: (a ramp)" if from && !over
          raise ArgumentError, "from: must be a number (got #{from.inspect})" unless from.nil? || (from.is_a?(Numeric) && from.real?)
          warn_clamp(k, value) if value.is_a?(Numeric)

          time = start_time ? start_time.to_r : launch_time(point, [], default: nil)
          data = turn_data(value, over, curve).merge(from ? { from: from } : {}).merge(smooth.nil? ? {} : { smooth: smooth })
          knob_change(k, time, data) { |kn, frame, t|
            apply_turn(kn, value, frame, t, over: over, curve: curve, smooth: smooth, from: from)
          }
        end

        # Ruby's own error for Symbol keys that aren't keywords of #turn (the
        # other keys are keyframe times).
        def check_turn_keywords(keys)
          bad = keys.keys.grep(Symbol)
          return if bad.empty?
          known = %i[at on in over curve from follow smooth]
          hint = bad.filter_map { |b| s = DidYouMean::SpellChecker.new(dictionary: known.map(&:to_s)).correct(b.to_s).first; s && "#{b}: (did you mean #{s}:?)" }
          raise ArgumentError, "unknown keyword#{'s' if bad.length > 1}: #{bad.map(&:inspect).join(', ')}#{" (#{hint.join(', ')})" unless hint.empty?}"
        end
        private :check_turn_keywords

        # A turn through keyframes ({ time => value }; see #turn), playing
        # their MB::Sound::Gesture from the change's landing frame.  When
        # the keys are a live gesture's line (#gesture_line), the change is
        # that gesture's: journaled at the gesture's first frame with its
        # raw steps (takes replay those, bit for bit; Take#gestures), its
        # undo restores the value from before the gesture, and it changes
        # nothing live (the steps played as they came).  A take replaying
        # the line plays the raw steps it recorded (unless smoothed; see
        # #smooth_gesture).
        def turn_keys(k, keys, curve, point, start_time)
          g = @render_lock.synchronize { @knob_gestures[k.name] }
          per_sample = g&.per_sample || (@transport.whole_notes_per_second / clock_rate)
          gesture = Gesture.from_hash(keys, curve: curve, per_sample: per_sample, rate: clock_rate, bar_length: @transport.bar_length)
          gesture.keys.each { |_, v| warn_clamp(k, v) }
          data = { value: gesture.keys.last[1], keys: gesture.keys.length }

          if g && g.fitted && g.fitted.keys == gesture.keys && g.fitted.curve == gesture.curve
            begin
              @committing_gesture = g
              raw = g.steps.map(&:dup).freeze
              return change(:turn, k.name, g.pos, data: data.merge(gesture: true, raw: raw, epoch: epoch, pos: g.pos)) { |_t|
                @knob_gestures.delete(k.name) if @knob_gestures[k.name].equal?(g)
              }
            ensure
              @committing_gesture = nil
            end
          end

          time = start_time ? start_time.to_r : launch_time(point, [], default: nil)
          knob_change(k, time, data) { |kn, frame, t|
            # (a take replaying a gesture's line: the raw steps it recorded,
            # at the gesture's time, which the take gives the action)
            raw = replayed_gesture(k.name, t)
            if raw
              raw.each { |off, v| kn.set(v, frame: frame + off) }
            else
              play_gesture(kn, gesture, frame)
            end
          }
        end

        # Schedules +gesture+ on knob +kn+ from frame +frame+ (see
        # Gesture#segments).
        def play_gesture(kn, gesture, frame)
          if gesture.curve == :step
            gesture.keys.each { |off, v| kn.set(v, frame: frame + off) }
            return
          end
          (f0, v0), segs = gesture.segments(kn.spec)
          if f0 == 0
            kn.set(v0, frame: frame, smooth: 0)
          else
            # (from where the knob is to the first key)
            kn.ramp_to(v0, frames: f0, frame: frame + 1, curve: gesture.curve.nil? || gesture.curve == :linear ? nil : MB::Sound::Curve[gesture.curve])
          end
          segs.each do |start, frames, va, vb, c|
            kn.ramp_to(vb, frames: frames, frame: frame + start, curve: c, from: va)
          end
        end
        private :play_gesture

        # True if a plain turn of +k+ to +value+ is a live one-step
        # gesture's line (see #gesture_line).
        def gesture_for?(k, value, over, follow, point)
          return false unless value.is_a?(Numeric) && over.nil? && follow.nil? && !point.given?
          g = @render_lock.synchronize { @knob_gestures[k.name] } or return false
          g.steps == [[0, value.to_f]]
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
        # rack's knob names: :space matches :"dub/space") limit the recall
        # to some knobs (a partial recall).  Returns the Changes.
        def recall(name, at: nil, on: nil, in: nil, over: nil, curve: nil, smooth: nil, start_time: nil, only: nil, except: nil)
          point = LaunchPoint.of(binding) or return nil
          names = filter_knob_names(snapshot_knob_names(name), only, except)
          names &= knobs.keys # (knobs of forgotten players are gone)
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

        # Moves knob +name+ to +value+ live, at the next frame to render,
        # without a journal entry: a step of a gesture (a held key in the
        # racks pane, UI::TurnGesture) that #gesture_line then writes as ONE
        # console line (its fitted keyframes), whose turn the take replays
        # from the gesture's first frame with the raw steps (see
        # #turn_keys), so a replay plays what was heard.  Each step is a #turn without +over:+ (the knob's smooth
        # glide).  Values are rounded as the line prints them.  Returns the
        # value.
        def preview_turn(name, value)
          k = knob!(name)
          raise ArgumentError, "Turn #{k.name.inspect} to a real number (got #{value.inspect})" unless value.is_a?(Numeric) && value.real? && value.finite?
          v = Float(GraphNode::Knob.number(k.spec.clamp(value)))
          @render_lock.synchronize {
            f = @frame
            g = @knob_gestures[k.name]
            unless g
              mode, before = k.state_at(f)
              g = @knob_gestures[k.name] = KnobGesture.new(name: k.name, frame: f, pos: @transport.position, before: KnobState.new(mode: mode, value: before), steps: [],
                                                           per_sample: @transport.whole_notes_per_second / clock_rate, fitted: nil)
            end
            off = f - g.frame
            g.steps.last&.first == off ? (g.steps[-1] = [off, v]) : (g.steps << [off, v])
            k.set(v, frame: f)
          }
          v
        end

        # The console line for the live gesture on knob +name+ (see
        # #preview_turn): `turn :"dub/space", 0.42` for one step, else its
        # fitted keyframes (MB::Sound::Gesture.fit: the fewest keys within
        # +tolerance+ of the knob's range), `turn :"dub/space", 0 => 0.32,
        # 1.n8 => 0.4, 1.n4 => 0.62`; stepped knobs (Knob#choose) keep their
        # steps (`curve: :step`).  The take keeps the raw steps (see
        # #turn_keys).  Nil without a gesture.
        def gesture_line(name, tolerance: Gesture::TOLERANCE)
          k = knob!(name)
          g = @render_lock.synchronize { @knob_gestures[k.name] } or return nil
          steps = @render_lock.synchronize { g.steps.map(&:dup) }
          fitted = Gesture.fit(steps, k.spec, tolerance: tolerance, stepped: k.stepped?)
          @render_lock.synchronize { g.fitted = fitted }
          fitted.to_ruby(g.name, per_sample: g.per_sample, rate: clock_rate)
        end

        # The live gestures ({ knob name => KnobGesture }).
        def knob_gestures
          @render_lock.synchronize { @knob_gestures.transform_values(&:dup) }
        end

        # A listing of the knobs: name => "800 Hz (100..8000 exp) cc74 -> 3000".
        def knob_info
          knobs.transform_values { |k|
            parts = [k.value_string, "(#{GraphNode::Knob.number(k.range.begin)}..#{GraphNode::Knob.number(k.range.end)}#{k.spec.curve == :exp ? ' exp' : ''})"]
            parts << "cc#{k.cc}" if k.cc
            parts << 'learning' if k.learning?
            parts << "-> #{GraphNode::Knob.number(MB::M.sigfigs(k.target, 4))}" if k.mode == :ramp
            parts << "following #{k.instance_variable_get(:@segment).label}" if k.mode == :follow
            parts << '(implicit: read before it was defined)' if k.implicit
            parts.join(' ')
          }
        end

        private

        def init_knobs
          @knobs = {}
          @knob_list = [] # (see #advance_knobs)
          @snapshots = {}
          @knob_lock = Mutex.new
          @knob_frame = nil
          @knob_midi = nil
          @knob_gestures = {}
          @committing_gesture = nil
        end

        def knob_suggestion(name, define: false)
          names = @knob_lock.synchronize { @knobs.keys }
          how = define ? "; `knob #{name.inspect}, value, range: lo..hi` makes one" : ''
          return " (no knobs yet#{how})" if names.empty?
          " (knobs: #{names.map(&:inspect).join(', ')}#{how})#{Form.suggest(name, names)}"
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
          list = @knob_list # (a reused copy, taken under the lock; dropouts-2)
          @knob_lock.synchronize { list.clear; @knobs.each_value { |k| list << k } }
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

        # A turn past a knob's range (ux-1 item 30: `turn :drive, 100` on a
        # 0..1 knob "doesn't apply any amplification", silently): checked
        # like every Param value (param-1), so it raises in scripts and
        # specs (MB::Sound.live_error), and live it warns once per knob and
        # the value is limited to the range.
        def warn_clamp(k, value)
          r = k.range
          return if value.between?(r.begin, r.end)
          n = GraphNode::Knob.method(:number)
          desc = k.spec.param.description
          message = "turn #{k.name.inspect}, #{n.(value)}: limited to #{n.(value.to_f.clamp(r.begin, r.end))} (knob #{k.name.inspect} goes #{n.(r.begin)}..#{n.(r.end)}#{"; #{desc}" if desc}; " \
                    "knob #{k.name.inspect}, #{n.(k.spec.default)}, range: #{widened(r, value)} widens it)"
          MB::Sound.live_error(Param::Error.new(message)) unless MB::Sound.live?
          @clamp_warned ||= {}
          return if @clamp_warned[k.name]
          @clamp_warned[k.name] = true
          warn message
        end

        # A typed turn value (3000.hz for a knob declared with 2400.hz, 
        # -6.db for one declared in dB) as the knob's plain number; other
        # values as they are.  (A Pitch is a value here, not a sine to
        # follow, when the knob is a frequency.)
        def knob_value(k, value)
          t = Param.type_of(value)
          # (a gain like -6.db turning a plain-number knob, e.g. a level:
          # the knob holds the Float gain, so set documents print a number
          # its range can read; omnibus17)
          return value.to_f if t == :decibels && k.spec.param.type == :number
          return value if t.nil? || t == :number || t == :node || t == :name || t != k.spec.param.type
          Param.magnitude(value).to_f
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
        # knob names or knob names; a knob name matches the last part of
        # a rack knob's path).
        def filter_knob_names(names, only, except)
          match = ->(n, list) {
            Array(list).any? { |x|
              x = control_name(x.to_sym)
              n == x || (!Name[n].plain? && Name[n].leaf == x)
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
          # (a live gesture's change, landing now: the state from before its first step)
          g = @committing_gesture
          return g.before.dup if g && g.name == subject.name && @knob_gestures[g.name].equal?(g)
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
