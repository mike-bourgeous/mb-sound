module MB
  module Sound
    module UI
      # Following a Session for a screen (Band, Tiles): attaches the screen's
      # Feed to Session.existing (or a given Session), runs the Poll for slow
      # data, and takes the newest Snapshot.  Uses @feed, @session, @source,
      # @attached, @poll, @polled_at, @last.
      module Follow
        # Seconds between Poll runs (slow data).
        POLL = 0.25

        private

        # Follows Session.existing (or the given Session): attaches the feed.
        def attach
          return if @source

          s = @session || Session.existing
          return if s.equal?(@attached)

          detach
          @attached = s
          @poll = s && Poll.new(s)
          @polled_at = nil
          s.ui_feed = @feed if s
        end

        def detach
          @attached.ui_feed = nil if @attached && @attached.ui_feed.equal?(@feed)
          @poll&.close
          @poll = nil
          @attached = nil
        end

        def poll(now)
          return if @poll.nil? || (@polled_at && now - @polled_at < Follow::POLL)
          @polled_at = now
          slow, refs = @poll.call(@feed.needs)
          @feed.slow = slow
          @feed.knob_refs = refs
        rescue => e
          warn "UI poll: #{e.class}: #{e.message}" unless @poll_warned
          @poll_warned = true
        end

        # Snapshots kept to find what is heard now.
        HEARD = 32

        # The snapshot whose audio is reaching the speakers now (ux-1 r3
        # item 32b): +snap+ (the newest) when the output has no latency,
        # else the newest kept snapshot whose time plus the output's latency
        # has passed, so meters and scopes match what is heard instead of
        # running 10-50 ms early (`vis` compensates the same way).
        def heard(snap, now)
          return snap if snap.nil? || snap.latency.to_f <= 0
          ring = (@heard ||= [])
          ring << snap unless ring.last.equal?(snap)
          ring.shift while ring.length > HEARD
          wall = MB::U.clock_now
          ring.reverse_each { |x| return x if x.heard_at <= wall }
          ring.first
        end

        # The latest snapshot (nil without a Session; a still transport
        # before its first buffer), with the latest Poll's slow data: a
        # snapshot carries the slow data of when the render thread built
        # it, and a kept one (no new buffer since) kept old tracks and
        # clips (ux-fix-1 item 18: TRACKS said `bass  no clip` while `now`
        # said `roll (playing)`).
        def snapshot
          return @source.call if @source
          return nil unless @attached
          snap = @feed.take || @last || Snapshot.fake(slow: @feed.slow)
          slow = @feed.slow
          snap = snap.with(slow: slow) unless snap.slow.equal?(slow)
          @last = snap
        end

      end
    end
  end
end
