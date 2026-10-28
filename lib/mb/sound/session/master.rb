module MB
  module Sound
    class Session
      # Master effects for a Session: a chain of graph nodes that the whole
      # mix runs through before it reaches the output and taps (see #master).
      #
      # A new chain takes over from the old one at its start time.  By
      # default the old chain "spills over": from that sample on it gets
      # silence instead of the mix, so reverb and delay tails ring out
      # naturally while the new chain processes everything after the switch.
      # The old chain is dropped once it is quiet (or after
      # MAX_TAIL_SECONDS).  A +:fade+ crossfades the two chains' outputs
      # instead, both fed the mix; 0 cuts over on the switch sample.
      module Master
        # Output level below which a tail counts as silent (-90dB).
        TAIL_THRESHOLD = 10 ** (-90 / 20.0)

        # How long a tail must stay below TAIL_THRESHOLD to count as ended.
        TAIL_QUIET_SECONDS = 1

        # The longest a replaced chain may spill over, or #render may add
        # after the last player stops.
        MAX_TAIL_SECONDS = 10

        # Seconds to fade out a spillover tail that reaches MAX_TAIL_SECONDS.
        TAIL_FADE_SECONDS = 0.1

        # Processing load (fraction of the buffer's time) above which chains
        # are switched with a cut instead of running two chains at once.
        OVERLOAD = 0.6

        # A master effects chain.  +nodes+ has one node per channel (nil for
        # a bypass chain, which passes the mix through).  +mode+ is how it
        # takes over from older chains: :spill, :fade, or :cut.  +feeding+
        # is false once a newer chain has taken its input.  +gain+ and
        # +gain_step+ are its current output level and per-frame change.
        #
        # In the buffer where chains switch, +input_from+ and +input_until+
        # are the frames where the chain's input starts and stops, and
        # +ramp_from+ is the frame where its gain starts changing.
        #
        # +read_to+ is the session frame a bus's chain has read its branches
        # of shared nodes up to (nil before its first span; see
        # Buses#bus_read_shared).
        #
        # +cpu+ is the seconds its nodes took since the terminal UI's feed
        # last read it (see UIFeed).
        #
        # +preset+ is the Mastering::Preset given to #master (nil for a
        # plain block), +mastering+ every preset built into the chain (also
        # `mix.master(:club)` inside a block), +capture+ what a render's
        # first pass records of it (see Mastering::Targeting), and +rng+ the
        # root random generator's state when it was built (for rebuilding
        # it with the same seeds).
        Chain = Struct.new(
          :block, :source, :nodes, :timeline_nodes, :description,
          :start, :launch, :started, :mode, :fade, :feeding, :gain, :gain_step,
          :tail_frames, :quiet_frames, :slow_warned, :loads,
          :input_from, :input_until, :ramp_from, :read_to, :cpu,
          :preset, :mastering, :capture, :rng,
          keyword_init: true
        ) do
          def bypass?
            nodes.nil?
          end

          # The chain's nodes as one graph (a ChainGraph, the same object
          # for the chain's life), for the shared-node bookkeeping of
          # Strip#span_graphs and Strip#catch_up_waiting.
          def chain_graph
            @chain_graph ||= ChainGraph.new(self)
          end
        end

        # A master chain's nodes as one graph: #graph lists every node
        # upstream of them (none for a bypass, or a chain bypassed after an
        # error).  Running chains count as Session graphs for sleeping,
        # kept, and waiting players' shared nodes, and a chain waiting to
        # start keeps its branches of nodes it shares with them in step
        # (see Strip#catch_up_waiting; fixes-12).  Bus chains do the same,
        # and a sleeping bus's chains read their shared branches like a
        # sleeping player (fixes-13; see Buses#bus_read_shared):
        # +asleep_reads+ caches Strip#asleep_reads, and #input is the graph
        # itself (Strip#asleep_reads takes a player-like object).
        ChainGraph = Struct.new(:chain, :asleep_reads) do
          def input
            self
          end

          def graph(include_tees: true)
            nodes = chain.nodes
            return [] if nodes.nil?

            nodes.uniq(&:__id__).flat_map { |n| n.graph(include_tees: include_tees) }.uniq
          end
        end

        # Sets the master effects chain, which starts at the same launch
        # points as #add (the next bar by default while anything is playing).
        # With no block, the mix passes through unchanged (bypass).  Returns
        # a description of the chain.
        #
        # A block with one parameter gets the whole mix as a channel bundle
        # (GraphNode::Channels), so most methods run on every channel (e.g.
        # `mix.softclip`) while multichannel methods like #reverb take all of
        # them.  A block with one parameter per channel (or a splat) gets each
        # channel separately.  Either returns a bundle, an Array with one node
        # per channel, or a single node for every channel.
        #
        # +:fade+ - nil (default) to let the old chain's tails spill over,
        #           a number of bars to crossfade, or 0 to cut over.
        #
        # A mastering preset (+preset+: :club, :streaming, :quiet, :vinyl,
        # or a Mastering::Preset, with +options+; see Mastering) ends the
        # chain: the block's result (or the mix, without a block) runs
        # through it.
        #
        # Examples:
        #     session.master { |mix| mix.softclip(0.5, 0.95) }
        #     session.master { |l, r| [l, r.delay(0.01)] }
        #     session.master(:club, lufs: -9)
        #     session.master(:streaming) { |mix| mix.reverb(:hall, wet: -14.db) }
        #     session.master # bypass
        #
        # The change goes through the change queue (see Changes), so several
        # master changes can wait for different times.
        def master(preset = nil, at: nil, on: nil, in: nil, fade: nil, start_time: nil, description: nil, **options, &block)
          raise IOError, 'Session is closed' if @closed
          point = LaunchPoint.of(binding) or return nil
          raise ArgumentError, "master options #{options.keys.map(&:inspect).join(', ')} go with a mastering preset (master :club, ...)" if preset.nil? && !options.empty?
          preset = Mastering.from_preset(preset, **options) if preset
          preset = mastering_override_for(preset, block)

          chain = build_master(block, description: description, preset: preset)
          chain.mode, chain.fade = master_mode(fade)
          @master_block = block
          @master_preset = preset
          warm_master_chain(block, preset, chain, warm_time(point, start_time)) # (its code compiled here, not where it lands; see Warming)

          time = start_time ? start_time.to_r : launch_time(point, chain.timeline_nodes)
          change(:master, :master, time, data: { description: chain.description, fade: fade }, graph: chain.chain_graph) { |t|
            start_master(chain, t)
          }

          start_thread if @realtime
          chain.description
        end

        # What #master_info adds to "bypass" while the live output's safety
        # limiter stands in for a chain (see SafetyLimiter).
        SAFETY_NOTE = ' (live output: a safety limiter at -1 dBFS until a master chain is set)'

        # True if no master chain runs or waits to start (#master_info is
        # "bypass", with or without SAFETY_NOTE).
        def master_bypassed?
          master_info.delete_suffix(SAFETY_NOTE) == 'bypass'
        end

        # Returns a description of the master chain, noting when a new chain
        # is waiting to start.
        def master_info
          waiting = @render_lock.synchronize { @changes.select { |c| c.kind == :master } }
          unless waiting.empty?
            return "#{waiting.last.entry.data[:description]} (starts at bar #{bar_of(waiting.last.time)})"
          end

          @mutex.synchronize {
            chain = @master_chains&.last
            # The live output's safety limiter (see SafetyLimiter)
            safety = @safety_limiter ? SAFETY_NOTE : ''
            next "bypass#{safety}" if chain.nil?
            next "#{chain.description}#{safety}" if chain.bypass? && (chain.started || chain.start <= @transport.position)
            next "#{chain.description}#{rider_info(chain)}" if chain.started
            next "#{chain.description} (starting)" if chain.start <= @transport.position
            "#{chain.description} (starts at bar #{bar_of(chain.start)})"
          }
        end

        # " (ride +3.2 dB)" for a chain with a loudness rider (see
        # GraphNode::Rider), else ''.
        def rider_info(chain)
          return '' unless chain.preset&.ride
          rider = chain.chain_graph.graph.find { |n| n.is_a?(GraphNode::Rider::Output) }&.owner_rider
          rider ? format(' (ride %+.1f dB)', rider.gain) : ''
        end
        private :rider_info

        # The block given to the latest #master call (whether its chain
        # started or still waits), or nil for bypass (graph documents save it; see
        # GraphIO::SetWriter).
        def master_block
          @master_block
        end

        # The Mastering::Preset given to the latest #master call (nil for a
        # plain block or bypass; graph documents save it).
        def master_preset
          @master_preset
        end

        # A mastering preset that replaces the one every #master call gives
        # (and is added after master blocks that give none): a
        # Mastering::Preset, false to drop presets from #master calls, or nil
        # (default) for none.  `render(master: :club)` and scripts'
        # `--master club` set it (see PlaybackMethods#render).
        attr_reader :mastering_override

        # Sets #mastering_override (a preset name or Preset, false, or nil).
        def mastering_override=(preset)
          @mastering_override = preset.nil? || preset == false ? preset : Mastering.from_preset(preset)
        end

        # The gain renders give the trim of targeted mastering presets (see
        # Mastering::Targeting), or nil for their drive.
        attr_accessor :mastering_trim

        # A Mastering::Targeting::Capture recording what targeted master
        # chains get and give (a render's first pass), or nil.
        attr_accessor :mastering_capture

        # Rebuilds the latest master chain from its block, cutting over at
        # +time+ (whole notes; now if nil).  Clears reverb and delay tails
        # without removing the effects (see PlaybackMethods#panic).
        def reset_master(time: nil)
          chain = @mutex.synchronize { @master_chains&.last }
          return if chain.nil? || chain.bypass? && @master_chains.length == 1

          time = nil if time && time <= @transport.position
          master(chain.preset, on: :now, start_time: time, fade: 0, description: chain.description, &chain.block)
        rescue => e
          raise if @raise_errors
          warn "Could not rebuild the master chain (#{e.class}: #{e.message}); bypassing it"
          master(on: :now, start_time: time, fade: 0)
        end

        # Returns true if the mix runs through any effects (not just bypass),
        # including old chains whose tails are still ringing.
        def master_active?
          @mutex.synchronize { !!@master_chains&.any? { |c| !c.bypass? } }
        end

        # Returns true if every channel of +data+ is below TAIL_THRESHOLD.
        def quiet?(data)
          data.all? { |d| d.empty? || abs_peak(d) < TAIL_THRESHOLD } # (no Numo temporaries; Tails#abs_peak)
        end

        private

        # Hands a chain built by #master to the mix at timeline position
        # +time+ (applied by the change queue).
        def start_master(chain, time)
          @mutex.synchronize {
            @master_chains ||= []

            # The mix before any master chain was set is a bypass chain
            if @master_chains.none?(&:started)
              @master_chains.unshift(build_master(nil).tap { |c| start_master_chain(c, @transport.position) })
            end

            @master_chains.reject! { |c| !c.started }
            chain.start = time
            @master_chains << chain
          }
        end

        # Builds a Chain from a master block (a bypass chain for nil).
        # +label+ names the chain in its default description ("master: ...";
        # a bus's name for buses, see Buses).
        def build_master(block, description: nil, label: 'master', preset: nil)
          source = GraphNode::MixSource.new(channels: @channels, sample_rate: output.sample_rate)
          rng = @mastering_capture ? Internal.root_rng.dup : nil

          chain = Chain.new(
            block: block,
            source: source,
            timeline_nodes: [],
            started: false,
            feeding: true,
            gain: 1.0,
            gain_step: 0.0,
            tail_frames: 0,
            quiet_frames: 0,
            slow_warned: false,
            preset: preset,
            rng: rng
          )

          if block.nil? && preset.nil?
            chain.description = description || 'bypass'
            return chain
          end

          chans = source.outputs
          capturing = !@mastering_capture.nil?
          result, built = Mastering.building(trim: @mastering_trim, capture: capturing) {
            r = if block.nil?
                  GraphNode::Channels.new(chans)
                elsif block.arity == 0 || block.arity == 1
                  block.call(GraphNode::Channels.new(chans))
                elsif block.arity < 0 || block.arity == @channels
                  block.call(*chans)
                else
                  raise ArgumentError, "Give the master block one parameter (the whole mix) or #{@channels} (one per channel); got #{block.arity}"
                end
            if preset
              list = master_nodes(r)
              list *= @channels if list.length == 1
              r = GraphNode::Channels.new(list).master(preset)
            end
            r
          }
          chain.mastering = capturing ? built.map(&:preset) : built
          chain.capture = @mastering_capture&.chain(chain, built) if chain.mastering.any?(&:targeted?)

          list = master_nodes(result)
          list *= @channels if list.length == 1
          unless list.length == @channels
            raise ArgumentError, "The master block returned #{list.length} channels for a #{@channels}-channel session"
          end
          chain.nodes = list

          chain.timeline_nodes = chain.nodes.uniq.flat_map { |n| [n, *n.graph] }.grep(Sequence::TimelineNode).uniq
          bind_bus_taps(chain.nodes, :master) if label == 'master' # readers of buses and players (see Buses)
          chain.description = description || shorten(
            preset && block.nil? ? "#{label}: #{preset.call_ruby}" : "#{label}: #{[*(preset && preset.call_ruby), *chain.nodes.uniq.map { |n| MB::Sound.send(:playback_info, n) }.uniq].join(', ')}"
          )
          chain
        end

        # The preset a #master call uses after #mastering_override: the
        # override (if set and the call gives a preset or a block), none
        # (override false), or +preset+.
        def mastering_override_for(preset, block)
          return preset if @mastering_override.nil?
          return nil if @mastering_override == false
          return preset if preset.nil? && block.nil? # bypass stays bypass

          @mastering_override
        end

        # Converts a master block's result to an Array of GraphNodes.
        def master_nodes(result)
          case result
          when Array
            result.flat_map { |r| master_nodes(r) }
          when GraphNode, GraphNode::MultiOutput
            result.outputs
          else
            raise ArgumentError, "The master block must return a GraphNode or an Array of them (got #{result.class})"
          end
        end

        # Returns the switch mode and crossfade length in bars for a +:fade+
        # value given to #master.
        def master_mode(fade)
          return [:spill, nil] if fade.nil?
          fade = bars_or_nil(fade)
          fade ? [:fade, fade] : [:cut, nil]
        end

        # Marks a chain as started at timeline position +time+ (the start of
        # its first sample), launched at the exact time +launch+ (see
        # Sequence::TimelineNode#start_at).  Called with @mutex held.
        def start_master_chain(chain, time, launch: time)
          chain.start = time
          chain.launch = launch
          chain.started = true
        end

        # Runs +mix+ through the master chains and returns the result (the mix
        # itself if there are no chains).  +playing+ is true if any player is
        # playing, for keeping clips in master chains on the timeline.
        def process_master(mix, from, to, per_sample, count, playing:, seeked:)
          # (a reused copy, taken under the lock)
          chains = @mutex.synchronize { @master_chains.nil? || @master_chains.empty? ? nil : (@master_copy ||= []).replace(@master_chains) }
          return mix if chains.nil? || chains.empty?

          # Keep clips in effects on the timeline, which pauses while idle
          resync = seeked || (playing && !@master_playing)
          @master_playing = playing

          rate = output.sample_rate.to_f
          activate_master(chains, from, to, per_sample, rate)

          out = master_out(count)
          chains.each do |c|
            # Like players' clips: timeline loops follow the new position,
            # launch-aligned loops keep their anchor, and non-looping clips
            # count from the chain's start
            c.timeline_nodes.each { |n| n.start_at(from, origin: c.start, launch: c.launch, transport: @transport) } if resync && c.feeding

            # Tempo-synced LFOs freeze while the timeline is paused
            c.timeline_nodes.each(&:pause_timeline) unless playing

            render_master_chain(c, mix, out, count, rate)
          end

          @mutex.synchronize {
            chains.each { |c| @master_chains.delete(c) if master_chain_done?(c) }
            if @master_chains.length == 1 && @master_chains[0].bypass? && @master_chains[0].gain_step == 0
              @master_chains.clear
            end
          }

          out
        end

        # Zeroed buffers for the master chains' output: reused on the
        # render thread (see Session#process_buffer), else new (callers
        # keep what #process_buffer returns).
        def master_out(count)
          return Array.new(@channels) { Numo::SFloat.zeros(count) } unless @reuse_mix

          bufs = @master_out_bufs
          if bufs.nil? || bufs.length != @channels || bufs[0].length != count
            return @master_out_bufs = Array.new(@channels) { Numo::SFloat.zeros(count) }
          end
          bufs.each { |b| BufferHelper.zero(b) }
          bufs
        end

        # Starts a chain whose time has come, handing over from the older
        # chains at the frame where it starts in this buffer.
        def activate_master(chains, from, to, per_sample, rate)
          @mutex.synchronize {
            chain = chains.last
            return if chain.started || (chain.start >= to && @players.any?)

            # While idle the timeline doesn't advance, so start right away
            offset = chain.start >= to ? 0 : MB::M.max(((chain.start - from) / per_sample).floor, 0)
            start = from + offset * per_sample
            launch = chain.start >= to ? start : MB::M.max(chain.start, start)
            start_master_chain(chain, start, launch: launch)
            chain.timeline_nodes.each { |n| n.start_at(from, origin: start, launch: launch, transport: @transport) }

            mode = chain.mode
            if mode != :cut && @realtime && (@load || 0) > OVERLOAD
              warn "Audio processing is busy (#{(@load * 100).round}%); switching master effects without #{mode == :spill ? 'spillover' : 'a crossfade'}"
              mode = :cut
            end
            chain.mode = mode

            if mode == :spill
              chain.input_from = offset
              chains[0...-1].each do |c|
                next unless c.started && c.feeding
                c.feeding = false
                c.input_until = offset
              end
            else
              step = mode == :fade ? fade_step(chain.fade, rate) : 1.0
              chain.gain = 0.0
              chain.gain_step = step
              chain.ramp_from = offset
              chains[0...-1].each do |c|
                next unless c.started
                c.gain_step = -step
                c.ramp_from = offset
              end
            end
          }
        end

        # Renders one chain's output into +out+.
        def render_master_chain(c, mix, out, count, rate)
          return unless c.started

          input = mix
          if c.input_from || c.input_until
            input = mix.map { |m|
              d = m.dup
              d[0...c.input_from] = 0 if c.input_from && c.input_from > 0
              d[c.input_until..] = 0 if c.input_until && c.input_until < count
              d
            }
          elsif !c.feeding
            input = Array.new(@channels) { Numo::SFloat.zeros(count) }
          end

          data = master_chain_output(c, input, count)

          ramp = master_ramp(c, count, c.ramp_from || 0)
          if c.capture
            c.capture.add(@frame, input, data, ramp)
            @mastering_capture&.note_sections(self, @frame, count, @span.pos)
          end
          out.each_with_index do |o, idx|
            d = data[idx]
            next if d.length == count && (ramp.nil? || ramp.length == count) && FastArithmetic.add_at(o, 0, d, count, ramp)
            d = d * ramp if ramp
            o.inplace + d
          end

          track_master_tail(c, data, count, rate) unless c.feeding || c.input_until
          c.input_from = c.input_until = c.ramp_from = nil
        end

        # Samples a chain's nodes (each node once, even if it feeds several
        # channels).  A chain that raises or ends is replaced by a bypass.
        def master_chain_output(c, input, count)
          return input if c.bypass?

          c.source.write(input)
          t = MB::U.clock_now
          gc = GC.stat(:time)
          # (a reused Hash and, per chain, a reused Array: every buffer)
          results = (@chain_results ||= {})
          results.clear
          data = (@chain_data[c] ||= [])
          data.clear
          c.nodes.each do |n|
            d = (results[n.__id__] ||= n.sample(count))
            raise "The master chain ended (got #{d&.length.inspect} of #{count} samples)" if d.nil? || d.length < count
            d = d.real if d.is_a?(Numo::SComplex) || d.is_a?(Numo::DComplex)
            data << d
          end
          elapsed = MB::U.clock_now - t
          c.cpu = (c.cpu || 0.0) + elapsed if @ui_feed
          check_master_speed(c, Session.without_gc(elapsed, gc), count)
          data

        rescue => e
          raise if @raise_errors
          warn "The master chain (#{c.description}) stopped with an error, so it is bypassed: #{e.class}: #{e.message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}"
          old = c.nodes
          c.nodes = nil
          # (its ChainGraph lost its nodes: the Session's node-set caches
          # refresh; found by Strip.structure_check, bench-fixes-1)
          old&.each { |n| Plan.changed(n) }
          c.timeline_nodes = []
          c.description = 'bypass (the master chain stopped with an error)'
          input
        end

        # Returns per-frame gains for a chain that is fading (holding its
        # level until frame +offset+), or nil at full level.
        def master_ramp(c, count, offset)
          return nil if c.gain >= 1 && c.gain_step >= 0

          ramp = Numo::SFloat.new(count).fill(c.gain)
          if c.gain_step != 0 && offset < count
            ramp[offset..] = Numo::SFloat.new(count - offset).seq(c.gain + c.gain_step, c.gain_step)
          end
          ramp = ramp.clip(0, 1)

          c.gain = MB::M.clamp(c.gain + c.gain_step * (count - offset), 0.0, 1.0)
          c.gain_step = 0.0 if c.gain >= 1 && c.gain_step > 0
          ramp
        end

        # Counts how long a spillover chain has been ringing and how long it
        # has been quiet, fading it out if it rings too long.
        def track_master_tail(c, data, count, rate)
          c.tail_frames += count
          c.quiet_frames = quiet?(data) ? c.quiet_frames + count : 0

          if c.tail_frames >= MAX_TAIL_SECONDS * rate && c.gain_step >= 0
            c.gain_step = -1.0 / (TAIL_FADE_SECONDS * rate)
          end
        end

        # Returns true if a chain can be dropped: it was replaced and has
        # faded out or gone quiet.  +list+ is the chains it belongs to (a
        # bus's, see Buses).
        def master_chain_done?(c, list = @master_chains)
          return false if c.equal?(list.last) || !c.started

          faded = c.gain <= 0 && c.gain_step < 0
          silent = !c.feeding && (c.bypass? || c.quiet_frames >= TAIL_QUIET_SECONDS * output.sample_rate)
          faded || silent
        end

        # Warns once if a master chain takes most of the time available for
        # its buffer.
        def check_master_speed(c, elapsed, frames)
          return unless @realtime && !c.slow_warned && Session.speed_warnings

          load = sustained_load(c, elapsed, frames)
          if load
            c.slow_warned = true
            warn "The master chain (#{c.description}) is taking #{(100 * load).round}% of its audio buffer time; it may cause dropouts"
          end
        end
      end
    end
  end
end
