require 'set'

module MB
  module Sound
    class Session
      # Named buses with their own effect chains, sends from players, and
      # graphs that read buses and players by name (sidechains).  See
      # design/notes/buses.md.
      #
      #     session.bus(:verb) { |sig| sig.reverb(:hall, mix: 1) }
      #     session.route(:keys, send: { verb: -12.db })
      #     session.feed(:keys, :verb, -6.db, over: 2)
      #     bass.duck(:drums, only: :kick)
      #
      # A bus is a master-like chain (Master::Chain) fed by the players
      # (and buses) routed to it, rendered after them in each span.  Its
      # output goes into the master mix or another bus.  It keeps
      # processing after its senders stop, so tails ring out, and sleeps
      # (no CPU) once its input and output have been quiet for
      # Master::TAIL_QUIET_SECONDS, deciding on a fixed frame grid so its
      # output is the same at any buffer size.
      #
      # Routing belongs to player names, like mutes: each name has a main
      # out (the master, or a bus) and sends, post-fader.  Send levels are
      # unregistered GraphNode::Knobs, so they ramp on exact frames and undo
      # like knob turns.
      #
      # Players and buses render in dependency order (senders before their
      # buses, sources before graphs reading them with GraphNode::BusTap);
      # without buses or readers nothing changes.
      module Buses
        # Frames between the moments a quiet bus may fall asleep (the same
        # grid as idle Synth lanes), so sleeping is the same at any buffer
        # size.
        SLEEP_GRID = Synth::SKIP_GRID

        # The loudest send level (+24 dB).
        MAX_SEND = 16.0

        # (#bus_chain_graphs without buses)
        NO_GRAPHS = [].freeze

        # A bus: +to+ is the bus its output feeds (nil for the master),
        # +chains+ its effect chains (Master::Chain, the newest last), +input+
        # the span's input (one SFloat per channel, nil if nothing was sent),
        # +strip_level+/+strip_ramp+ its mute/solo level (see Strip),
        # +asleep+ true while it isn't processed, +quiet_from+ the session
        # frame where its current quiet stretch began, +wake_at+ a frame to
        # wake on (a chain change landing while it sleeps), and +playing+
        # whether the timeline moved last span (for its clips).
        Bus = Struct.new(
          :name, :to, :chains, :block, :input, :strip_level, :strip_ramp,
          :asleep, :quiet_from, :wake_at, :playing, :frames,
          keyword_init: true
        )

        # A player name's routing: +to+ is the bus its main out feeds (nil
        # for the master), +sends+ a Hash from bus name to the send's level
        # knob (a GraphNode::Knob), +key+ true for a key track (a sidechain
        # line: heard by readers only, never mixed; see #route).
        Route = Struct.new(:to, :sends, :key, keyword_init: true)

        # Undo subjects: a bus's chain, and one send of a player name.
        BusSubject = Data.define(:name)
        SendSubject = Data.define(:name, :bus)

        # A bus around a change, for undo: its chain's block (nil for
        # none), description, and destination.
        BusState = Struct.new(:block, :description, :to, keyword_init: true)

        # Defines (or redefines) bus +name+: its effect chain is built from
        # the block like a master chain (see Master#master: one parameter
        # gets the bus input as a channel bundle, one per channel gets the
        # channels; no block passes the input through), and its output goes
        # to +to:+ (:master, or another bus's name).  A new chain for an
        # existing bus takes over at the launch point (+on:+, +in:+, +at:+;
        # the next bar while anything plays) with the old one's tails
        # spilling over, or crossfading over +fade:+ bars (0 cuts).
        # Returns the Change.
        def bus(name, to: :master, at: nil, on: nil, in: nil, fade: nil, start_time: nil, description: nil, &block)
          raise IOError, 'Session is closed' if @closed
          point = LaunchPoint.of(binding) or return nil
          raise ArgumentError, "Bus names must be Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          raise ArgumentError, "to: must be :master or a bus name (got #{to.inspect})" unless to.is_a?(Symbol)
          to = nil if to == :master
          check_bus_name(to, "bus #{name.inspect}'s to:") if to
          return nil unless @names.claim(name, :bus)

          chain = build_master(block, description: description, label: name.to_s)
          chain.mode, chain.fade = master_mode(fade)
          prepare_bus_chain(name, chain)

          b = nil
          old_to = nil
          created = false
          @render_lock.synchronize { @mutex.synchronize {
            b = @buses[name]
            if b.nil?
              created = true
              b = @buses[name] = Bus.new(
                name: name, to: to, chains: [], block: nil, input: nil,
                strip_level: 1.0, strip_ramp: nil, asleep: false, quiet_from: @frame,
                wake_at: nil, playing: false, frames: nil
              )
            end
            old_to = b.to
            b.to = to
            @bus_order = nil
          } }
          b.strip_level = @render_lock.synchronize { audible_unlocked?(name) ? 1.0 : 0.0 } if created

          unless bus_acyclic?
            @mutex.synchronize { b.to = old_to; @bus_order = nil }
            return MB::Sound.live_error(ArgumentError.new("bus #{name.inspect} to: #{to.inspect} would make a loop of buses"))
          end

          @mutex.synchronize { @bus_defs[name] = [block, to || :master, description].freeze }

          time = start_time ? start_time.to_r : launch_time(point, chain.timeline_nodes)
          c = change(:bus, name, time, data: { description: chain.description, fade: fade, to: to || :master }, graph: chain.chain_graph) { |t|
            start_bus_chain(name, chain, block, t)
          }

          start_thread if @realtime
          c
        end

        # The buses: a Hash from name to a description, e.g.
        # "verb: reverb (to master)" (noting sleep and mutes).
        def bus_info
          list = @mutex.synchronize { @buses.values }
          list.to_h { |b|
            desc = b.chains.last&.description || 'bypass'
            state = b.asleep ? ', asleep' : ''
            state += ', muted' if muted?(b.name)
            [b.name, "#{desc} (to #{b.to || :master}#{state})"]
          }
        end

        # What each bus was last defined with (whether its chain started or
        # still waits; graph documents save them, see GraphIO::SetWriter):
        # name => [block (nil for a plain bus), destination (:master or a
        # bus name), description given (or nil)], in the order the buses
        # were first defined.
        def bus_definitions
          @mutex.synchronize { @buses.keys.to_h { |n| [n, @bus_defs[n]] }.compact }
        end

        # The routing of every player name for saving: name => { to: a bus
        # name or nil (the master), send: { bus => level } }, each level the
        # send's held value (a linear gain), or the name of the Session knob
        # it follows (a Symbol), or the node it follows.
        def route_definitions
          knobs = self.knobs
          @mutex.synchronize { @routes.dup }.transform_values { |r|
            sends = r.sends.transform_values { |k|
              mode, v = k.queued_state
              next v if mode == :hold
              v = v.knob if v.is_a?(GraphNode::Knob::Reader)
              knobs.key(v) || v
            }
            r.key ? { to: nil, send: {}, key: true } : { to: r.to, send: sends }
          }
        end

        # True if player name +name+ is a key track (see #route's +key:+;
        # an armed key track's monitor is one too).
        def key_track?(name)
          @mutex.synchronize { route_of(name)&.key } || false
        end

        # The key track names (see #route).
        def key_tracks
          @mutex.synchronize { @routes.select { |_, r| r.key }.keys }
        end

        # Who reads each source: source name => the names of the players,
        # buses, or :master whose graphs read it (`duck(:pump)`,
        # `bus(:drums, only: :kick)`).
        def bus_readers_of
          out = Hash.new { |h, k| h[k] = [] }
          @mutex.synchronize {
            @bus_readers.each { |owner, keys| keys.each { |k| out[k.is_a?(Array) ? k[0] : k] |= [owner] } }
          }
          out.default_proc = nil
          out
        end

        # The bus names.
        def bus_names
          @mutex.synchronize { @buses.keys }
        end

        # True if +name+ is a bus.
        def bus?(name)
          @mutex.synchronize { @buses.key?(name) }
        end

        # True if any bus is awake (processing), so a render's tail goes on
        # (see PlaybackMethods#render).
        def buses_awake?
          @mutex.synchronize { @buses.each_value.any? { |b| !b.asleep } }
        end

        # Sets the routing of player name +name+ (a track or `bg` name;
        # see the module comment): +to:+ the bus its main out feeds
        # (:master or nil for the master), +send:+ a Hash from bus name to a
        # level (a linear gain such as `-12.db`, 0 for off, or a knob name or
        # Knob to follow).  Applies right away (not journaled: track and
        # `bg` definitions set it); see #feed to change a send while
        # playing.  Returns the name.
        #
        # +key: true+ makes +name+ a key track (SidechainMethods#sidechain;
        # design/notes/dynamics.md): its sound goes nowhere (not the master,
        # buses, sends, stems, CUE, or meters) and only readers hear it
        # (`duck(:pump)`, `bus(:pump)`, `compress(sidechain: :pump)`), so a
        # line of impulses or a muted hat pattern can key a ducker.  A key
        # route takes no to: or send:; +key: false+ makes it an ordinary
        # route again (to the master).
        def route(name, to: :keep, send: nil, key: nil)
          raise ArgumentError, "Player names must be Symbols or Integers (got #{name.inspect})" unless name.is_a?(Symbol) || name.is_a?(Integer)
          raise ArgumentError, "send: takes a Hash from bus name to level (got #{send.inspect})" unless send.nil? || send.is_a?(Hash)
          raise ArgumentError, "key: is true or false (got #{key.inspect})" unless [nil, true, false].include?(key)
          was_key = key_track?(name)
          if (key || (key.nil? && was_key)) && (!(to == :keep || to.nil?) || send&.any?)
            raise ArgumentError, "#{name.inspect} is a key track: its sound goes only to readers (duck(#{name.inspect})), so it takes no to: or send:"
          end
          unless to == :keep
            to = nil if to == :master
            raise ArgumentError, "to: must be :master or a bus name (got #{to.inspect})" unless to.nil? || to.is_a?(Symbol)
            check_bus_name(to, "#{name.inspect}'s to:") if to
          end
          send&.each_key { |k| check_bus_name(k, "#{name.inspect}'s send:") }

          knobs = send&.to_h { |bus, level| [bus, send_knob(name, bus, level)] }

          old = nil
          dropped = nil
          @mutex.synchronize {
            old = @routes[name]
            r = Route.new(to: old&.to, sends: (old&.sends || {}).dup, key: old&.key || false)
            r.to = to unless to == :keep
            r.sends = knobs if knobs
            unless key.nil?
              r.key = key
              if key
                dropped = r.sends.values
                r.to = nil
                r.sends = {}
              end
            end
            @routes[name] = r
            @bus_order = nil
            @key_routes = @routes.each_value.any?(&:key)
          }
          drop_send_knobs(dropped) if dropped && !dropped.empty?

          unless bus_acyclic?
            @mutex.synchronize { old ? @routes[name] = old : @routes.delete(name); @bus_order = nil }
            drop_send_knobs(knobs&.values || [])
            return MB::Sound.live_error(ArgumentError.new("routing #{name.inspect} there would make a loop (a bus can't feed what it reads)"))
          end
          drop_send_knobs(old.sends.values) if knobs && old

          @render_lock.synchronize { apply_strip(nil) } unless @soloed.empty?
          name
        end

        # The routing of every player name: name => { to:, send: { bus =>
        # level } } (levels as linear gains, or "knob(:x)" for follows).
        def routes
          @mutex.synchronize { @routes.dup }.transform_values { |r|
            next { to: nil, key: true } if r.key
            { to: r.to || :master, send: r.sends.transform_values { |k| send_level_value(k) } }
          }
        end

        # Changes the send from player name +name+ to bus +bus+ to +value+
        # (a linear gain such as `-6.db`, 0 for off, or a knob name or node
        # to follow), right away with a short glide (+smooth:+) or at a
        # launch point (+on:+, +in:+, +at:+), over +over:+ (bars, a Duration,
        # or a Length; linear in gain, shaped by +curve:+, from where it is or
        # +from:+).  Journaled (`send :keys lands 9:1`), undoable, and
        # replayed exactly by takes.  Returns the Change.
        def feed(name, bus, value, at: nil, on: nil, in: nil, over: nil, curve: nil, from: nil, smooth: nil, start_time: nil)
          point = LaunchPoint.of(binding) or return nil
          raise ArgumentError, "Player names must be Symbols or Integers (got #{name.inspect})" unless name.is_a?(Symbol) || name.is_a?(Integer)
          check_bus_name(bus, 'feed')
          check_send_level(value)
          if key_track?(name)
            raise ArgumentError, "#{name.inspect} is a key track (heard only by readers such as duck(#{name.inspect})); it has no sends"
          end
          raise ArgumentError, 'from: needs over: (a ramp)' if from && !over
          raise ArgumentError, "from: must be a gain of 0 or more (got #{from.inspect})" unless from.nil? || (from.is_a?(Numeric) && from.real? && from >= 0)

          # The send exists (at its old level) from now on, so the routing
          # order counts it before it lands
          k = @mutex.synchronize { @routes[name]&.sends&.[](bus) }
          unless k
            k = send_knob(name, bus, 0)
            @mutex.synchronize {
              r = (@routes[name] ||= Route.new(to: nil, sends: {}))
              r.sends = r.sends.merge(bus => k)
              @bus_order = nil
            }
            unless bus_acyclic?
              @mutex.synchronize { @routes[name].sends = @routes[name].sends.reject { |b, _| b == bus }; @bus_order = nil }
              return MB::Sound.live_error(ArgumentError.new("feed #{name.inspect} to #{bus.inspect} would make a loop (a bus can't feed what it reads)"))
            end
          end

          time = start_time ? start_time.to_r : launch_time(point, [], default: nil)
          data = { bus: bus }.merge(turn_data(value, over, curve)).merge(from ? { from: from } : {})
          change(:send, name, time, data: data) { |t|
            apply_turn(k, value, @landing_frame || @frame, t, over: over, curve: curve, smooth: smooth, from: from)
          }
        end

        # A node reading bus or player +name+ in graphs (see
        # GraphNode::BusTap): a bundle of the Session's channels, or with
        # +only:+ one channel, the node of that name inside the named
        # track's graph.
        def bus_tap(name, only: nil)
          GraphNode::BusTap.new(name, only: only, channels: @channels, sample_rate: output_open? ? sample_rate : 48000).node
        end

        # Increased before each graph read (a player's buffer, a bus's
        # chain), so BusTap channels know when to start a new read.
        def bus_read_serial
          @bus_read_serial
        end

        # The first frame of the read in progress within the span (see
        # #bus_read_serial).
        def bus_read_offset
          @bus_read_offset
        end

        # The signal of bus or player +name+ (or the node +only+ in its
        # graph) in the span being rendered: an Array of one SFloat per
        # channel (the span's length), or nil if it didn't play.
        def bus_signal(name, only = nil)
          key = only ? [name, only] : name
          @bus_signal_span[key] == @bus_span ? @bus_signals[key] : nil
        end

        # Rebuilds every bus's chain (see Master#reset_master), clearing
        # their tails, at +time+ (whole notes; now if nil).  Called by
        # PlaybackMethods#panic.
        def reset_buses(time: nil)
          list = @mutex.synchronize { @buses.values }
          time = nil if time && time <= @transport.position
          list.each do |b|
            chain = b.chains.last or next
            bus(b.name, to: b.to || :master, on: :now, start_time: time, fade: 0, description: chain.description, &chain.block)
          rescue => e
            raise if @raise_errors
            warn "Could not rebuild bus #{b.name.inspect} (#{e.class}: #{e.message})"
          end
        end

        private

        def init_buses
          @buses = {}
          @bus_defs = {}
          @routes = {}
          @key_routes = false
          @bus_order = nil
          @bus_readers = Hash.new { |h, k| h[k] = ::Set.new }
          @bus_only = Hash.new { |h, k| h[k] = ::Set.new }
          @bus_spied = {}.compare_by_identity
          @bus_signals = {}
          @bus_signal_span = {}
          @bus_span = 0
          @bus_read_serial = 0
          @bus_read_offset = 0
          @bus_only_pos = {}
          @bus_only_pending = {}
          @send_knobs = []
          @bus_cycle_warned = false
          @routed_span = false
          @bus_tapped = ::Set.new
          @bus_sources = ::Set.new
          @stem_shadows = {}
        end

        # True if anything needs the routed render (buses, or graphs that
        # read players or buses).
        def routed?
          !@buses.empty? || !@bus_readers.empty? || @key_routes
        end

        # Raises unless +name+ is a bus.
        def check_bus_name(name, what)
          return if @mutex.synchronize { @buses.key?(name) }
          known = bus_names
          raise ArgumentError, "#{what}: no bus #{name.inspect}#{known.empty? ? ' (define it with `bus :name do |sig| ... end`)' : " (buses: #{known.map(&:inspect).join(', ')})#{Form.suggest(name, known)}"}"
        end

        def check_send_level(value)
          case value
          when Numeric
            unless value.real? && value.finite? && value >= 0 && value <= MAX_SEND
              raise ArgumentError, "Send levels are linear gains from 0 to #{MAX_SEND.round} (write -6.db for -6 dB; got #{value.inspect})"
            end
          when Symbol
            knob!(value)
          else
            raise ArgumentError, "A send level is a gain (e.g. -6.db), a knob name, or a node (got #{value.inspect})" unless value.respond_to?(:sample) && value.respond_to?(:get_sampler)
          end
        end

        # A new level knob for the send from +name+ to +bus+ at +level+ (see
        # #route).
        def send_knob(name, bus, level)
          check_send_level(level)
          rate = output_open? ? sample_rate : 48000
          k = nil
          @render_lock.synchronize {
            k = GraphNode::Knob.new(:"#{name}>#{bus}", 0.0, session: self, sample_rate: rate, frame: @frame, range: 0.0..MAX_SEND)
            if level.is_a?(Numeric)
              k.set(level.to_f, frame: @frame, smooth: 0)
            else
              k.follow(level.is_a?(Symbol) ? knob!(level) : level, frame: @frame, time: @transport.position, transport: @transport)
            end
            @send_knobs << k
          }
          k
        end

        # Stops advancing send level knobs no longer in use (replaced by
        # #route).
        def drop_send_knobs(list)
          return if list.empty?
          @render_lock.synchronize { @send_knobs.reject! { |k| list.any? { |o| o.equal?(k) } } }
        end

        # A send's level for listings: its value, or what it follows.
        def send_level_value(k)
          src = k.following
          src ? GraphNode::Knob.label_of(src) : k.value
        end

        # Binds the BusTaps in +nodes+ (a graph's outputs) to this Session
        # and records what +owner+ (a player name, bus name, or :master)
        # reads, attaching spies for `only:` readers.  Returns false (after
        # MB::Sound.live_error) if the readers would make a loop.
        def bind_bus_taps(nodes, owner)
          taps = nodes.flat_map { |n| [n, *n.graph] }.grep(GraphNode::BusTap::Channel).map(&:original_source).uniq
          return true if taps.empty?

          taps.each { |t| t.bind(self) }
          added = []
          @mutex.synchronize {
            taps.each do |t|
              key = t.only ? [t.source_name, t.only] : t.source_name
              added << key unless @bus_readers[owner].include?(key)
              @bus_readers[owner] << key
              @bus_only[t.source_name] << t.only if t.only
            end
            @bus_order = nil
          }

          unless owner == :master || bus_acyclic?
            @mutex.synchronize { added.each { |k| @bus_readers[owner].delete(k) }; @bus_readers.delete(owner) if @bus_readers[owner].empty?; @bus_order = nil }
            return !!MB::Sound.live_error(ArgumentError.new("#{owner.inspect} reads #{added.map { |k| k.is_a?(Array) ? k[0] : k }.uniq.map(&:inspect).join(', ')}, which #{added.length == 1 ? 'depends' : 'depend'} on #{owner.inspect} (a loop)"))
          end

          # Graphs already playing under a name an `only:` reader names
          taps.select(&:only).each do |t|
            players = @mutex.synchronize { @players.values.select { |p| p.name == t.source_name } + [@stopped[t.source_name]].compact }
            players.each { |p| attach_bus_spies(t.source_name, p.input.nodes) }
          end
          true
        end

        # Attaches spies for `only:` readers of +name+ to the nodes they name
        # in +nodes+ (a graph about to play under +name+).
        def attach_bus_spies(name, nodes)
          onlys = @mutex.synchronize { @bus_only.key?(name) ? @bus_only[name].to_a : [] }
          return if onlys.empty?

          all = nodes.flat_map { |n| [n, *n.graph] }.uniq
          onlys.each do |only|
            node = all.find { |n| bus_named?(n, only) }
            if node.nil?
              warn "#{name.inspect} has no node named #{only.inspect} for a sidechain (a drum voice, or a node given .named(#{only.inspect})); it reads silence"
              next
            end
            spied = (@bus_spied[node] ||= ::Set.new)
            next if spied.include?([name, only])
            spied << [name, only]

            key = [name, only]
            node.spy(handle: [:bus_tap, name, only], phase: :pre) { |count| @bus_only_pending[key] = count }
            node.spy(handle: [:bus_tap, name, only], phase: :post) { |data| bus_only_write(key, data) }
          end
        end

        # True if graph node +n+ is the one `only: name` means.
        def bus_named?(n, name)
          return true if n.is_a?(Drums::Voice) && n.name == name
          n.respond_to?(:named?) && n.named? && n.graph_node_name == name.to_s
        end

        # Writes a spied node's buffer into its `only:` signal (see
        # #attach_bus_spies), at the position of the read in progress.
        def bus_only_write(key, data)
          count = @bus_only_pending.delete(key) || data&.length || 0
          pos = @bus_only_pos[key]
          return if pos.nil? || count == 0

          buf = bus_signal_buffer(key, 1)[0]
          n = MB::M.min(count, buf.length - pos)
          if n > 0 && data
            m = MB::M.min(n, data.length)
            d = data[0...m]
            d = d.real if d.is_a?(Numo::SComplex) || d.is_a?(Numo::DComplex)
            buf[pos...(pos + m)] = d if m > 0
          end
          @bus_only_pos[key] = pos + count
        end

        # The span's signal buffer for +key+ (a name, or [name, only]),
        # zeroed on its first use in a span.
        def bus_signal_buffer(key, channels = @channels)
          return @bus_signals[key] if @bus_signal_span[key] == @bus_span

          count = @bus_span_count
          bufs = @bus_signals[key]
          if bufs && bufs.length == channels && bufs[0].length == count
            bufs.each { |b| b.fill(0) }
          else
            bufs = @bus_signals[key] = Array.new(channels) { Numo::SFloat.zeros(count) }
          end
          @bus_signal_span[key] = @bus_span
          bufs
        end

        # True if a reader reads player or bus +name+ (or a node inside
        # it) this span: it keeps rendering while muted.
        def bus_source?(name)
          @bus_sources.include?(name)
        end

        # True if some reader reads +key+ (a name, or [name, only]).
        def bus_tapped?(key)
          @bus_tapped.include?(key)
        end

        # The span's input of bus +name+ (zeroed on first use), or nil if
        # there is no such bus.
        def bus_input(name)
          b = @bus_span_buses[name] or return nil
          b.input ||= Array.new(@channels) { Numo::SFloat.zeros(@bus_span_count) }
        end

        # The routing of player name +name+ (an armed track's monitor uses
        # its track's), or nil.
        def route_of(name)
          @routes[name] || ((t = Arrangement::Recording.monitored_track(name)) && @routes[t])
        end

        # Before a graph read in the span (a player at +offset+ frames in, a
        # bus segment): readers start a new read there, and `only:` spies of
        # the player write from there.
        def begin_bus_read(offset, name = nil)
          @bus_read_serial += 1
          @bus_read_offset = offset
          return unless name && @bus_only.key?(name)
          @bus_only[name].each { |only| @bus_only_pos[[name, only]] = offset }
        end

        # Every edge of the routing graph: [from, to] name pairs (senders
        # into buses, buses into buses, sources into their readers).
        def bus_edges
          edges = []
          @routes.each do |name, r|
            edges << [name, r.to] if r.to
            r.sends.each_key { |b| edges << [name, b] }
          end
          @buses.each_value { |b| edges << [b.name, b.to] if b.to }
          @bus_readers.each do |owner, keys|
            next if owner == :master
            keys.each { |k| edges << [k.is_a?(Array) ? k[0] : k, owner] }
          end
          edges
        end

        # True if the routing graph has no loop.
        def bus_acyclic?
          @mutex.synchronize { !bus_ranks_for(bus_edges).nil? }
        end

        # The rank (longest path from a source) of every name in +edges+,
        # or nil if there is a loop.
        def bus_ranks_for(edges)
          preds = Hash.new { |h, k| h[k] = [] }
          nodes = ::Set.new
          edges.each { |a, b| preds[b] << a; nodes << a << b }

          ranks = {}
          state = {}
          visit = ->(n) {
            return ranks[n] if state[n] == :done
            return :loop if state[n] == :active
            state[n] = :active
            r = 0
            preds[n].each do |p|
              pr = visit.(p)
              return :loop if pr == :loop
              r = pr + 1 if pr + 1 > r
            end
            state[n] = :done
            ranks[n] = r
          }
          nodes.each { |n| return nil if visit.(n) == :loop }
          ranks
        end

        # The routing order's ranks (cached until routing changes), breaking
        # loops if one slipped through (readers then read silence).
        def bus_ranks
          @mutex.synchronize {
            @bus_order ||= begin
              edges = bus_edges
              ranks = bus_ranks_for(edges)
              if ranks.nil?
                warn 'Bus routing has a loop; some readers read silence' unless @bus_cycle_warned
                @bus_cycle_warned = true
                kept = []
                edges.each { |e| kept << e if bus_ranks_for(kept + [e]) }
                ranks = bus_ranks_for(kept)
              end
              ranks.freeze
            end
          }
        end

        def rank_of(ranks, name)
          ranks[name] || ((t = Arrangement::Recording.monitored_track(name)) && ranks[t]) || 0
        end

        # Renders a span's players and buses in routing order (see the
        # module comment), adding main outs and bus outputs into +mix+.
        # Called by #render_span with the render lock held.
        def render_routed(players, mix, from, to, per_sample, count, frame, playing)
          buses = @mutex.synchronize { @buses.values }
          @bus_span += 1
          @bus_span_count = count
          @bus_span_buses = buses.to_h { |b| [b.name, b] }
          buses.each { |b| b.input = nil }
          # Stems: each track's own copy of every bus it reaches (see
          # #stem_shadow), following its bus's mute
          @stem_shadows.each_value do |list|
            list.each do |bus, sh|
              b = @bus_span_buses[bus]
              sh.input = nil
              sh.strip_level = b ? b.strip_level : 0.0
              sh.strip_ramp = b&.strip_ramp
            end
          end
          @bus_tapped = @mutex.synchronize { @bus_readers.each_value.flat_map(&:to_a).to_set }
          @bus_sources = @bus_tapped.to_set { |k| k.is_a?(Array) ? k[0] : k }
          @send_knobs.each { |k| k.read(frame, count) } unless @send_knobs.empty?
          # Bus and send meters for the terminal UI (UI::BusMeter), while a
          # pane shows them
          @ui_bus_meter = @ui_feed&.bus_meter(self)

          ranks = bus_ranks
          items = players.each_with_index.map { |p, i| [rank_of(ranks, p.name), 0, i, p] } +
            buses.each_with_index.map { |b, i| [ranks[b.name] || 0, 1, i, b] }
          items.sort_by! { |r, kind, i, _| [r, kind, i] }

          parts = @stems ? {} : nil
          prepare_stem_shadows(players, to) if parts
          items.each do |_, kind, _, x|
            if kind == 0
              if parts && route_of(x.name)&.key
                render_player(x, mix, from, to, per_sample, count) # (a key track: no stem)
              elsif parts
                own = Array.new(@channels) { Numo::SFloat.zeros(count) }
                stem = Array.new(@channels) { Numo::SFloat.zeros(count) }
                render_player(x, own, from, to, per_sample, count, stem: stem)
                own.each_with_index { |o, c| mix[c] = mix[c] + o }
                name = stem_name(x)
                parts[name] = parts[name] ? parts[name].each_with_index.map { |a, c| a + stem[c] } : stem
              else
                render_player(x, mix, from, to, per_sample, count)
              end
            else
              render_bus(x, mix, from, to, per_sample, count, frame, playing, parts)
              # Each track's share of this bus, into the track's stem (or its
              # copy of the next bus)
              if parts
                @stem_shadows.each do |track, list|
                  sh = list[x.name] or next
                  stem = (parts[track] ||= Array.new(@channels) { Numo::SFloat.zeros(count) })
                  dest = sh.to ? stem_shadow_input(track, sh.to) : stem
                  render_bus(sh, nil, from, to, per_sample, count, frame, playing, nil, into: dest)
                end
              end
            end
          end

          parts&.each { |name, data| @stems.add(name, @master_gain == 1 ? data : data.map { |d| d * @master_gain }, frame) }
          @ui_bus_meter&.end_span(count)
        end

        # Adds a player's buffer (+data+, after its fades and mute: +ramp+)
        # to its destinations: its main out (+mix+ or a bus), its sends, a
        # reader's signal, and +stem+.  Called by #render_player.
        #
        # A reader's signal hears the player before its mute and solo
        # (+fade+: the fade ramp alone), so soloing a bass keeps it ducking
        # by a muted kick.
        #
        # With stems, +stem+ gets the player's main out if it goes to the
        # master; what it sends or plays into buses goes through its own
        # copies of those buses into its stem (see #stem_shadow), so each
        # stem is the track as heard before the master chain.
        def deliver_player(p, data, ramp, mix, stem, offset, frames, fade: ramp)
          route = route_of(p.name)
          return deliver_key(p, data, offset, frames, fade) if route&.key
          main_bus = route&.to && bus_input(route.to)
          dest = main_bus || mix
          tap = bus_tapped?(p.name) ? bus_signal_buffer(p.name) : nil
          track = stem && stem_name(p)
          meter = @ui_bus_meter
          sends = route ? route.sends.filter_map { |bus, k|
            input = bus_input(bus) or next
            v = k.read(@frame, @bus_span_count)
            if v.is_a?(Numeric) && v == 0
              meter&.send_seen(p.name, bus, 0)
              next
            end
            [input, v, track && stem_shadow_input(track, bus), bus]
          } : []
          if stem && main_bus
            stem = stem_shadow_input(track, route.to)
          end

          dest.each_with_index do |m, c|
            d = data[c % data.length]
            next if d.nil? || d.empty?
            d = d.real if d.is_a?(Numo::SComplex) || d.is_a?(Numo::DComplex)
            len = MB::M.min(d.length, frames)
            raw = d[0...len]
            d = ramp ? raw * ramp[0...len] : raw
            r = offset...(offset + len)
            m[r].inplace + d
            stem[c][r].inplace + d if stem
            tap[c][r].inplace + (fade.equal?(ramp) ? d : (fade ? raw * fade[0...len] : raw)) if tap
            sends.each do |input, v, shadow, bus|
              x = v.is_a?(Numeric) ? (v == 1 ? d : d * v) : d * v[r]
              input[c][r].inplace + x
              shadow[c][r].inplace + x if shadow
              meter&.send_signal(p.name, bus, c, x, v.is_a?(Numeric) ? v : v[r])
            end
          end
        end

        # A key track's buffer (see #route's +key:+) goes only to its
        # readers' signal (after its fades, before its mute, like any
        # player's): no mix, bus, send, stem, or meter.
        def deliver_key(p, data, offset, frames, fade)
          return unless bus_tapped?(p.name)
          tap = bus_signal_buffer(p.name)
          tap.each_with_index do |t, c|
            d = data[c % data.length]
            next if d.nil? || d.empty?
            d = d.real if d.is_a?(Numo::SComplex) || d.is_a?(Numo::DComplex)
            len = MB::M.min(d.length, frames)
            raw = d[0...len]
            t[offset...(offset + len)].inplace + (fade ? raw * fade[0...len] : raw)
          end
        end

        # Renders bus +b+ for the span: wakes it on its first loud input (or
        # a chain change, or an unmute), runs its chains, and adds its output
        # to its destination, its reader signal, and +parts+ (stems).
        #
        # +into+ renders a track's stem copy of the bus (see #stem_shadow)
        # into that Array instead (the track's stem, or its copy of the next
        # bus), with no reader signal or bus stem.
        def render_bus(b, mix, from, to, per_sample, count, frame, playing, parts, into: nil)
          rate = output.sample_rate.to_f
          input = b.input
          s = 0
          e = count
          meter = into ? nil : @ui_bus_meter
          meter&.bus_input(b.name, input)

          # A bus a sidechain reads keeps processing while muted
          read = into.nil? && bus_tapped?(b.name)
          muted = b.strip_level <= 0 && b.strip_ramp.nil? && !read
          if b.asleep || muted
            wake = bus_wake_index(b, input, frame, count)
            if wake.nil? || muted
              b.asleep = true
              b.wake_at = nil if b.wake_at && b.wake_at < frame + count
              bus_read_shared(b, frame + count)
              return
            end
            s = wake
            b.asleep = false
            b.wake_at = nil
            b.quiet_from = frame + s
            # Clips and tempo-synced nodes in the chain catch up with the
            # timeline, as players do when they wake
            pos = from + s * per_sample
            b.chains.each { |c| c.timeline_nodes.each { |n| n.start_at(pos, origin: c.start, launch: c.launch, transport: @transport) } if c.started }
          end

          # A mute ramp ending in this span: the bus stops on its last frame
          if b.strip_ramp && b.strip_ramp.to <= 0 && !read
            silent_from = b.strip_ramp.start + b.strip_ramp.length - frame
            e = MB::M.clamp(silent_from, s, count)
          end

          # Keep clips in the chains on the timeline, which pauses while idle
          resync = (playing && !b.playing)
          b.playing = playing
          pos0 = from + s * per_sample
          b.chains.each do |c|
            c.timeline_nodes.each { |n| n.start_at(pos0, origin: c.start, launch: c.launch, transport: @transport) } if resync && c.started && c.feeding
            c.timeline_nodes.each(&:pause_timeline) unless playing
          end

          quiet = (Master::TAIL_QUIET_SECONDS * rate).round
          dest = into || (b.to ? (bus_input(b.to) || mix) : mix)
          tap = read ? bus_signal_buffer(b.name) : nil
          stem = parts && @stems.buses ? Array.new(@channels) { Numo::SFloat.zeros(count) } : nil

          p0 = s
          while p0 < e
            f = frame + p0
            if f % SLEEP_GRID == 0 && f - b.quiet_from >= quiet && bus_settled?(b)
              b.asleep = true
              break
            end

            # Split at the first grid frame where it could fall asleep
            g = MB::M.max(f + 1, b.quiet_from + quiet)
            g = ((g + SLEEP_GRID - 1) / SLEEP_GRID) * SLEEP_GRID
            p1 = g < frame + e ? g - frame : e

            out = run_bus_chains(b, input, p0, p1, from, per_sample, rate)
            track_bus_quiet(b, input, out, p0, p1, frame)

            ramp = ramp_levels(b, :strip_level, :strip_ramp, frame + p0, p1 - p0)
            r = p0...p1
            out.each_with_index do |o, c|
              tap[c][r].inplace + o if tap # (readers hear it before its mute)
              o.inplace * ramp if ramp
              dest[c][r].inplace + o
              stem[c][r].inplace + o if stem
              meter&.bus_output(b.name, c, o)
            end
            p0 = p1
          end

          if e < count && !b.asleep
            b.strip_level = 0.0
            b.strip_ramp = nil
            b.asleep = true
          end

          # Frames it slept through after p0 (falling asleep, a mute ramp's end)
          bus_read_shared(b, frame + count)

          if stem
            key = b.name.to_s.gsub(%r{[/\\\0]}, '_')
            parts[key] = parts[key] ? parts[key].each_with_index.map { |a, c| a + stem[c] } : stem
          end
        end

        # Makes the stem copies of buses (see #stem_shadow) that +players+
        # will feed this span before any of them renders (the sends
        # #deliver_player would make them for), so a copy's branches of
        # nodes it shares with players start on the span's first frame: made
        # while delivering, after a player had read the span, a copy of
        # `bus(:fx) { |sig| sig * lfo }` read the LFO a span ahead (0.039
        # off in a 0.25 stem, fixes-13).
        def prepare_stem_shadows(players, to)
          players.each do |p|
            next if p.start >= to

            route = route_of(p.name) or next
            track = stem_name(p)
            stem_shadow(track, route.to) if route.to && @bus_span_buses.key?(route.to)
            route.sends.each do |bus, k|
              next unless @bus_span_buses.key?(bus)
              v = k.read(@frame, @bus_span_count)
              next if v.is_a?(Numeric) && v == 0

              stem_shadow(track, bus)
            end
          end
        end

        # The input of track stem +track+'s copy of bus +bus+ this span
        # (see #stem_shadow), zeroed on first use.
        def stem_shadow_input(track, bus)
          sh = stem_shadow(track, bus) or return nil
          sh.input ||= Array.new(@channels) { Numo::SFloat.zeros(@bus_span_count) }
        end

        # A stem's own copy of bus +bus+ (and, through +to+, of the buses it
        # feeds): a Bus with a chain built from the bus's block, fed only
        # that track's sends, so its stem holds the track as heard in the
        # mix, bus effects included (maintainer, 2026-10-13: "Use final
        # versions of stems through all non-mastering processing").  Made
        # when the track first sends to the bus during a stems render.
        def stem_shadow(track, bus)
          list = (@stem_shadows[track] ||= {})
          return list[bus] if list.key?(bus)

          b = @bus_span_buses[bus] or return nil
          # The newest chain (a swap still waiting for a later span: the one
          # playing now)
          chain = b.chains.last
          chain = b.chains.reverse.find(&:started) if chain && !chain.started && chain.start > @transport.position
          block = chain&.block
          sh = Bus.new(
            name: bus, to: b.to, chains: [], block: block, input: nil,
            strip_level: b.strip_level, strip_ramp: b.strip_ramp, asleep: false, quiet_from: @frame,
            wake_at: nil, playing: b.playing, frames: nil
          )
          # (built on the render thread: commands in the block use this Session)
          c = Session.with_context(session: self) { build_master(block, description: chain&.description, label: bus.to_s) }
          prepare_bus_chain(bus, c)
          start_master_chain(c, @transport.position)
          sh.chains << c
          list[bus] = sh
          stem_shadow(track, b.to) if b.to
          sh
        end

        # Where a sleeping bus wakes in this span: its first input frame at
        # or above Master::TAIL_THRESHOLD, an unmute ramp's start, or a chain
        # change's landing frame; nil to keep sleeping.
        def bus_wake_index(b, input, frame, count)
          candidates = []
          if b.strip_level <= 0
            # Muted: only the unmute ramp's start wakes it (input before it
            # is dropped, whatever the buffer size)
            return nil unless b.strip_ramp && b.strip_ramp.to > 0
            w = MB::M.max(b.strip_ramp.start - frame, 0)
            return w < count ? w : nil
          end
          candidates << MB::M.max(b.wake_at - frame, 0) if b.wake_at
          if input
            input.each do |x|
              idx = x.abs.ge(Master::TAIL_THRESHOLD).where
              candidates << idx[0] if idx.length > 0
            end
          end
          w = candidates.min
          w && w < count ? w : nil
        end

        # True if bus +b+ has one chain running with no switch in progress
        # (a bus mid-switch keeps processing).
        def bus_settled?(b)
          b.chains.length <= 1 && b.chains.all? { |c| c.started && c.gain_step == 0 }
        end

        # Moves bus +b+'s quiet stretch past any loud input or output frame
        # in [+p0+, +p1+) of the span starting at session frame +frame+.
        def track_bus_quiet(b, input, out, p0, p1, frame)
          last = nil
          [*(input ? input.map { |x| x[p0...p1] } : []), *out].each do |x|
            idx = x.abs.ge(Master::TAIL_THRESHOLD).where
            last = idx[-1] if idx.length > 0 && (last.nil? || idx[-1] > last)
          end
          b.quiet_from = MB::M.max(b.quiet_from, frame + p0 + last + 1) if last
        end

        # Runs bus +b+'s chains over frames [+p0+, +p1+) of the span and
        # returns their output (one SFloat per channel).
        def run_bus_chains(b, input, p0, p1, from, per_sample, rate)
          n = p1 - p0
          chains = @mutex.synchronize { b.chains.dup }
          seg = input ? input.map { |x| x[p0...p1] } : Array.new(@channels) { Numo::SFloat.zeros(n) }
          out = Array.new(@channels) { Numo::SFloat.zeros(n) }

          if chains.empty?
            seg.each_with_index { |x, c| out[c].inplace + x }
            return out
          end

          seg_from = from + p0 * per_sample
          activate_master(chains, seg_from, from + p1 * per_sample, per_sample, rate)
          # Shared branches catch up with frames the chains didn't read
          # (asleep, or not started yet) before the segment
          bus_read_shared(b, @frame + p0, chains)
          begin_bus_read(p0)
          chains.each { |c| render_master_chain(c, seg, out, n, rate) }
          chains.each { |c| c.read_to = @frame + p1 if c.started }

          @mutex.synchronize {
            chains.each { |c| b.chains.delete(c) if master_chain_done?(c, b.chains) }
          }
          out
        end

        # Reads the branches of shared nodes (see Strip#asleep_reads) of bus
        # +b+'s started chains (or +chains+) from where each read up to (the
        # span's first frame for a chain starting in this span) to session
        # frame +upto+, like a sleeping player: a bus sleeps (nothing sent,
        # or muted) and runs in segments of a span, and a chain starting
        # later in a span skips the segments before it, so before fixes-13 a
        # chain sharing a node with a player (`lfo = 3.hz.lfo; bg :a, lfo;
        # bus(:fx) { |sig| sig * lfo }`) read it late after sleeping, and
        # raised BranchBufferOverflow after a second.  The chains' own nodes
        # still sleep.
        def bus_read_shared(b, upto, chains = nil)
          chains ||= @mutex.synchronize { b.chains.dup }
          chains.each do |c|
            next unless c.started && !c.bypass?

            read_while_asleep(c.chain_graph, upto - (c.read_to || @frame))
            c.read_to = upto
          end
        end

        # The ChainGraphs of every bus chain that isn't a bypass (only those
        # that haven't started with +waiting+), stem copies' included, for Strip#span_graphs and
        # Strip#catch_up_waiting (fixes-13).
        def bus_chain_graphs(waiting: false)
          return NO_GRAPHS if @buses.empty?

          list = []
          add = ->(b) { b.chains.each { |c| list << c.chain_graph unless c.bypass? || (waiting && c.started) } }
          @mutex.synchronize { @buses.each_value(&add) }
          @stem_shadows.each_value { |l| l.each_value(&add) } # (stems renders)
          list
        end

        # Prepares a chain built for bus +name+: binds its readers and
        # installs its plans.
        def prepare_bus_chain(name, chain)
          return if chain.bypass?
          bind_bus_taps(chain.nodes, name) or raise ArgumentError, "bus #{name.inspect} reads itself"
          Plan.install(chain.nodes.uniq)
        end

        # Hands a chain built by #bus to bus +name+ (applied by the change
        # queue), like Master#start_master.
        def start_bus_chain(name, chain, block, time)
          @mutex.synchronize {
            b = @buses[name] or raise "No bus #{name.inspect}"
            if b.chains.none?(&:started)
              b.chains.unshift(build_master(nil, label: name.to_s).tap { |c| start_master_chain(c, @transport.position) })
            end
            b.chains.reject! { |c| !c.started }
            chain.start = time
            b.chains << chain
            b.block = block
            if b.asleep
              b.wake_at = @landing_frame || @frame
            end
          }

          # Stem copies of the bus switch chains with it
          @stem_shadows.each_value do |list|
            sh = list[name] or next
            c = Session.with_context(session: self) { build_master(block, description: chain.description, label: name.to_s) }
            prepare_bus_chain(name, c)
            c.mode, c.fade = chain.mode, chain.fade
            c.start = time
            sh.chains.reject! { |x| !x.started }
            sh.chains << c
            sh.wake_at = @landing_frame || @frame if sh.asleep
          end
        end

        # --- Overrides (Strip, Undo, Seeks) ---

        # Solo in place through the routing (see design/notes/buses.md): a
        # soloed track keeps the buses it feeds audible, and a soloed bus
        # keeps what feeds it audible.
        def audible_unlocked?(name)
          return super if @soloed.empty? || (@buses.empty? && @routes.empty?)
          track = Arrangement::Recording.monitored_track(name)
          return false if @muted.include?(name) || (track && @muted.include?(track))
          return true if super
          reach = solo_reach
          reach.include?(name) || (!track.nil? && reach.include?(track))
        end

        # Names audible because of a solo elsewhere in the routing: buses
        # downstream of a soloed name, and names upstream of a soloed bus.
        # (Called with or without @mutex held: copies without locking.)
        def solo_reach
          edges = []
          @routes.dup.each { |name, r| edges << [name, r.to] if r.to; r.sends.each_key { |b| edges << [name, b] } }
          @buses.dup.each_value { |b| edges << [b.name, b.to] if b.to }
          down = Hash.new { |h, k| h[k] = [] }
          up = Hash.new { |h, k| h[k] = [] }
          edges.each { |a, b| down[a] << b; up[b] << a }

          reach = ::Set.new
          walk = ->(start, map) {
            stack = [start]
            until stack.empty?
              map[stack.pop].each { |n| stack << n if reach.add?(n) }
            end
          }
          @soloed.each { |s| walk.(s, down); walk.(s, up) }
          reach
        end

        # Strip ramps for buses too.
        def apply_strip(fade)
          super
          return if @buses.empty?

          frame = @landing_frame || @frame
          rate = output.sample_rate.to_f
          length = fade ? fade_frames(fade, rate) : MB::M.max((Fades::DECLICK_SECONDS * rate).round, 1)
          @mutex.synchronize { @buses.values }.each do |b|
            target = audible_unlocked?(b.name) ? 1.0 : 0.0
            current = b.strip_ramp ? b.strip_ramp.to : b.strip_level
            next if current == target
            level = b.strip_ramp ? b.strip_ramp.at(frame) : b.strip_level
            b.strip_ramp = Fades::Ramp.new(level, target, frame, length)
          end
        end

        def snapshot_subject(c)
          return BusSubject.new(c.subject) if c.kind == :bus
          return SendSubject.new(c.subject, c.entry.data[:bus]) if c.kind == :send
          super
        end

        def undo_snapshot(subject)
          case subject
          when BusSubject
            b = @mutex.synchronize { @buses[subject.name] }
            chain = b&.chains&.last
            BusState.new(block: b&.block, description: chain&.description || 'bypass', to: b&.to)
          when SendSubject
            k = @mutex.synchronize { @routes[subject.name]&.sends&.[](subject.bus) }
            return nil unless k
            mode, value = k.state_at(@landing_frame || @frame)
            Knobs::KnobState.new(mode: mode, value: value)
          else
            super
          end
        end

        def restore_change(subject, original, time)
          case subject
          when BusSubject
            state = original.before
            chain = build_master(state&.block, description: state&.description, label: subject.name.to_s)
            prepare_bus_chain(subject.name, chain)
            change(:bus, subject.name, time, data: { description: state&.description, to: state&.to || :master }, undoes: original.seq, graph: chain.chain_graph) { |t|
              @mutex.synchronize { b = @buses[subject.name]; b.to = state&.to if b; @bus_order = nil }
              start_bus_chain(subject.name, chain, state&.block, t)
            }
          when SendSubject
            state = original.before
            change(:send, subject.name, time, data: { bus: subject.bus }, undoes: original.seq) { |_t|
              k = @mutex.synchronize { @routes[subject.name]&.sends&.[](subject.bus) }
              if k && state
                frame = @landing_frame || @frame
                state.mode == :follow ? k.refollow(state.value, frame: frame) : k.set(state.value, frame: frame)
              end
            }
          else
            super
          end
        end
      end
    end
  end
end
