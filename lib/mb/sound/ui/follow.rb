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
          slow, refs = @poll.call
          @feed.slow = slow
          @feed.knob_refs = refs
        rescue => e
          warn "UI poll: #{e.class}: #{e.message}" unless @poll_warned
          @poll_warned = true
        end

        # The latest snapshot (nil without a Session; a still transport
        # before its first buffer).
        def snapshot
          return @source.call if @source
          return nil unless @attached
          @last = @feed.take || @last || Snapshot.fake(slow: @feed.slow)
        end

      end
    end
  end
end
