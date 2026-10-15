module MB
  module Sound
    class Session
      # The Session's side of the terminal UI's feed (MB::Sound::UI::Feed,
      # design/notes/terminal_ui.md): the render thread hands the feed each
      # buffer's mix and, when the feed wants a new snapshot, the players,
      # buses, and master chains with the CPU time each took since the last
      # one.  The UI never calls Session methods that take the render lock
      # (like #players) per frame; everything fast comes through here.
      module UIFeed
        # A player, bus, or master chain as the UI sees it: +name+, +kind+
        # (:player, :bus, :master), +state+ (:playing, :starting,
        # :stopping, :fading, :ringing, :muted, :asleep), and +cpu+ (seconds
        # its graph took since the feed last read it).
        UIPart = Data.define(:name, :kind, :state, :cpu)

        # The terminal UI feed attached to this Session (see UI::Feed), or
        # nil.
        attr_reader :ui_feed

        # Attaches (or with nil detaches) a terminal UI feed: the render
        # thread calls its #capture (with the render lock held, when it
        # #wants_capture?) and #publish (after each buffer is written).
        # Graphs' CPU times are counted only while a feed is attached.
        def ui_feed=(feed)
          @ui_feed = feed
        end

        # The players, buses, and master chains with their CPU time since
        # the last call, resetting the counts (an Array of UIPart).  Called
        # by the feed on the render thread with the render lock held.
        def ui_parts
          out = []
          players = @mutex.synchronize { @players.values }
          players.group_by(&:name).each do |name, list|
            p = list.find(&:current?) || list.first
            cpu = 0.0
            list.each { |q| cpu += q.cpu || 0.0; q.cpu = 0.0 }
            out << UIPart.new(name: name, kind: :player, state: ui_player_state(p), cpu: cpu)
          end

          (@buses || {}).each_value do |b|
            cpu = 0.0
            b.chains.each { |c| cpu += c.cpu || 0.0; c.cpu = 0.0 }
            out << UIPart.new(name: b.name, kind: :bus, state: b.asleep ? :asleep : :playing, cpu: cpu)
          end

          chains = @master_chains || []
          unless chains.empty? || chains.all?(&:bypass?)
            cpu = 0.0
            chains.each { |c| cpu += c.cpu || 0.0; c.cpu = 0.0 }
            out << UIPart.new(name: :master, kind: :master, state: :playing, cpu: cpu)
          end

          out
        end

        private

        # A player's state for #ui_parts (the same rules as #players).
        def ui_player_state(p)
          if !p.current? && p.stop_at > @transport.position
            :stopping
          elsif !p.current? && p.ring&.active
            :ringing
          elsif !p.current?
            :fading
          elsif !p.started
            :starting
          elsif p.asleep || p.strip_level == 0 && p.strip_ramp.nil?
            :muted
          else
            :playing
          end
        end
      end
    end
  end
end
