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
        Chain = Struct.new(
          :block, :source, :nodes, :timeline_nodes, :description,
          :start, :started, :mode, :fade, :feeding, :gain, :gain_step,
          :tail_frames, :quiet_frames, :slow_warned, :loads,
          :input_from, :input_until, :ramp_from,
          keyword_init: true
        ) do
          def bypass?
            nodes.nil?
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
        # Examples:
        #     session.master { |mix| mix.softclip(0.5, 0.95) }
        #     session.master { |l, r| [l, r.delay(seconds: 0.01)] }
        #     session.master # bypass
        def master(at: nil, fade: nil, start_time: nil, description: nil, &block)
          raise IOError, 'Session is closed' if @closed

          chain = build_master(block, description: description)
          chain.mode, chain.fade = master_mode(fade)

          @mutex.synchronize {
            @master_chains ||= []

            # The mix before any master chain was set is a bypass chain
            if @master_chains.none?(&:started)
              @master_chains.unshift(build_master(nil).tap { |c| start_master_chain(c, @transport.position) })
            end

            @master_chains.reject! { |c| !c.started }
            chain.start = start_time ? start_time.to_r : launch_time(at, chain.timeline_nodes)
            @master_chains << chain
          }

          start_thread if @realtime
          chain.description
        end

        # Returns a description of the master chain, noting when a new chain
        # is waiting to start.
        def master_info
          @mutex.synchronize {
            chain = @master_chains&.last
            next 'bypass' if chain.nil?
            next chain.description if chain.started
            next "#{chain.description} (starting)" if chain.start <= @transport.position
            "#{chain.description} (starts at bar #{bar_of(chain.start)})"
          }
        end

        # Rebuilds the latest master chain from its block, cutting over at
        # +time+ (whole notes; now if nil).  Clears reverb and delay tails
        # without removing the effects (see PlaybackMethods#panic).
        def reset_master(time: nil)
          chain = @mutex.synchronize { @master_chains&.last }
          return if chain.nil? || chain.bypass? && @master_chains.length == 1

          time = nil if time && time <= @transport.position
          master(at: :now, start_time: time, fade: 0, description: chain.description, &chain.block)
        rescue => e
          raise if @raise_errors
          warn "Could not rebuild the master chain (#{e.class}: #{e.message}); bypassing it"
          master(at: :now, start_time: time, fade: 0)
        end

        # Returns true if the mix runs through any effects (not just bypass),
        # including old chains whose tails are still ringing.
        def master_active?
          @mutex.synchronize { !!@master_chains&.any? { |c| !c.bypass? } }
        end

        # Returns true if every channel of +data+ is below TAIL_THRESHOLD.
        def quiet?(data)
          data.all? { |d| d.empty? || d.abs.max < TAIL_THRESHOLD }
        end

        private

        # Builds a Chain from a master block (a bypass chain for nil).
        def build_master(block, description: nil)
          source = GraphNode::MixSource.new(channels: @channels, sample_rate: output.sample_rate)

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
            slow_warned: false
          )

          if block.nil?
            chain.description = description || 'bypass'
            return chain
          end

          chans = source.outputs
          arity = block.arity
          result = if arity == 0 || arity == 1
                     block.call(GraphNode::Channels.new(chans))
                   elsif arity < 0 || arity == @channels
                     block.call(*chans)
                   else
                     raise ArgumentError, "Give the master block one parameter (the whole mix) or #{@channels} (one per channel); got #{arity}"
                   end

          list = master_nodes(result)
          list *= @channels if list.length == 1
          unless list.length == @channels
            raise ArgumentError, "The master block returned #{list.length} channels for a #{@channels}-channel session"
          end
          chain.nodes = list

          chain.timeline_nodes = chain.nodes.uniq.flat_map { |n| [n, *n.graph] }.grep(Sequence::TimelineNode).uniq
          chain.description = description || shorten("master: #{chain.nodes.uniq.map { |n| MB::Sound.send(:playback_info, n) }.uniq.join(', ')}")
          chain
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

        # Marks a chain as started at timeline position +time+.  Called with
        # @mutex held.
        def start_master_chain(chain, time)
          chain.start = time
          chain.started = true
        end

        # Runs +mix+ through the master chains and returns the result (the mix
        # itself if there are no chains).  +playing+ is true if any player is
        # playing, for keeping clips in master chains on the timeline.
        def process_master(mix, from, to, per_sample, count, playing:, seeked:)
          chains = @mutex.synchronize { @master_chains&.dup }
          return mix if chains.nil? || chains.empty?

          # Keep clips in effects on the timeline, which pauses while idle
          resync = seeked || (playing && !@master_playing)
          @master_playing = playing

          rate = output.sample_rate.to_f
          activate_master(chains, from, to, per_sample, rate)

          out = Array.new(@channels) { Numo::SFloat.zeros(count) }
          chains.each do |c|
            c.timeline_nodes.each { |n| n.start_at(from, transport: @transport) } if resync && c.feeding

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

        # Starts a chain whose time has come, handing over from the older
        # chains at the frame where it starts in this buffer.
        def activate_master(chains, from, to, per_sample, rate)
          @mutex.synchronize {
            chain = chains.last
            return if chain.started || (chain.start >= to && @players.any?)

            # While idle the timeline doesn't advance, so start right away
            offset = chain.start >= to ? 0 : MB::M.max(((chain.start - from) / per_sample).ceil, 0)
            start_master_chain(chain, from + offset * per_sample)
            chain.timeline_nodes.each { |n| n.start_at(from, transport: @transport) }

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
          out.each_with_index do |o, idx|
            d = data[idx]
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
          results = {}
          data = c.nodes.map { |n|
            d = (results[n.__id__] ||= n.sample(count))
            raise "The master chain ended (got #{d&.length.inspect} of #{count} samples)" if d.nil? || d.length < count
            d = d.real if d.is_a?(Numo::SComplex) || d.is_a?(Numo::DComplex)
            d
          }
          check_master_speed(c, MB::U.clock_now - t, count)
          data

        rescue => e
          raise if @raise_errors
          warn "The master chain (#{c.description}) stopped with an error, so it is bypassed: #{e.class}: #{e.message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}"
          c.nodes = nil
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
        # faded out or gone quiet.
        def master_chain_done?(c)
          return false if c.equal?(@master_chains.last) || !c.started

          faded = c.gain <= 0 && c.gain_step < 0
          silent = !c.feeding && (c.bypass? || c.quiet_frames >= TAIL_QUIET_SECONDS * output.sample_rate)
          faded || silent
        end

        # Warns once if a master chain takes most of the time available for
        # its buffer.
        def check_master_speed(c, elapsed, frames)
          return unless @realtime && !c.slow_warned

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
