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

        # The MIDI::Stream knobs listen to for controllers (#learn, cc:),
        # or nil until set (the console sets live MIDI input).
        attr_accessor :knob_midi

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

        # Moves knob +name+ at the launch point (+on:+, +in:+, +at:+; see
        # LaunchPoint; right away by default, like mutes): to +value+ (a
        # number, limited to the knob's range; gliding over the knob's
        # +smooth:+ time, or +smooth:+ seconds here), over +over:+ (bars, a
        # Duration, or a Length) shaped by +curve:+ (a Curve name or
        # MB::Sound::Curve) in the knob's scale, or following a graph node
        # (+value+ or +follow:+ a node or another knob's name) until it is
        # turned again.  Returns the Change (see Changes#change).
        def turn(name, value = nil, at: nil, on: nil, in: nil, over: nil, curve: nil, follow: nil, smooth: nil, start_time: nil)
          point = LaunchPoint.of(binding) or return nil
          k = knob!(name)
          value = follow unless follow.nil?
          raise ArgumentError, "Turn #{k.name.inspect} to a number or a node (got nil)" if value.nil?
          check_turn_value(k, value)

          time = start_time ? start_time.to_r : launch_time(point, [], default: nil)
          knob_change(k, time, turn_data(value, over, curve)) { |kn, frame, t|
            apply_turn(kn, value, frame, t, over: over, curve: curve, smooth: smooth)
          }
        end

        # Remembers every knob's value (or where it is heading, while it
        # ramps) as snapshot +name+, when the launch point arrives (now by
        # default).  Returns the Change.
        def snap(name, at: nil, on: nil, in: nil, start_time: nil)
          point = LaunchPoint.of(binding) or return nil
          raise ArgumentError, "Snapshot names must be Symbols (got #{name.inspect})" unless name.is_a?(Symbol)

          time = start_time ? start_time.to_r : launch_time(point, [], default: nil)
          change(:snap, name, time, data: {}) { |_t|
            frame = @landing_frame || @frame
            values = knobs.transform_values { |k| st = k.state_at(frame); st[0] == :follow ? k.value : st[1] }
            @knob_lock.synchronize { @snapshots[name] = values.freeze }
          }
        end

        # The snapshots (a Hash from name to a Hash of knob values).
        def snapshots
          @knob_lock.synchronize { @snapshots.dup }
        end

        # Turns every knob in snapshot +name+ back to its value there (see
        # #turn for the options).  Returns the Changes.
        def recall(name, at: nil, on: nil, in: nil, over: nil, curve: nil, smooth: nil, start_time: nil)
          point = LaunchPoint.of(binding) or return nil
          names = snapshot_knob_names(name)
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
          names.map { |n|
            k = knob!(n)
            raise ArgumentError, "Knob #{n.inspect} can't crossfade by itself" if source.is_a?(GraphNode::Knob) && source.equal?(k)

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
        # GraphNode::Knob#listen for pickup and jump takeover).  Returns the
        # knob.
        def learn(name, stream: nil)
          k = knob!(name)
          stream ||= @knob_midi
          raise ArgumentError, 'No MIDI stream for knobs (set Session#knob_midi)' if stream.nil? && k.listening.nil?
          k.listen(stream) if stream && (k.listening.nil? || !stream.equal?(@knob_midi))
          k.learn
        end

        # Makes knob +name+ follow MIDI controller +cc+ on #knob_midi (or
        # +stream+).  Returns the knob.
        def bind_cc(name, cc, stream: nil)
          k = knob!(name)
          stream ||= @knob_midi
          raise ArgumentError, 'No MIDI stream for knobs (set Session#knob_midi)' if stream.nil? && k.listening.nil?
          k.listen(stream) if stream && k.listening.nil?
          k.cc = cc
          k
        end

        # A listing of the knobs: name => "800 Hz (100..8000 exp) cc74 -> 3000".
        def knob_info
          knobs.transform_values { |k|
            parts = [k.value_string, "(#{MB::M.sigfigs(k.range.begin, 4)}..#{MB::M.sigfigs(k.range.end, 4)}#{k.spec.curve == :exp ? ' exp' : ''})"]
            parts << "cc#{k.cc}" if k.cc
            parts << 'learning' if k.learning?
            parts << "-> #{MB::M.sigfigs(k.target, 4)}" if k.mode == :ramp
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

        # Journal data for a turn.
        def turn_data(value, over, curve)
          what = value.is_a?(Numeric) ? { value: value } : { follow: value.is_a?(Symbol) ? "knob(#{value.inspect})" : GraphNode::Knob.label_of(value) }
          what.merge({ over: over, curve: curve }.compact)
        end

        # Applies a turn to knob +k+ on frame +frame+ (landing position +t+).
        def apply_turn(k, value, frame, t, over:, curve:, smooth:)
          value = knob!(value) if value.is_a?(Symbol)

          if value.is_a?(Numeric)
            if over
              k.ramp_to(value, frames: knob_frames(over), frame: frame, curve: curve)
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
