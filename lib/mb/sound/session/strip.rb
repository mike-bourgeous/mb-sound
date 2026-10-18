module MB
  module Sound
    class Session
      # Mute and solo for Session players: the mute/solo stage of each
      # player's strip (contract K7: fade, then gain, then mute/solo).
      #
      # Mutes and solos belong to player names, so a graph replacing a muted
      # one starts muted.  An armed track's monitor player follows its
      # track's mute and solo.  They apply right away with a short declick ramp
      # (DECLICK_SECONDS), or at a launch point (+:at+) and over a +:fade+
      # in bars, through the change queue like every other change.
      #
      # A player that is silent because of a mute or solo sleeps: its graph
      # isn't rendered at all (no CPU), so its state goes stale.  When it
      # wakes, its clips and tempo-synced oscillators move to the timeline
      # like after a seek, so they come back in time; free-running
      # oscillators, envelopes, delays, and reverbs carry on from where they
      # stopped.
      module Strip
        # A graph kept for #resume or #undo that still reads its branches of
        # shared nodes (see #read_kept_graphs): +read_to+ is the session
        # frame it has read up to, +asleep_reads+ the cache of
        # #asleep_reads.
        KeptGraph = Struct.new(:input, :read_to, :asleep_reads)

        # A graph waiting to start (see #catch_up_waiting): +asleep_reads+
        # is the cache of #asleep_reads.
        WaitingGraph = Struct.new(:input, :asleep_reads)

        # Raised by the structure check (Strip.structure_check) when a
        # Session graph's nodes changed without Plan.changed(node): the
        # node-set caches (#graph_node_set) refresh only on
        # GraphNode.structure_changes, so such an edit leaves them stale.
        class UnannouncedStructureChange < RuntimeError; end

        class << self
          # True to check that each cached node set (#graph_node_set)
          # still matches a fresh walk of its graph while
          # GraphNode.structure_changes says nothing changed (omnibus10: a
          # guard for ux-fix-2's caches, which trust every structural edit
          # to call Plan.changed), every STRUCTURE_CHECK_SPANS spans and
          # when the Session closes (an edit stays, so it is found; every
          # span tripled the time of Session-heavy specs).  On in specs
          # (spec_helper) and with MB_SOUND_CHECK_STRUCTURE=1; off by
          # default.
          attr_accessor :structure_check
        end
        self.structure_check = !['', '0', nil].include?(ENV['MB_SOUND_CHECK_STRUCTURE'])

        # Spans between structure checks (see Strip.structure_check).
        STRUCTURE_CHECK_SPANS = 16

        # Mutes the players named +names+ (or mute groups; see #mute_group).
        # Returns the changes (see Changes#change).
        def mute(*names, at: nil, on: nil, in: nil, fade: nil, start_time: nil)
          point = LaunchPoint.of(binding) or return nil
          strip_change(:mute, names, at: point, fade: fade, start_time: start_time) { |n| @muted << n }
        end

        # Unmutes the named players (all muted players if none are named:
        # those muted when the change lands).
        def unmute(*names, at: nil, on: nil, in: nil, fade: nil, start_time: nil)
          point = LaunchPoint.of(binding) or return nil
          return strip_all_change(:unmute, at: point, fade: fade, start_time: start_time) { @muted.clear } if names.empty?
          strip_change(:unmute, names, at: point, fade: fade, start_time: start_time) { |n| @muted.delete(n) }
        end

        # Solos the named players: while any player is soloed, players that
        # aren't are silent.  With no names, clears every solo (see #unsolo).
        def solo(*names, at: nil, on: nil, in: nil, fade: nil, start_time: nil)
          point = LaunchPoint.of(binding) or return nil
          return unsolo(at: point, fade: fade, start_time: start_time) if names.empty?
          strip_change(:solo, names, at: point, fade: fade, start_time: start_time) { |n| @soloed << n }
        end

        # Clears the solo of the named players (all solos if none are named:
        # those soloed when the change lands, so a queued solo isn't missed).
        def unsolo(*names, at: nil, on: nil, in: nil, fade: nil, start_time: nil)
          point = LaunchPoint.of(binding) or return nil
          return strip_all_change(:unsolo, at: point, fade: fade, start_time: start_time) { @soloed.clear } if names.empty?
          strip_change(:unsolo, names, at: point, fade: fade, start_time: start_time) { |n| @soloed.delete(n) }
        end

        # Defines a mute group: +name+ stands for the players +names+ in
        # #mute, #unmute, #solo, and #unsolo (an MPC-style mute group, e.g.
        # `mute_group :breakdown, :drums, :bass` and then `mute :breakdown`).
        # Pass no names to remove the group.  Returns the group's names.
        def mute_group(name, *names)
          names = names.flatten
          return nil unless names.empty? || @names.claim(name, :group)

          @render_lock.synchronize {
            if names.empty?
              @mute_groups.delete(name)
            else
              @mute_groups[name] = names.freeze
            end
          }
          names
        end

        # The mute groups (a Hash from group name to player names).
        def mute_groups
          @render_lock.synchronize { @mute_groups.dup }
        end

        # True if +name+ is muted (once queued changes have landed, if
        # +projected+).
        def muted?(name)
          @render_lock.synchronize { @muted.include?(name) }
        end

        # True if +name+ is soloed.
        def soloed?(name)
          @render_lock.synchronize { @soloed.include?(name) }
        end

        # True if a player named +name+ would be heard (not muted, and
        # soloed if anything is).
        def audible?(name)
          @render_lock.synchronize { audible_unlocked?(name) }
        end

        # The mute and solo state: a Hash with the +:muted+ and +:soloed+
        # names, the mute +:groups+, and +:queued+ mute/solo changes.
        def strip_info
          @render_lock.synchronize {
            {
              muted: @muted.to_a,
              soloed: @soloed.to_a,
              groups: @mute_groups.dup,
              queued: @changes.select { |c| STRIP_KINDS.include?(c.kind) }.map(&:entry),
            }
          }
        end

        # Change kinds for mutes and solos.
        STRIP_KINDS = [:mute, :unmute, :solo, :unsolo].freeze

        private

        def init_strip
          @muted = ::Set.new
          @soloed = ::Set.new
          @mute_groups = {}
          @landing_frame = nil
          @kept_graphs = {}.compare_by_identity
          @waiting_graphs = {}.compare_by_identity
          @graph_node_sets = {}.compare_by_identity # (#graph_node_set)
          @structure_check_spans = 0 # (Strip.structure_check)
          @asleep_index = nil # (#asleep_index)
        end

        # Expands mute group names.
        def expand_mute_groups(names)
          names.flat_map { |n| @mute_groups.key?(n) ? @mute_groups[n] : [n] }.uniq
        end

        # Queues one mute/solo change per name at the launch point (now by
        # default), each calling +update+ with the name when it lands.
        def strip_change(kind, names, at:, fade:, start_time:, &update)
          names = expand_mute_groups(names.flatten)
          fade = bars_or_nil(fade) if fade
          time = start_time ? start_time.to_r : launch_time(at, [], default: nil)

          names.map { |n|
            change(kind, n, time, data: { fade: fade }) { |_t|
              update.call(n)
              apply_strip(fade)
            }
          }
        end

        # Queues one change to every player's mute or solo flags (subject
        # :strip), calling +update+ when it lands.  Returns the changes.
        def strip_all_change(kind, at:, fade:, start_time:, &update)
          fade = bars_or_nil(fade) if fade
          time = start_time ? start_time.to_r : launch_time(at, [], default: nil)
          [change(kind, :strip, time, data: { fade: fade }) { |_t| update.call; apply_strip(fade) }]
        end

        # Puts every mute and solo flag back to a StripState (for undo).
        def restore_strip(state, fade = nil)
          @muted.replace(state.muted)
          @soloed.replace(state.soloed)
          apply_strip(fade)
        end

        # True if a player named +name+ should be heard.  Called with
        # @render_lock held.  An armed track's monitor (:"lead/live"; see
        # Arrangement::Recording) follows its track's flags as well as its
        # own: `mute :lead` silences the keyboard through :lead's patch
        # too, and `solo :lead` keeps it (omnibus6, agreed 2026-10-12).
        def audible_unlocked?(name)
          track = Arrangement::Recording.monitored_track(name)
          return false if @muted.include?(name) || (track && @muted.include?(track))
          @soloed.empty? || @soloed.include?(name) || (!track.nil? && @soloed.include?(track))
        end

        # Ramps every player whose mute/solo level should change, starting
        # at the frame where the current change lands (see
        # Changes#commit_change), over +fade+ bars or DECLICK_SECONDS.
        def apply_strip(fade)
          frame = @landing_frame || @frame
          rate = output.sample_rate.to_f
          length = fade ? fade_frames(fade, rate) : MB::M.max((Fades::DECLICK_SECONDS * rate).round, 1)

          @mutex.synchronize { @players.values }.each do |p|
            target = audible_unlocked?(p.name) ? 1.0 : 0.0
            current_target = p.strip_ramp ? p.strip_ramp.to : p.strip_level
            next if current_target == target

            level = p.strip_ramp ? p.strip_ramp.at(frame) : p.strip_level
            p.strip_ramp = Fades::Ramp.new(level, target, frame, length)
          end
        end

        # Reads sleeping player +p+'s branches of nodes that other players
        # also play (see #asleep_reads) for +frames+ frames, so their Tees
        # keep it in step: before, the Tee left it a whole CircularBuffer
        # behind after a second asleep, and unmuting raised
        # BranchBufferOverflow.  The player's own nodes still sleep.
        def read_while_asleep(p, frames)
          return if frames <= 0

          asleep_reads(p).each { |b| b.sample(frames) }
        end

        # What sleeping player +p+ (or a kept graph; see #read_kept_graphs)
        # still reads (like a skipped Synth lane; see Synth#boundary), and
        # what a graph waiting to start skips (see #catch_up_waiting): its
        # own branches of Tees with a branch in another graph in the Session
        # (another player's, sleeping or not, or a graph kept for #resume or
        # #undo), less those that another of these reads through.  Branches
        # nothing in the Session plays (an unused `lfo * 2`, or a graph not
        # started yet) don't count: reading for them would run the node
        # while the player sleeps, so a muted player's sound would depend on
        # unused nodes.  Cached until one of its Tees gains or loses a
        # branch (GraphNode::BranchWatch), the Session's graphs change, or
        # one of their nodes changes structure (GraphNode.structure_changes).
        #
        # Each graph's nodes are listed once (#graph_node_set) and counted
        # once per set of graphs (#asleep_index), not once per sleeping,
        # kept, or waiting graph; and branches made elsewhere (the next
        # scene's graphs, built on the scheduler thread) leave the cache
        # alone.  Before (ux-fix-2), every new branch anywhere rebuilt every
        # such cache by walking every graph, each buffer while a scene was
        # built: up to 45 ms of a 10.7 ms buffer at night_bus_flow's drop.
        def asleep_reads(p)
          graphs = span_graphs
          structure = GraphNode.structure_changes
          cache = p.asleep_reads
          return cache[3] if cache && cache[0].equal?(graphs) && cache[1] == structure && cache[2].current?

          input = p.input
          counts, members = asleep_index(graphs, structure)
          own, own_set = graph_node_set(input, structure)
          # Nodes in another graph than this one
          mine = members.key?(input)
          other = ->(n) { id = n.__id__; (counts[id] || 0) - (mine && own_set[id] ? 1 : 0) > 0 }

          # Branches only this graph reads (a branch inside a node another
          # graph also plays, e.g. the LFO branch in `x = lfo * 2` shared
          # by both, is read through that node), of Tees with another
          # branch in another graph: before fixes-11 a Tee counted only if
          # one of its branches was outside this graph, so a graph playing
          # `x * 0.1 + lfo * 0.1` while another played `x` left its own
          # `lfo` branch unread, and unmuting it after a second raised
          # BranchBufferOverflow
          branches = own.select { |n| n.is_a?(GraphNode::Tee::Branch) && n.reader }
          watch = GraphNode::BranchWatch.new(branches.map(&:owner_tee)) # (before reading their branches)
          shared = branches.select { |n|
            !other.(n) && n.owner_tee.branches.any? { |b| !b.equal?(n) && other.(b) }
          }
          upstream = {}
          shared.each { |n| n.graph(include_tees: true).each { |u| upstream[u.__id__] = true unless u.equal?(n) } }
          shared.reject! { |n| upstream[n.__id__] }

          p.asleep_reads = [graphs, structure, watch, shared]
          shared
        end

        # How many of +graphs+ (#span_graphs) hold each node (by __id__),
        # and the graphs as an identity Hash: [counts, members], kept while
        # the graphs and +structure+ (GraphNode.structure_changes) stay.
        def asleep_index(graphs, structure)
          index = @asleep_index
          return index[2] if index && index[0].equal?(graphs) && index[1] == structure

          members = {}.compare_by_identity
          graphs.each { |g| members[g] = true }
          counts = {}
          members.each_key do |g|
            graph_node_set(g, structure)[1].each_key { |id| counts[id] = (counts[id] || 0) + 1 }
          end
          # Forget node sets of graphs that left (waiting graphs ask again)
          @graph_node_sets.select! { |g, _| members.key?(g) || @waiting_graphs.key?(g) }
          @asleep_index = [graphs, structure, [counts, members]]
          [counts, members]
        end

        # The nodes of +graph+ (with Tees) and a Hash of their __ids__:
        # [nodes, ids], kept while +structure+ (GraphNode.structure_changes)
        # stays (a Tee gaining a branch doesn't change what a graph reads
        # through its sources).
        def graph_node_set(graph, structure)
          entry = @graph_node_sets[graph]
          return entry[1] if entry && entry[0] == structure

          nodes = graph.graph(include_tees: true)
          GraphNode.watch_structure(nodes)
          ids = {}
          nodes.each { |n| ids[n.__id__] = true }
          @graph_node_sets[graph] = [structure, [nodes, ids]]
          [nodes, ids]
        end

        # Raises UnannouncedStructureChange if a cached node set (see
        # #graph_node_set) no longer matches its graph while
        # GraphNode.structure_changes hasn't moved (Strip.structure_check).
        def check_structure!
          structure = GraphNode.structure_changes
          @graph_node_sets.each do |graph, (count, (nodes, ids))|
            next unless count == structure

            now = graph.graph(include_tees: true)
            next if now.length == nodes.length && now.all? { |n| ids.key?(n.__id__) }

            fresh = {}
            now.each { |n| fresh[n.__id__] = true }
            added = now.reject { |n| ids.key?(n.__id__) }
            removed = nodes.reject { |n| fresh.key?(n.__id__) }
            names = ->(list) { list.first(4).map { |n| n.class.name.sub('MB::Sound::', '') }.join(', ') + (list.length > 4 ? ', ...' : '') }
            raise UnannouncedStructureChange,
                  "A Session graph (#{graph.class.name.sub('MB::Sound::', '')}) changed its nodes without Plan.changed(node) " \
                  "(#{added.length} added#{added.empty? ? '' : ": #{names.(added)}"}; #{removed.length} removed#{removed.empty? ? '' : ": #{names.(removed)}"}): " \
                  'call MB::Sound::Plan.changed(node) after changing a node\'s inputs, so caches of graph node sets (Session::Strip) refresh'
          end
          nil
        end

        # The inputs of the Session's graphs (players' and kept graphs', and
        # the ChainGraphs of master chains: running, spilling over, or
        # landed and starting in this span; fixes-12; and of bus chains,
        # asleep or not; fixes-13): one list per span,
        # the same object while they stay the same (for the caches of
        # #asleep_reads).
        def span_graphs
          @span_graphs ||= begin
            list = (@span_players || @mutex.synchronize { @players.values }).map(&:input)
            list.concat(@kept_graphs.keys) unless @kept_graphs.empty?
            chains = @master_chains
            chains&.each { |c| list << c.chain_graph unless c.bypass? }
            list.concat(bus_chain_graphs) # (fixes-13; see Buses)
            ids = list.map(&:__id__)
            if ids == @asleep_ids
              @asleep_graphs
            else
              @asleep_ids = ids
              @asleep_graphs = list
            end
          end
        end

        # Moves the branches of shared nodes in graphs waiting to start (see
        # #asleep_reads) to their Tees' leaders: graphs queued by #add
        # (a `bg` while playing lands on the next bar; scene builds run up
        # to two bars ahead) and players that start later in this span.
        # Before, nothing read a waiting graph's branch while a playing
        # graph's branch read on, so it started with the shared node late
        # by its wait, and after a second (the Tee's CircularBuffer) its
        # first read raised BranchBufferOverflow (fixes-10 found it).  Called
        # at the start of every span, after changes land and before players
        # render, when every played branch is at the span's first frame, so
        # a waiting graph starts reading the node on the frame it starts at
        # any buffer size (#catch_up_started reads the frames of the span
        # before that).  Graphs kept for #resume or #undo read instead (see
        # #read_kept_graphs).
        #
        # Master chains waiting to start (queued by #master, or an undo's
        # restore, and chains that landed in this span) do the same since
        # fixes-12 (2026-10-14): before, `master { |mix| mix * lfo }` queued
        # for the next bar played the LFO late by its wait and raised
        # BranchBufferOverflow after a second.  A chain reads its first
        # span from the span's first frame (its input is silent before its
        # start), so it needs no #catch_up_started.  Bus chains waiting to
        # start do the same since fixes-13 (their :bus changes carry their
        # ChainGraphs); one starting in a later segment of the span reads
        # the frames before it first (see Buses#bus_read_shared).
        def catch_up_waiting(players)
          if Strip.structure_check && (@structure_check_spans += 1) % STRUCTURE_CHECK_SPANS == 0
            check_structure!
          end
          waiting = nil
          @changes.each { |c| (waiting ||= []) << c.graph if c.graph }
          players.each { |p| (waiting ||= []) << p.input unless p.started }
          chains = @master_chains
          chains&.each { |c| (waiting ||= []) << c.chain_graph unless c.started || c.bypass? }
          bus_chain_graphs(waiting: true).each { |g| (waiting ||= []) << g }
          if waiting.nil?
            @waiting_graphs.clear unless @waiting_graphs.empty?
            return
          end

          live = {}.compare_by_identity
          waiting.each do |input|
            next if @kept_graphs.key?(input)

            live[input] = true
            w = (@waiting_graphs[input] ||= WaitingGraph.new(input, nil))
            asleep_reads(w).each(&:catch_up)
          rescue => e
            raise if @raise_errors
            warn "A graph waiting to start couldn't keep in step with shared nodes: #{e.class}: #{e.message}"
          end
          @waiting_graphs.select! { |input, _| live[input] } if @waiting_graphs.size > live.size
        end

        # Reads the first +offset+ frames of the span on the shared
        # branches of player +p+'s graph if it waited to start (see
        # #catch_up_waiting), so it starts reading them on its first frame.
        # They are read at the Tees' own rate (a branch pinned to an
        # oversample region's rate starts its resampler there).
        def catch_up_started(p, offset)
          w = @waiting_graphs.delete(p.input) unless @waiting_graphs.empty?
          return unless w && offset > 0

          asleep_reads(w).each { |b| b.internal_raw_sample(offset) }
        end

        # Notes that player +p+ has left the Session's players (stopped,
        # replaced, or ended), so #read_kept_graphs can keep its graph in
        # step while it is kept for #resume or #undo.  Called on the
        # rendering thread or with @render_lock held.
        def note_retired(p)
          return unless p.read_to

          k = (@kept_graphs[p.input] ||= KeptGraph.new(p.input, p.read_to, nil))
          k.read_to = p.read_to
        end

        # Reads the branches of shared nodes (see #asleep_reads) of graphs
        # kept for #resume or #undo (stopped, replaced, or forgotten graphs
        # the undo list still holds) up to session frame +frame+ (the end
        # of the span), like sleeping players: a kept graph sharing a node
        # with a playing graph fell a whole CircularBuffer behind after a
        # second, and resuming it raised BranchBufferOverflow (fixes-9
        # reproduced it).  Each graph reads exactly the frames since it
        # stopped, so it comes back in step at any buffer size.  Graphs no
        # longer kept, or playing again, are dropped; a graph waiting to
        # start reads up to its first frame in #catch_up_kept.  Called once
        # per span after the players, on the rendering thread.
        def read_kept_graphs(frame)
          return if @kept_graphs.empty?

          kept = {}.compare_by_identity
          @mutex.synchronize {
            @stopped.each_value { |s| kept[s.input] = true }
            @players.each_value { |o| kept[o.input] = false if o.started }
          }
          undo_inputs.each { |i| kept[i] = true unless kept.key?(i) }
          @kept_graphs.select! { |input, _| kept[input] }

          @kept_graphs.each_value do |k|
            read_while_asleep(k, frame - k.read_to)
            k.read_to = frame
          rescue => e
            @kept_graphs.delete(k.input)
            raise if @raise_errors
            warn "A kept graph stopped keeping in step with an error: #{e.class}: #{e.message}"
          end
        end

        # Reads a kept graph's shared branches (see #read_kept_graphs) up to
        # player +p+'s first frame, +frame+, when +p+ plays it again
        # (#resume, #undo).
        def catch_up_kept(p, frame)
          k = @kept_graphs.delete(p.input) unless @kept_graphs.empty?
          p.read_to = frame
          return unless k

          read_while_asleep(p, frame - k.read_to)
        end

        # The mute/solo level a new player named +name+ starts at.
        def initial_strip_level(name)
          audible_unlocked?(name) ? 1.0 : 0.0
        end
      end
    end
  end
end
