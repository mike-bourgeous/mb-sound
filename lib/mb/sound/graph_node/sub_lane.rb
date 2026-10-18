module MB
  module Sound
    module GraphNode
      # A skippable part of a Synth lane's graph (a sub-lane): one or more
      # channels (+inputs+) that the lane's Synth may stop computing while
      # they have nothing to play, as it skips idle lanes (see
      # Synth#setup_idle_skipping), so a lane with layers that each play
      # only some notes (SoundFont layers: Sampler::Instrument.layered)
      # computes only the layers that sound.  Sampler::Instrument#play makes
      # one per layer in synth voices.
      #
      # A sub-lane falls asleep at a point of the Synth's skip grid
      # (Synth::SKIP_GRID, 800 samples of the synth's own time) after a
      # whole grid cell whose output was exactly zero, with every envelope
      # and sampler voice inside it idle (#idle_nodes), and wakes on the
      # exact sample of the next lane event for which +wake+ (a Proc taking
      # a MIDI::Event; nil for every event) is true, or at a content jump
      # (a new stream generation: seeks, restarts).  While asleep its
      # outputs are zeros; its nodes are paused except those that keep
      # nodes outside it in step: its branches of Tees that other parts of
      # the lane read, its Notes nodes and knob readers (advanced without
      # rendering), and its Notes envelopes' bookkeeping
      # (Notes::NoteEnvelope#advance).  Wakes that start mid-buffer render
      # the rest of the buffer, with the Synth's shared controller buffers
      # windowed there (Plan::SharedInputs#window).  So the output is the
      # same at any buffer size, and, for sub-lanes whose state is all
      # envelopes, sampler voices, and filters (Instrument layers), the
      # same as rendering it every buffer, except that filter states flush
      # their last residue below 1e-30 on a grid of their own (paused)
      # time (see the sampler notes; free-running oscillators of a
      # sub-lane's own would pause, as in skipped lanes).
      #
      # Sub-lanes skip only in a Synth lane whose Notes is +notes+ (outside
      # one, or with Synth.sub_lanes off, they pass their inputs through),
      # and only if every node inside reads nodes shared with the rest of
      # the lane through Tees, has no long-memory node (Synth.long_memory?),
      # and shares its zone value indices with no node outside (see
      # #skippable? and #reason).  A plan boundary.
      class SubLane
        include MultiOutput
        include Nameable

        # One output channel of a SubLane.
        class Output
          include GraphNode
          include GraphNode::SampleRateHelper
          include GraphNode::NodeOutput

          attr_reader :index

          def initialize(sub_lane, index)
            @owner = sub_lane
            @index = index
            @node_type_name = "Sub-lane #{index + 1}"
          end

          def sample(count)
            @owner.sample_internal(count, @index)
          end

          def sample_rate
            @owner.sample_rate
          end

          def sample_rate=(rate)
            @owner.sample_rate = rate
            self
          end

          def sources
            { sub_lane: @owner }
          end

          # The plan layer sees through to this channel's input (the
          # SubLane isn't a node it walks), so the sub-lane's graph is
          # planned in regions of its own.
          def plan_sources
            { input: @owner.inputs[@index] }
          end

          # Outside a Synth lane (or with Synth.sub_lanes off) the output is
          # its input to the plan layer, so plans fuse across it as if the
          # sub-lane weren't there; a sub-lane that may sleep is a boundary.
          include Plan::Describable

          def plan_inputs
            [@owner.inputs[@index]]
          end

          def plan_describe(p)
            p[@owner.inputs[@index]]
          end

          def plan_unsupported_reason
            @owner.skippable? ? 'synth sub-lanes are a plan boundary' : nil
          end

          def to_s
            "#{@owner} #{@index + 1}"
          end
        end

        # Used by Synth while building lane graph +outs+ (the lane's output
        # nodes) for lane Notes +notes+, before it looks at the lane's
        # graph: ZoneValues inside a sub-lane that share their Index with
        # nodes outside it (e.g. modulation that only one layer of an
        # instrument uses) get an Index of their own, as do those read
        # through the Notes nodes a sleeping sub-lane keeps advancing (see
        # ZoneValue.separate), so the sub-lane can pause the rest (an Index
        # serves its readers in lockstep).
        def self.prepare(outs, notes)
          graph = outs.flat_map { |o| o.graph(include_tees: true) }.uniq
          parts = graph.select { |n| n.is_a?(SubLane) && n.notes.equal?(notes) }
          return if parts.empty?

          zones = graph.select { |n| n.is_a?(ZoneValue) }
          in_graph = {}.compare_by_identity
          graph.each { |n| in_graph[n] = true }
          before = zones.map(&:zone_index).uniq
          parts.each do |part|
            # (branches outside this lane's graph count as unread here: at
            # worst a value gets an Index it didn't need)
            excl = part.send(:exclusive, graph, ->(b) { !in_graph[b] })
            local = {}.compare_by_identity
            mine = {}.compare_by_identity
            GraphNode.graph(part, include_tees: true).each { |n| mine[n] = true }
            zones.each do |z|
              idx = z.zone_index
              fresh = -> { ZoneValue::Index.new(ZoneValue.origin(idx.number), ZoneValue.origin(idx.velocity)) }
              if excl[z]
                next if zones.all? { |u| !u.zone_index.equal?(idx) || excl[u] }

                z.zone_index = local[idx] ||= fresh.call
              elsif mine[z]
                # Read through a Tee that the sub-lane also reads, a value
                # may be sampled at the sub-lane's piece counts while its
                # Index's other values read whole buffers: one of its own
                next if zones.none? { |u| !u.equal?(z) && u.zone_index.equal?(idx) }

                z.zone_index = fresh.call
              end
            end
            nodes = graph.select { |n| excl[n] }
            ZoneValue.separate(nodes, advanced_nodes(nodes))
          end
          ZoneValue.release(before, zones)
        end

        # The nodes among +nodes+ that a sleeping sub-lane (or skipped lane)
        # advances: Notes nodes and knob readers not read through others.
        def self.advanced_nodes(nodes)
          own = nodes.select { |n| n.is_a?(MB::Sound::Notes::Node) || n.is_a?(Knob::Reader) }
          upstream = {}.compare_by_identity
          own.each { |n| n.graph(include_tees: true).each { |u| upstream[u] = true unless u.equal?(n) } }
          own.reject { |n| upstream[n] }
        end

        # The lane's Notes (see the class description).
        attr_reader :notes

        # The output nodes, one per input channel.
        attr_reader :outputs

        # The input nodes (samplers), one per channel.
        attr_reader :inputs

        # Why the sub-lane can't skip in its Synth (a String), or nil.
        attr_reader :reason

        # Samples the sub-lane spent asleep, and wakes (for specs and
        # stats).
        attr_reader :skipped_samples, :wakes

        # +inputs+: a node or an Array (or Channels) of nodes, one per
        # channel.  +notes+: the Synth lane's Notes.  +wake+: a Proc taking
        # a MIDI::Event, true for events that may make the sub-lane sound
        # (nil: every event).
        def initialize(inputs, notes:, wake: nil, name: nil)
          list = inputs.is_a?(Channels) || inputs.is_a?(Array) ? inputs.to_a : [inputs]
          raise ArgumentError, 'A sub-lane needs at least one input' if list.empty?
          raise ArgumentError, 'Sub-lane inputs are graph nodes' unless list.all? { |n| n.respond_to?(:sample) }
          @inputs = list.map(&:get_sampler).freeze
          @notes = notes
          @wake = wake
          @outputs = Array.new(@inputs.length) { |i| Output.new(self, i) }.freeze
          @label = name
          @synth = nil
          @lane = nil
          @reason = 'not in a Synth lane'
          @analysis = nil
          @asleep = false
          @ended = false
          @cell_loud = false
          @generation = nil
          @reader = nil
          @serial = nil
          @out = Array.new(@inputs.length)
          @piece_bufs = nil
          @zeros = nil
          @skipped_samples = 0
          @wakes = 0
          @env_lag = 0
          @clock_lag = 0
        end

        def sources
          @inputs.length == 1 ? { input: @inputs[0] } : @inputs.each_with_index.to_h { |n, i| [:"input_#{i + 1}", n] }
        end

        def sample_rate
          @inputs[0].sample_rate
        end

        def sample_rate=(rate)
          @inputs.each { |n| n.sample_rate = rate }
          self
        end

        def channel_count
          @inputs.length
        end

        def plan_unsupported_reason
          'synth sub-lanes are a plan boundary'
        end

        def to_s
          "Sub-lane#{" #{@label}" if @label}"
        end

        # True while the sub-lane is asleep.
        def asleep?
          @asleep
        end

        # True if the sub-lane may skip (attached to a Synth lane and no
        # #reason against it).
        def skippable?
          !@synth.nil? && @reason.nil?
        end

        # Used by Synth: the sub-lane is part of +synth+'s lane +lane+ (a
        # MIDI::Allocator::Lane) at +sample_rate+, and +lane_graph+ is every
        # node of that lane's graph; +unread+ tells branches nothing reads
        # (Synth#unread_branch?).  Finds what to pause and what to keep
        # reading while asleep (see the class description), or the #reason
        # it can't skip.
        def attach(synth, lane, lane_graph, unread)
          @synth = synth
          @lane = lane
          @rate = @inputs[0].sample_rate.to_f
          @rate_r = @rate.to_r
          @lane_graph = lane_graph
          @unread = unread
          @reader&.close
          @reader = lane.reader
          @generation = lane.generation
          @analysis = nil
          analyze
          self
        end

        # Used by Synth when the whole lane sleeps for +count+ samples: keeps
        # the sub-lane's own clock and its envelopes' bookkeeping in step
        # (everything else of the lane is paused with it).
        def lane_skipped(count)
          return unless skippable?

          flush_clock
          advance_clock(count)
          @env_lag += count
        end

        # Used by Output#sample: renders every channel once per piece of the
        # Synth's lane (or passes the inputs through outside a Synth lane)
        # and returns channel +index+.
        def sample_internal(count, index)
          return nil if @ended
          return @inputs[index].sample(count) unless skippable?

          ctx = @synth.lane_piece
          if ctx.nil? || ctx[0] != @lane.index || ctx[2] != count
            # Read outside its lane's pieces (or with another count): it
            # can't keep its place on the synth's time, so it stops skipping
            @reason = "read outside its Synth lane's buffers (#{count} samples)"
            return @inputs[index].sample(count)
          end

          unless @serial == ctx[3]
            @serial = ctx[3]
            render(ctx[1], count)
          end
          @out[index]
        end

        private

        # The pause/keep lists (recomputed when a Tee upstream gains or
        # loses a branch; BranchWatch).
        def analysis
          analyze if @analysis.nil? || !@analysis[:watch].current?
          @analysis
        end

        # See #attach.
        def analyze
          # (before reading the Tees' branches)
          watch = BranchWatch.new(GraphNode.graph(self, include_tees: true).select { |n| n.is_a?(Tee) })
          lane_set = {}.compare_by_identity
          @lane_graph.each { |n| lane_set[n] = true }
          excl = exclusive(@lane_graph, @unread)
          mine = GraphNode.graph(self, include_tees: true).reject { |n| n.equal?(self) }
          nodes = mine.select { |n| excl[n] }

          reason = nil
          # Nodes read directly (not through a Tee) by both sides would be
          # read once per buffer by the rest and not at all while asleep
          nodes.each do |n|
            n.sources.each_value do |s|
              next if excl[s] || !lane_set[s] || s.is_a?(Tee::Branch) || s.is_a?(Tee) || !s.respond_to?(:sample)
              next if s.is_a?(MIDI::Stream)
              reason ||= "#{n} reads #{s} without a Tee"
            end
          end
          reason ||= nodes.find { |n| Synth.long_memory?(n) }&.then { |n| "#{n} remembers sound (#{n.class})" }

          # Zone value indices must be read by this sub-lane only
          zones = @lane_graph.select { |n| n.is_a?(ZoneValue) }
          nodes.each do |n|
            next unless n.is_a?(ZoneValue)
            idx = n.zone_index
            next if zones.all? { |z| !z.zone_index.equal?(idx) || excl[z] }
            reason ||= "#{n} shares its zone index with nodes outside the sub-lane"
          end

          # What to keep reading while asleep: Notes nodes (advanced) and
          # knob readers, then branches of Tees read outside, except those
          # read through them
          own = SubLane.advanced_nodes(nodes)
          upstream = {}.compare_by_identity
          own.each { |n| n.graph(include_tees: true).each { |u| upstream[u] = true unless u.equal?(n) } }
          branches = nodes.select { |n| n.is_a?(Tee::Branch) && !excl[n.owner_tee] && !upstream[n] }

          @analysis = {
            watch: watch,
            nodes: nodes,
            advance: own,
            branches: branches,
            envelopes: nodes.select { |n| n.is_a?(MB::Sound::Notes::NoteEnvelope) },
            idle: nodes.select { |n| n.respond_to?(:idle?) && (n.is_a?(MB::Sound::Envelope) || n.is_a?(SamplerVoice)) },
          }
          @reason = reason
          if reason && @asleep
            @asleep = false
          end
          @analysis
        end

        # The nodes of +lane_graph+ that only this sub-lane reads (an
        # identity Hash): everything upstream of its inputs whose every
        # reader is one of them (for Tees: every branch +unread+ doesn't
        # leave out).
        def exclusive(lane_graph, unread)
          lane_set = {}.compare_by_identity
          lane_graph.each { |n| lane_set[n] = true }
          readers = Hash.new { |h, k| h[k] = [] }.compare_by_identity
          lane_graph.each do |m|
            next unless m.respond_to?(:sources)
            m.sources.each_value { |s| readers[s] << m if lane_set[s] }
          end

          excl = {}.compare_by_identity
          excl[self] = true
          GraphNode.graph(self, include_tees: true).each do |n|
            next if n.equal?(self) || !n.respond_to?(:sources)
            ok = if n.is_a?(Tee)
                   live = n.branches.reject { |b| unread.call(b) }
                   !live.empty? && live.all? { |b| excl[b] }
                 else
                   r = readers[n]
                   !r.empty? && r.all? { |m| excl[m] }
                 end
            excl[n] = true if ok
          end
          excl.delete(self)
          excl
        end

        # Renders +count+ samples from synth sample +pos+ into @out (see the
        # class description).
        def render(pos, count)
          a = analysis
          unless @reason.nil?
            catch_up(a)
            return render_awake(count)
          end

          o = 0
          whole = nil
          pieces = false
          while o < count
            if @asleep
              wake = wake_offset(o, count)
              stop = wake || count
              if stop > o
                skip_span(a, o, stop - o, o != 0 || stop != count)
                if o == 0 && wake.nil?
                  whole = :zeros
                else
                  pieces = true
                  piece_bufs(count).each { |b| b[o...stop] = 0 }
                end
              end
              o = stop
              next if wake.nil?

              @asleep = false
              @cell_loud = false
              @wakes += 1
            end
            catch_up(a)

            stop = sleep_candidate(a, pos, o, count)
            n = stop - o
            window = o != 0 || stop != count
            got = sample_inputs(o, n, window)
            if got.nil?
              @ended = true
              @out.fill(nil)
              return
            end
            # (awake, the clock catches up once per grid cell: see
            # #flush_clock)
            @clock_lag += n
            track_cells(a, got, pos + o)
            flush_clock if @asleep || @clock_lag >= Synth::SKIP_GRID

            if window
              pieces = true
              piece_bufs(count).each_with_index { |b, c| b[o...stop] = got[c] }
            else
              whole = got
            end
            o = stop
          end

          if pieces
            @piece_bufs.each_with_index { |b, c| @out[c] = b }
          elsif whole == :zeros
            z = zeros(count)
            @out.fill(z)
          else
            whole.each_with_index { |b, c| @out[c] = b }
          end
        end

        # Every channel for +count+ without skipping (a sub-lane that can't
        # skip in its Synth after all).
        def render_awake(count)
          @inputs.each_with_index { |n, c| @out[c] = n.sample(count) }
          @clock_lag += count
          flush_clock if @clock_lag >= Synth::SKIP_GRID
        end

        # Moves the clock over the samples rendered awake since it last
        # moved (reading it every buffer cost ~1.3 us per buffer; a reader
        # behind by up to a grid cell only holds that much of the lane's
        # event log).
        def flush_clock
          return if @clock_lag == 0

          advance_clock(@clock_lag)
          @clock_lag = 0
        end

        # The inputs' buffers for +n+ samples from offset +o+ of the lane's
        # piece (windowed shared inputs if +window+), or nil if one ended.
        # Short last buffers are padded with zeros.
        def sample_inputs(o, n, window)
          got = (@got ||= [])
          got.clear
          @inputs.each do |inp|
            buf = window ? @synth.sub_lane_window(o, n) { inp.sample(n) } : inp.sample(n)
            return nil if buf.nil?
            if buf.length < n
              padded = buf.class.zeros(n)
              padded[0...buf.length] = buf
              buf = padded
            end
            got << buf
          end
          got
        end

        # Keeps nodes outside in step for +count+ samples from offset +o+ of
        # the lane's piece while asleep (with the shared controller buffers
        # windowed there if +window+: what these branches read may be a plan
        # region gathering them).
        def skip_span(a, o, count, window)
          shared = @synth.shared_inputs
          shared = nil unless shared&.active?
          branches = a[:branches]
          unless branches.empty?
            if window
              @synth.sub_lane_window(o, count) { read_branches(branches, shared, count) }
            else
              read_branches(branches, shared, count)
            end
          end
          a[:advance].each do |n|
            next if shared&.shared_node?(n)
            n.advance(count)
          end
          # (idle envelopes catch up at the wake: their stream time only
          # answers questions about sounding envelopes; see #catch_up)
          @env_lag += count
          advance_clock(count)
          @skipped_samples += count
        end

        # Reads (and drops) +count+ samples of each of +branches+, except
        # those Plan::SharedInputs hands out.
        def read_branches(branches, shared, count)
          branches.each do |b|
            next if shared && (b.is_a?(Tee::Branch) ? shared.shared_tee?(b.owner_tee) : shared.shared_node?(b))
            b.sample(count)
          end
        end

        # Moves the paused Notes envelopes' bookkeeping over the samples
        # skipped since they last rendered (Notes::NoteEnvelope#advance).
        def catch_up(a)
          return if @env_lag == 0

          a[:envelopes].each { |e| e.advance(@env_lag) }
          @env_lag = 0
        end

        # Moves the sub-lane's own reader of the lane +count+ samples on.
        def advance_clock(count)
          from = @reader.cursor
          @reader.events(from, @lane.advance(from, count, @rate))
        end

        # The offset (from +o+ of +count+) of the first event that wakes
        # the sub-lane, or nil (see the class description).
        def wake_offset(o, count)
          return o if @lane.generation != @generation

          from = @reader.cursor
          to = @lane.advance(from, count - o, @rate)
          time = @wake ? @lane.first_pending_time(from, to, &@wake) : @lane.first_pending_time(from, to)
          return nil if time.nil?

          o + ((time - from) * @rate_r).floor
        end

        # Like Synth#sleep_candidate: the next grid point if the sub-lane may
        # fall asleep there (its cell so far was silent), else +count+.  A
        # sampler voice holding a looping note can't fall idle without a
        # lane event, so without one in the rest of the block there's no
        # split (a piano layer looping a silent stretch of its sample would
        # otherwise split every buffer crossing a grid point, which takes its
        # Tees out of lockstep).
        def sleep_candidate(a, pos, o, count)
          grid = Synth::SKIP_GRID
          g = ((pos + o) / grid + 1) * grid - pos
          return count if g > count

          g += grid if @cell_loud
          return count if g > count

          if a[:idle].any? { |n| n.respond_to?(:sustaining?) && n.sustaining? }
            from = @clock_lag == 0 ? @reader.cursor : @lane.advance(@reader.cursor, @clock_lag, @rate)
            return count if @lane.first_pending_time(from, @lane.advance(from, count - o, @rate)).nil?
          end

          g
        end

        # Notes whether the output was nonzero in each grid cell, and falls
        # asleep at a grid point ending a silent cell with every envelope and
        # voice idle (only at the end of the buffers, where #sleep_candidate
        # split the block).
        def track_cells(a, bufs, start)
          grid = Synth::SKIP_GRID
          len = bufs[0].length
          # (the usual awake case: already loud, no grid point reached)
          return if @cell_loud && start + len < (start / grid + 1) * grid

          i = 0
          while i < len
            g = (start + i) / grid * grid + grid
            stop = MB::M.min(g - start, len)
            @cell_loud ||= bufs.any? { |b| nonzero?(i == 0 && stop == len ? b : b[i...stop]) }
            if start + stop == g
              silent = !@cell_loud
              @cell_loud = false
              if silent && stop == len && a[:idle].all?(&:idle?)
                @asleep = true
                @generation = @lane.generation
              end
            end
            i = stop
          end
        end

        def nonzero?(b)
          return false if b.equal?(@zeros)

          r = (@range ||= [0.0, 0.0])
          unless MB::Sound::FastArithmetic.min_max(b, r)
            b = b.abs if b.is_a?(Numo::SComplex) || b.is_a?(Numo::DComplex)
            r[0] = b.min.to_f
            r[1] = b.max.to_f
          end
          r[0] != 0 || r[1] != 0
        end

        def zeros(count)
          @zeros = Numo::SFloat.zeros(count).freeze if @zeros.nil? || @zeros.length != count
          @zeros
        end

        def piece_bufs(count)
          list = (@piece_bufs ||= [])
          list.clear if list[0] && list[0].length != count
          list << Numo::SFloat.zeros(count) while list.length < @inputs.length
          list
        end
      end
    end
  end
end
