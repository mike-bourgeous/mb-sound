module MB
  module Sound
    class Session
      # Warms what a change starts before it lands (dropouts-2,
      # 2026-10-28), so YJIT compiles its code where the command runs (the
      # console, or the scheduler thread for scheduled blocks) instead of
      # on the render thread in the buffer where the change lands.
      #
      # The maintainer: "Creating a new bus causes dropouts."  Measured
      # (offline Session, 256-frame buffers, a dnb_reese track and a pad
      # playing, YJIT): the landing buffer of `bus(:verb) { |sig|
      # sig.reverb(:hall, mix: 1) }` took 65-100 ms, 93% of it YJIT
      # compiling the reverb, the routed render, and the bus chain's
      # bookkeeping, against a steady worst buffer of ~14 ms; a master
      # chain 46 ms, `bg` of a new preset graph 168 ms.  Without YJIT the
      # same buffer took ~4 ms.
      #
      # A warm-up builds a copy of what the change starts in a sandbox
      # Session (the session's buffer size, channels, rate, tempo, meter,
      # copies of its knobs and clocks; see #warm_sandbox), plays it there
      # for WARM_BUFFERS buffers with stand-in players (noise sent to a
      # bus and played into it, or under a master chain), and drops it:
      # - a bus chain (Buses#bus): the copy built from the bus's block;
      # - a master chain (Master#master): the block and preset again;
      # - a graph (#add, from PlaybackMethods#bg and tracks): a track's
      #   patch built again with the clip (Arrangement#start_track passes
      #   it as +warm:+), else a copy of the graph from its recipe
      #   (GraphNode::Recipe#to_ruby loaded by GraphIO.load).
      # The copy plays only if it shares no node with the live chain or
      # graph (a node captured by the block would be advanced by the
      # sandbox); otherwise it is only built.  Building draws seeds from a
      # root generator of the warming thread's own
      # (Internal.with_private_rng), so seeds drawn live are unchanged and
      # a scene built on the scheduler thread meanwhile draws the seeds it
      # would have; the live graphs and the session are never touched, so
      # renders and takes play the same samples with or without warming.
      #
      # The warm-up runs on its own thread at WARM_PRIORITY (like the
      # scheduler's, below the render thread's) joined by the caller, with
      # major GCs held off (GCQuiet), and never while the caller holds the
      # render lock.  What a warm-up compiles depends only on code paths,
      # so a change whose kind and node classes were warmed before in this
      # process (Warming.signature) isn't warmed again.
      #
      # On (#warm_changes :auto, the default) for realtime sessions with
      # YJIT running; `session.warm_changes = true` warms offline or
      # without YJIT too (measurements, specs), false never;
      # MB_SOUND_WARM=0 turns :auto off.  #warmed lists the last warm-ups.
      #
      # New graphs (#add: `bg`, tracks, scenes) issued at the console of a
      # realtime session warm in the background (session-2, the
      # maintainer's "In background", 2026-10-30): the command returns at
      # once with its change queued, held (a WarmHold, one per console
      # command, so a scene's tracks land together) until the warm-up
      # thread is done; a change whose time passed meanwhile lands at its
      # launch point's next alignment (the next bar, say; `on: :now` the
      # next buffer).  Scheduled blocks, buses, and master chains still
      # join their warm-ups (blocks run ahead on the scheduler thread, and
      # skip a warm-up they lack the time for).  #warm_background (:auto:
      # realtime sessions; true for specs, false never) decides.
      module Warming
        # Buffers a warm-up plays (enough for MB::Sound::JIT's call
        # threshold, 5, with room for code that runs every other buffer).
        WARM_BUFFERS = 16

        # Rounds of a warm-up, each in a new sandbox.  Code that runs once
        # per object or per session (lazy setup, a node's first buffer, a
        # bus's creation) runs before its method has been called often
        # enough to compile, so one round leaves those branches to compile
        # live, in the hot method, where the change lands; a second round
        # compiles them (hall bus landing: 23 -> ms with two).
        WARM_ROUNDS = 2

        # Bars a graph's warm-up plays after it lands, at least (see
        # #warm_round).
        GRAPH_BARS = 1/2r

        # Buffers a warm-up plays before its change lands (see #warm).
        WARM_LEAD = 6

        # The warming thread's Ruby priority (the scheduler thread's;
        # the render thread runs at Session::RENDER_THREAD_PRIORITY).
        WARM_PRIORITY = -3

        # The stand-in players' level (noise at -20 dB).
        WARM_LEVEL = 0.1

        # How many warm-ups #warmed keeps.
        WARM_LOG = 32

        # False when MB_SOUND_WARM turns :auto warming off.
        AUTO = !%w[0 false off no].include?(ENV['MB_SOUND_WARM'].to_s.downcase)

        # One warm-up: its +kind+ (:bus, :master, :graph), the bus or
        # player +name+, milliseconds spent, and the +result+: :played,
        # :built (the copy shares nodes with the live one), :known (warmed
        # before), :skipped (a scheduled block without the time for it),
        # :failed (+reason+ says why; the change lands anyway).
        Warm = Data.define(:kind, :name, :ms, :result, :reason) do
          def to_s
            "warm #{kind} #{name.inspect}: #{result}#{" (#{reason})" if reason} #{ms.round(1)} ms"
          end
        end

        # The changes one console command queued while its graphs warm in
        # the background (see Warming): released, each change re-timed if
        # its time has passed, once every warm-up thread added to it is
        # done.
        class WarmHold
          def initialize
            @lock = Mutex.new
            @threads = 0
            @changes = [] # [Change, retime Proc]
            @released = false
          end

          # True once released (the changes may land).
          def released?
            @released
          end

          # Counts a warm-up thread started for this hold (held again if an
          # earlier one had released it).
          def started!
            @lock.synchronize { @threads += 1; @released = false }
          end

          # Notes that a warm-up thread finished; true if it was the last.
          def finished!
            @lock.synchronize { (@threads -= 1) == 0 }
          end

          # Adds change +c+ (with +retime+, a Proc giving its landing time
          # if its time has passed when released).
          def hold(c, retime)
            @lock.synchronize { @changes << [c, retime] }
          end

          # The held changes and their retime Procs.
          def changes
            @lock.synchronize { @changes.dup }
          end

          # Marks the hold released (see Session#release_warm_hold).
          def release!
            @released = true
          end
        end

        @signatures = {}
        @signature_lock = Mutex.new
        @always = false

        class << self
          # A signature of what a warm-up of +kind+ compiles: the kind, the
          # buffer size, and the classes of +nodes+' graphs.
          def signature(kind, buffer_size, nodes)
            classes = {}
            Array(nodes).each { |n| [n, *n.graph].each { |x| classes[x.class] = true unless x.is_a?(Numeric) } }
            [kind, buffer_size, classes.keys.map(&:name).sort].hash
          end

          # True if +sig+ was warmed before (and notes it as warmed).
          def known!(sig)
            @signature_lock.synchronize {
              next true if @signatures[sig]
              @signatures[sig] = true
              false
            }
          end

          # Forgets every warmed signature (for specs).
          def forget!
            @signature_lock.synchronize { @signatures.clear }
          end

          # True makes every session warm every change, even ones warmed
          # before and scheduled blocks without the time (session fuzz's
          # :warm relation and measurements; false by default).
          attr_accessor :always
        end

        # Whether changes are warmed before they land: :auto (realtime
        # sessions with YJIT running, unless MB_SOUND_WARM=0), true, or
        # false (see Warming).
        attr_reader :warm_changes

        # Sets #warm_changes.
        def warm_changes=(value)
          raise ArgumentError, "warm_changes must be :auto, true, or false (got #{value.inspect})" unless [:auto, true, false].include?(value)
          @warm_changes = value
        end

        # True if this session warms changes now (see #warm_changes).
        def warming?
          return false if @sandbox
          return true if Warming.always
          case @warm_changes
          when true then true
          when false then false
          else AUTO && @realtime && defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
          end
        end

        # Whether new graphs from console commands warm in the background
        # (see Warming): :auto (realtime sessions), true, or false.
        attr_reader :warm_background

        # Sets #warm_background.
        def warm_background=(value)
          raise ArgumentError, "warm_background must be :auto, true, or false (got #{value.inspect})" unless [:auto, true, false].include?(value)
          @warm_background = value
        end

        # The last warm-ups (Warm values, oldest first).
        def warmed
          @warm_lock.synchronize { @warm_log.dup }
        end

        # A throwaway Session for warm-ups and rehearsals: this session's
        # tempo, meter, channels, rate, and buffer size, and copies of its
        # knobs (at their values) and clocks; never warming itself.
        def warm_sandbox
          t = @transport
          transport = Sequence::Transport.new(bpm: t.bpm, bar_length: t.bar_length)
          output = NullOutput.new(channels: @channels, sample_rate: sample_rate, buffer_size: buffer_size, sleep: false)
          box = Session.new(output: output, transport: transport, channels: @channels, buffer_size: buffer_size, realtime: false, raise_errors: true, master_gain: 1)
          box.send(:sandbox!)
          knobs.each do |name, k|
            sp = k.spec
            box.knob(name, k.value, range: sp.range, curve: sp.curve, unit: sp.unit, takeover: sp.takeover, smooth: sp.smooth)
          end
          box
        end

        private

        def init_warming
          @sandbox = false
          @warm_changes = :auto
          @warm_log = []
          @warm_lock = Mutex.new
          @warm_background = :auto
        end

        # Marks this session as a sandbox, which never warms (see
        # #warm_sandbox).
        def sandbox!
          @sandbox = true
          @warm_changes = false
        end

        # Warms bus +name+'s new chain (built from +block+ as +chain+)
        # before it lands, expected at +at+ (see Warming).
        def warm_bus_chain(name, block, chain, at)
          return if chain.bypass? || !warming?
          warm(:bus, name, chain.nodes, at) { |box, land, later, live|
            box.bus(name, start_time: land, &block)
            next :built if warm_shares?(pending_nodes(box, :bus), live)
            # (a new bus runs on silence until something is sent to it)
            box.add(warm_noise, name: :warm_to, start_time: later, to: name)
            box.add(warm_noise, name: :warm_send, start_time: later, send: { name => 0.5 })
            # (and a send's change landing: a feed usually follows a new bus)
            box.feed(:warm_to, name, 0.5, start_time: later + box.transport.whole_notes_of(WARM_BUFFERS / 4 * Rational(box.buffer_size, box.sample_rate)))
            :played
          }
        end

        # Warms a new master +chain+ (from +block+ and +preset+) before it
        # lands, expected at +at+ (see Warming).
        def warm_master_chain(block, preset, chain, at)
          return if chain.bypass? || !warming?
          warm(:master, :master, chain.nodes, at) { |box, land, _, live|
            box.master(preset, start_time: land, &block)
            next :built if warm_shares?(pending_nodes(box, :master), live)
            box.add(warm_noise, name: :warm_mix, start_time: 0r)
            :played
          }
        end

        # Warms graph +nodes+ (the output nodes of a graph #add is about to
        # start as +name+) before it lands, expected at +at+, playing a
        # copy built by +copy+ (a Proc; see Warming), else one from the
        # graph's recipe.
        #
        # With +background+ (a WarmHold), a warm-up that runs (not one
        # known or skipped) runs on its own thread, counted in the hold;
        # returns the hold then, else nil.
        def warm_graph(name, nodes, copy, at, background: nil)
          return unless warming?
          w = warm(:graph, name, nodes, at, background: background) { |box, land, _, live|
            built = copy ? copy.call : recipe_copy(nodes)
            next [:failed, 'no recipe'] if built.nil?
            graph = Playable.graph(built, sample_rate: box.sample_rate)
            next :built if warm_shares?(graph.nodes.flat_map { |n| [n, *n.graph] }, live)
            box.add(warm_noise, name: :warm_other, start_time: 0r)
            box.add(graph, name: name.is_a?(Symbol) ? name : :warm, start_time: land)
            :played
          }
          w.equal?(background) ? background : nil
        end

        # The WarmHold for a new graph #add starts now, or nil to warm it
        # where the command runs (see Warming): the console command's hold
        # (one per command) on a session that warms in the background,
        # outside scheduled blocks and replays.
        def warm_hold_for_add
          return nil unless warming?
          return nil unless @warm_background == true || (@warm_background == :auto && @realtime)
          context = Session.context
          return nil if context&.time_for(self) || context&.replaying? || context&.batch
          group = context&.command
          return WarmHold.new unless group && group.session.equal?(self)
          group.warm_hold ||= WarmHold.new
        end

        # Lets the changes held by +hold+ land (on the warm-up thread, when
        # its last warm-up is done): a change whose time has passed is
        # re-timed by its Proc (the launch point's next alignment from now).
        def release_warm_hold(hold)
          @render_lock.synchronize {
            hold.changes.each do |c, retime|
              next unless @changes.include?(c) # (cancelled or undone meanwhile)
              next unless c.time < @transport.position

              t = retime.call.to_r
              t = @transport.position if t < @transport.position
              @changes.delete(c)
              c.time = t
              queue_change(c)
              c.entry = @journal.add(c.entry.with(lands: stamp(t)))
            end
            hold.release!
          }
        end

        # The nodes of the graphs sandbox +box+'s changes of +kind+ wait
        # to start.
        def pending_nodes(box, kind)
          box.instance_variable_get(:@changes).select { |c| c.kind == kind }.flat_map { |c| c.graph&.graph || [] }
        end

        # A copy of the graph whose outputs are +nodes+ from its recipe, or
        # nil if it has none (or the recipe can't be loaded back).
        def recipe_copy(nodes)
          root = nodes.length == 1 ? nodes[0] : GraphNode::Channels.new(nodes)
          return nil unless root.respond_to?(:to_ruby) && GraphNode::Recipe.record_of(nodes[0])
          text = root.to_ruby
          return nil if text.include?('FIXME')
          GraphIO.load(text)
        end

        # The least time a scheduled block's warm-up must leave before
        # the block's time, as a multiple of the last warm-up of its kind
        # (else it is skipped: a late block lands its changes late).
        WARM_MARGIN = 2

        # The time a warm-up of a kind not done yet is expected to take
        # (seconds; see WARM_MARGIN).
        WARM_GUESS = 0.5

        # Runs a warm-up of +kind+ for +name+ (see Warming), whose change
        # is expected to land at timeline position +at+ (or nil): the block gets
        # the sandbox (current while it runs), the timeline position where
        # its change should land (inside the buffer after WARM_LEAD
        # buffers, so the code that runs while a change waits and where it
        # lands is compiled by then: a change landing on the sandbox's
        # first buffer left the landing paths to compile live), and a
        # position half of WARM_BUFFERS later (where a bus's stand-in
        # senders start), and sets it up, returning
        # :played (then WARM_LEAD + WARM_BUFFERS buffers play), :built, or
        # [:failed, reason].  Notes and returns the Warm.
        #
        # With +background+ (a WarmHold), the warm-up thread isn't joined:
        # it releases the hold when it and the hold's other warm-ups are
        # done, and the hold is returned (see Warming).
        def warm(kind, name, nodes, at, background: nil)
          # (never stall a render thread; offline renders run scheduled
          # blocks holding the render lock, which is fine)
          return note_warm(Warm.new(kind: kind, name: name, ms: 0.0, result: :skipped, reason: 'the render lock is held')) if @realtime && @render_lock.mon_owned?
          t0 = MB::U.clock_now
          if !Warming.always && (left = scheduled_time_left)
            last = @warm_lock.synchronize { @warm_log.reverse_each.find { |w| w.kind == kind && w.result == :played } }
            need = WARM_MARGIN * (last ? last.ms / 1000.0 : WARM_GUESS)
            return note_warm(Warm.new(kind: kind, name: name, ms: 0.0, result: :skipped, reason: format('%.2f s before the block\'s time', left))) if left < need
          end
          sig = Warming.signature(kind, buffer_size, nodes)
          return note_warm(Warm.new(kind: kind, name: name, ms: (MB::U.clock_now - t0) * 1000, result: :known, reason: nil)) if Warming.known!(sig) && !Warming.always

          result = reason = nil
          live = warm_node_set(nodes)
          worker = Thread.new {
            Thread.current.report_on_exception = false
            Thread.current.name = 'mb-sound-warm'
            GCQuiet.during {
              Internal.strictly {
                Internal.with_private_rng(0) {
                  WARM_ROUNDS.times do |round|
                    result, reason = warm_round(kind, at, round, live) { |*a| yield(*a) }
                    break unless result == :played
                  end
                }
              }
            }
          }
          worker.priority = WARM_PRIORITY
          if background
            background.started!
            Thread.new {
              Thread.current.report_on_exception = false
              Thread.current.name = 'mb-sound-warm-wait'
              begin
                worker.join
              rescue StandardError
                nil
              ensure
                note_warm(Warm.new(kind: kind, name: name, ms: (MB::U.clock_now - t0) * 1000, result: result || :failed, reason: reason))
                release_warm_hold(background) if background.finished!
              end
            }
            return background
          end
          worker.join
          note_warm(Warm.new(kind: kind, name: name, ms: (MB::U.clock_now - t0) * 1000, result: result, reason: reason))
        end

        # One round of #warm in a new sandbox, its timeline placed so the
        # change lands at +at+ (when there is room for the lead), with
        # +live+ the live graph's nodes (see #warm_node_set).  Branches the
        # copy made on live nodes (a node its block captured; the copy is
        # then only built) are removed again, so the live Tees stay in
        # lockstep.  Returns the result and reason.
        def warm_round(kind, at, round, live)
          box = warm_sandbox
          copy_clocks(box)
          # (inside a buffer, as changes landing on a bar line do, and
          # where the change is expected to land live, so clips that
          # follow the timeline start where they will: mid-loop, say)
          per_buffer = box.transport.whole_notes_of(Rational(box.buffer_size, box.sample_rate))
          lead = (WARM_LEAD + 1/2r) * per_buffer
          land = at && at > lead ? at : lead
          box.transport.seek(land - lead)
          later = land + WARM_BUFFERS / 2 * per_buffer
          result = nil
          made = GraphNode::Tee.collect_branches {
            result = begin
              Session.with_context(session: box) { yield box, land, later, live }
            rescue StandardError, ScriptError => e
              [:failed, "#{e.class}: #{e.message.lines.first&.chomp}"]
            end
          }
          stale = []
          made.each_key { |b| stale << b if b.reader && live.include?(b.owner_tee) }
          @render_lock.synchronize { stale.each(&:destroy) } unless stale.empty?
          result, reason = result if result.is_a?(Array)
          if result == :played
            after = WARM_BUFFERS
            if kind == :graph && round == 0
              # (a graph's notes: half a bar reaches a clip's next notes,
              # voices reused and released, as Arrangement#warm_up plays;
              # the second round only needs the graph's first buffers)
              bar = box.transport.frames_of(box.transport.bar_length, box.sample_rate)
              after = MB::M.max(after, (bar * GRAPH_BARS / box.buffer_size).ceil)
            end
            (WARM_LEAD + after).times { box.process_buffer }
          end
          [result, reason]
        rescue StandardError, ScriptError => e
          [:failed, "#{e.class}: #{e.message.lines.first&.chomp}"]
        ensure
          box&.close
        end

        # Where a change at LaunchPoint +point+ (or +start_time+) would
        # land if issued now, for placing a warm-up (looping clips' grid
        # left out: a prediction, never the change's time, which is taken
        # after the warm-up).
        def warm_time(point, start_time)
          return nil unless warming?
          start_time ? start_time.to_r : launch_time(point, [])
        rescue StandardError
          nil
        end

        # Seconds of timeline left before the time of the scheduled block
        # running on this thread for this session (nil outside one).
        def scheduled_time_left
          time = Session.context&.time_for(self) or return nil
          @transport.seconds_of(time.to_r - @transport.position).to_f
        end

        def note_warm(w)
          @warm_lock.synchronize {
            @warm_log << w
            @warm_log.shift while @warm_log.length > WARM_LOG
          }
          w
        end

        # Gives sandbox +box+ this session's clocks (speeds that follow a
        # node become 1).
        def copy_clocks(box)
          clocks.each do |name, c|
            box.define_clock(name, c.base, speed: c.speed.is_a?(Numeric) || c.speed.is_a?(Symbol) ? c.speed : 1)
          end
        end

        # A stand-in player for warm-ups: noise at WARM_LEVEL.
        def warm_noise
          GraphNode::Recipe.quietly { MB::Sound.noise.at(WARM_LEVEL) }
        end

        # The nodes of the graphs of +nodes+, as a Hash compared by
        # identity (numbers left out).
        def warm_node_set(nodes)
          set = {}.compare_by_identity
          Array(nodes).each { |o| [o, *o.graph].each { |n| set[n] = true unless n.is_a?(Numeric) } }
          set
        end

        # True if any of +copy+ (an Array of nodes) is in +live+ (see
        # #warm_node_set).
        def warm_shares?(copy, live)
          copy.any? { |n| live.include?(n) }
        end
      end
    end
  end
end
