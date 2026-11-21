module MB
  module Sound
    class Session
      # Pausing the transport while tails ring (pause-tails-1; the
      # maintainer's UI note, 2026-11-21: "I don't expect `pause` to
      # silence ringing effects, just stop the transport and release
      # sounding notes").  Console `pause`/`start` and NAV Space use it;
      # the old freeze (nothing rendered, silence) is #paused= (PauseFade),
      # the console's `suspend`.
      #
      # #pause_transport issues a :pause change and #play_on a :play_on
      # change, timeline changes (see Seeks#timeline_change?) that land on
      # an exact sample at any buffer size.  While paused:
      # - the timeline position stands still (#render_span's +moving+ is
      #   false), so scheduled blocks, forms, queued changes for later
      #   times, launches, and clocks wait;
      # - every player, bus, and master chain keeps rendering, so effects
      #   ring out;
      # - timeline nodes hold their place by their
      #   TimelineNode#timeline_hold_mode: clip sources release their
      #   notes at the pause sample and stop, loop and region players fade
      #   out over FADE_SECONDS and hold, musical time limits stop
      #   counting, tempo-synced nodes run on;
      # - a player with nothing that holds by itself (#holds_whole?: a
      #   drone, a file) fades out over FADE_SECONDS from the pause sample
      #   (the strip's pause level) and is then not rendered until resume.
      # #play_on releases the holds on its landing sample: held sources
      # fade back in, whole-held players ramp up, :restart nodes are
      # re-placed at the held position, and with +resync+ tempo-synced
      # nodes jump back onto the grid there.
      module TransportPause
        # The quick fade of held sources, out at the pause and in at the
        # resume (seconds; the maintainer's "quickfade mute").
        FADE_SECONDS = 0.01

        # Pauses the transport (see TransportPause) now: the change lands
        # at the next buffer's start (a take replay forces its recorded
        # landing).  Returns the change's journal entry.  Nothing happens
        # when it lands on a paused transport.
        def pause_transport
          change(:pause, :transport, nil, data: {}) { |_t| apply_pause }.entry
        end

        # Plays the paused transport on from where it stopped (see
        # TransportPause); +resync+ puts tempo-synced nodes (LFO rates,
        # synced delays) back on the bar grid.  Returns the change's
        # journal entry.  Nothing happens when it lands on a transport that
        # isn't paused.
        def play_on(resync: false)
          resync = !!resync
          change(:play_on, :transport, nil, data: { resync: resync }) { |_t| apply_play_on(resync) }.entry
        end

        # True while the transport is paused (see TransportPause; the old
        # freeze is #paused?).
        def transport_paused?
          @tp_paused
        end

        # The frames rendered since the transport paused (where a change
        # made now lands, counted from the pause's sample), or nil when it
        # isn't paused.  Takes record it for lines typed while paused.
        def pause_held_frames
          @tp_paused ? @frame - @tp_frame : nil
        end

        # The session frame where the transport paused, or nil.
        def pause_frame
          @tp_paused ? @tp_frame : nil
        end

        private

        def init_transport_pause
          @tp_paused = false
          @tp_frame = nil
        end

        # Frames in a pause fade at this Session's rate.
        def pause_fade_frames
          MB::M.max((FADE_SECONDS * output.sample_rate).round, 1)
        end

        # True if player +p+ holds as a whole while paused: nothing in it
        # holds its place by itself (a clip source releases its notes, a
        # loop or region player fades and holds).
        def holds_whole?(p)
          p.timeline_nodes.none? { |n| n.is_a?(MIDI::ClipSource) || n.is_a?(Sequence::TimelineHoldFade) }
        end

        # True if player +p+ is left alone by a pause: it is ending (ringing
        # out, fading out, or stopping) or it plays live input (a track's
        # monitor: the keyboard plays on).
        def pause_exempt?(p)
          p.ring&.active || p.fading_out || !p.stop_at.nil? || Name[p.name].monitor?
        end

        # The :pause change's action (render lock held).
        def apply_pause
          return if @tp_paused

          @tp_paused = true
          frame = @landing_frame || @frame
          @tp_frame = frame
          k = pause_fade_frames
          @mutex.synchronize { @players.values }.each do |p|
            next if pause_exempt?(p) || !holds_whole?(p)

            p.pause_whole = true
            p.pause_ramp = Fades::Ramp.after(p.pause_ramp, p.pause_level || 1.0, 0.0, frame, k)
          end
          hold_timeline_nodes
          # Live notes held on the MIDI inputs release too (their monitors
          # play on: the keyboard still plays while paused)
          @midi_lock.synchronize { @midi_inputs.values }.each(&:release_held!)
        end

        # The :play_on change's action (render lock held).
        def apply_play_on(resync)
          return unless @tp_paused

          @tp_paused = false
          @tp_frame = nil
          frame = @landing_frame || @frame
          pos = @transport.position
          k = pause_fade_frames
          @mutex.synchronize { @players.values }.each do |p|
            if p.pause_whole
              p.pause_whole = false
              p.pause_ramp = Fades::Ramp.after(p.pause_ramp, p.pause_level || 1.0, 1.0, frame, k)
            end
            release_nodes(p.timeline_nodes, pos, p.start, p.launch, resync, k) if p.started
          end
          each_paused_chain { |c| release_nodes(c.timeline_nodes, pos, c.start, c.launch, resync, k) }
        end

        # Holds the timeline nodes of every started player and every
        # master and bus chain (each span while paused: graphs started or
        # swapped in meanwhile hold too; holding is idempotent).
        def hold_timeline_nodes
          k = pause_fade_frames
          @mutex.synchronize { @players.values }.each do |p|
            next unless p.started
            next if Name[p.name].monitor?
            p.timeline_nodes.each { |n| n.timeline_hold(true, fade_frames: k) if n.timeline_hold_mode == :native }
          end
          each_paused_chain { |c| c.timeline_nodes.each { |n| n.timeline_hold(true, fade_frames: k) if n.timeline_hold_mode == :native } }
        end

        # Releases +nodes+ at timeline position +pos+ for a graph started
        # at +origin+ and launched at +launch+ (see
        # TimelineNode#timeline_hold_mode).
        def release_nodes(nodes, pos, origin, launch, resync, k)
          nodes.each do |n|
            case n.timeline_hold_mode
            when :native
              n.timeline_hold(false, fade_frames: k)
            when :runs
              n.start_at(pos, origin: origin, launch: launch, transport: @transport) if resync
            else
              n.start_at(pos, origin: origin, launch: launch, transport: @transport)
            end
          end
        end

        # Yields each started master chain and bus chain (Master::Chain:
        # #timeline_nodes, #start, #launch).
        def each_paused_chain
          chains = @mutex.synchronize {
            list = (@master_chains || []).dup
            @buses.each_value { |b| list.concat(b.chains) if b.chains }
            list
          }
          chains.each { |c| yield c if c.started && c.timeline_nodes }
        end
      end
    end
  end
end
