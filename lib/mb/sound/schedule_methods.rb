module MB
  module Sound
    # Methods included in MB::Sound for arranging background playback over
    # time: running blocks at bars on the Session timeline.
    #
    # The #bg, #stop, #outro, #panic, #resume, and #bpm commands inside a
    # scheduled block take effect exactly at the scheduled time.  Blocks run
    # a little ahead of time; if one takes so long that its time passes, its
    # commands are skipped with a warning.  Schedules follow the timeline,
    # which only moves while something is playing.
    #
    # Bars count from 1, like SequenceMethods#seek.
    #
    # Example (bin/sound.rb):
    #     bg :pad, pad_graph
    #     at_bar 9 do
    #       bg :drums, drum_graph
    #       stop :pad, fade: 0
    #     end
    #     every(4, offset: 3) { bg :fill, fill_graph, fade: 0 }
    #     at_bar(25) { outro }
    module ScheduleMethods
      # Runs the block at the start of +bar+ (counting from 1), or at +:beat+
      # (a quarter-note beat within the bar, counting from 1).  Instead of
      # a bar, or with one, launch points work as for #bg (see LaunchPoint):
      # +in:+ that long from now, +at:+ a position (bar(n)), and +on:+ to
      # align to a grid (`at_bar 9, on: :beat`, `at_bar in: 2.beats`,
      # `at_bar on: :bar`).  Returns a schedule handle (prints when it runs,
      # e.g. `at_bar 9 runs 9:1`; #cancel), or nil if that time has already
      # passed.
      def at_bar(bar = nil, beat: 1, at: nil, on: nil, in: nil, &block)
        raise ArgumentError, 'Pass a block to run' unless block
        point = LaunchPoint.of(binding) or return nil
        session = Session.current

        if bar.nil?
          raise ArgumentError, 'Give a bar number or a launch point (e.g. at_bar 9, at_bar in: 2.beats, at_bar at: bar(9))' unless point.given?
          raise ArgumentError, 'beat: goes with a bar number (or write at: bar(n, beat: b))' unless beat == 1
          time = launch_position(session, point)
          return nil if time.nil?
          return session.schedule(time, description: "bar #{session.transport.bar_at(time).floor}", label: "at_bar #{point_text(point)}", &block)
        end

        raise ArgumentError, "Bar must be a number of at least 1 (got #{bar.inspect})" unless bar.is_a?(Numeric) && bar >= 1
        raise ArgumentError, "Beat must be a number of at least 1 (got #{beat.inspect})" unless beat.is_a?(Numeric) && beat >= 1
        raise ArgumentError, 'Give a bar number or at:/in:, not both (on: aligns from the bar)' if point.at || point.offset

        time = session.transport.bar_position(bar) + (beat.to_r - 1) / 4
        description = beat == 1 ? "bar #{bar}" : "bar #{bar} beat #{beat}"
        label = beat == 1 ? "at_bar #{bar}" : "at_bar #{bar}, beat: #{beat}"

        if time < session.transport.position
          warn "Not scheduling for #{description}: the timeline is already at bar #{session.transport.bar} beat #{session.transport.beat}"
          return nil
        end

        if point.on
          time = LaunchPoint.on(point.on)&.resolve(now: time, transport: session.transport) or return nil
          description = "bar #{session.transport.bar_at(time).floor}"
          label += ", on: #{point.on.inspect}"
        end

        session.schedule(time, description: description, label: label, &block)
      end
      alias on_bar at_bar

      # An absolute timeline position for the +at:+ keyword of #bg, #go,
      # #mute, and the other commands (see LaunchPoint): the start of bar
      # +bar+ (counting from 1, like #at_bar, so bar(1) is the start of the
      # timeline), or quarter-note +:beat+ within it (counting from 1).
      #
      #     go :drop, at: bar(33)
      #     bg :fill, fill, at: bar(16, beat: 4)
      def bar(bar, beat: 1)
        LaunchPoint::Bar.new(bar: bar, beat: beat)
      end

      # Runs the block +bars+ bars (a number, or a Duration like 2.bars) from
      # the next bar line (so `after 1` runs at the next bar).  Launch points
      # work too: `after in: 3.beats` (exactly that long from now), `after
      # 2, on: :beat`.  Returns a schedule handle (see #at_bar).
      def after(bars = nil, at: nil, on: nil, in: nil, &block)
        raise ArgumentError, 'Pass a block to run' unless block
        point = LaunchPoint.of(binding) or return nil
        session = Session.current
        t = session.transport

        if bars.nil?
          raise ArgumentError, 'Give a number of bars or a launch point (e.g. after 2, after in: 3.beats)' unless point.given?
          time = launch_position(session, point)
          return nil if time.nil?
          return session.schedule(time, description: "bar #{t.bar_at(time).floor}", label: "after #{point_text(point)}", &block)
        end

        raise ArgumentError, 'Give a number of bars or at:/in:, not both (on: aligns from the bars)' if point.at || point.offset
        label = "after #{bars.inspect}"
        bars = Sequence::Duration.bars(bars, t.bar_length, transport: t)
        raise ArgumentError, "Bars must be a number of at least 1 (got #{bars.inspect})" unless bars.is_a?(Numeric) && bars >= 1

        first = t.next_bar_line(session.now)
        time = t.bar_position(t.bar_at(first) + bars.to_r - 1)
        if point.on
          time = LaunchPoint.on(point.on)&.resolve(now: time, transport: t) or return nil
          label += ", on: #{point.on.inspect}"
        end
        session.schedule(time, description: "bar #{t.bar_at(time).floor}", label: label, &block)
      end

      # Runs the block every +bars+ bars, on bar +:offset+ + 1 of each group
      # (e.g. `every 4, offset: 3` runs on bars 4, 8, 12, ... for fills),
      # starting with the next such bar.  +bars+ and +:offset+ may also be
      # Durations (e.g. `every 2.beats`).  A launch point instead of
      # +:offset+ sets the first time (`every 1.n4, on: :beat`, `every 4,
      # at: bar(9)`, `every 2, in: 1.beat`).  Returns a schedule handle (see
      # #at_bar).
      def every(bars, offset: 0, at: nil, on: nil, in: nil, &block)
        raise ArgumentError, 'Pass a block to run' unless block
        point = LaunchPoint.of(binding) or return nil
        session = Session.current
        t = session.transport
        label = "every #{bars.inspect}"
        bars = Sequence::Duration.bars(bars, t.bar_length, transport: t)
        offset = Sequence::Duration.bars(offset, t.bar_length, transport: t)
        raise ArgumentError, "Bars must be a positive number (got #{bars.inspect})" unless bars.is_a?(Numeric) && bars > 0
        raise ArgumentError, "Offset must be a number from 0 up to the bar count (got #{offset.inspect})" unless offset.is_a?(Numeric) && offset >= 0 && offset < bars

        if point.given?
          raise ArgumentError, 'Give offset: or a launch point (at:, on:, in:), not both' unless offset == 0
          time = launch_position(session, point)
          return nil if time.nil?
          label += ", #{point_text(point)}"
          description = "every #{bars} bars from #{Session::Stamp.at(time, t)}"
        else
          # The first bar line whose number is offset more than a multiple
          # of bars (counting from bar 1, through the meter map)
          b = t.bar_at(session.now)
          n = ((b - 1 - offset.to_r) / bars.to_r).ceil * bars.to_r + 1 + offset.to_r
          time = t.bar_position(n)
          description = "every #{bars} bars from bar #{t.bar_at(time).floor}"
          label += ", offset: #{offset.inspect}" unless offset == 0
        end

        # The period is in whole notes at the first run's meter
        period = bars.to_r * t.bar_length(time)
        session.schedule(time, period: period, description: description, label: label, &block)
      end

      # Lists the scheduled blocks that haven't run yet (and repeating
      # ones), soonest first: schedule handles that print when each runs.
      def scheduled
        Session.current.scheduled
      end

      # Cancels scheduled blocks (handles returned by #at_bar, #after,
      # #every, or their ids; every block they scheduled if none are
      # given).  Returns the handles cancelled.  `handle.cancel` works too.
      # See #reset_scheduler to also stop a song form and a stuck
      # scheduler.
      def cancel(*schedules)
        Session.current.cancel(*schedules)
      end

      # The scheduler's panic button, leaving the players alone (see
      # PlaybackMethods#panic for everything at once): stops the song form
      # (if one plays), cancels every scheduled block, and if the scheduler
      # thread died or a block has been running for over a second more,
      # stops it and starts a fresh one.  Prints what it did.  Returns the
      # cancelled schedule handles.
      def reset_scheduler
        report = Session.current.reset_scheduler
        message = Session::Scheduler.reset_message(report)
        warn "reset_scheduler: #{message}" if message
        report[:cancelled]
      end

      private

      # A launch point as a schedule label shows it: `in: 3 beats, on: :bar`.
      def point_text(point)
        show = ->(v) { v.is_a?(Length) ? v.to_s : v.inspect }
        [
          point.at && "at: #{point.at}",
          point.offset && "in: #{show.(point.offset)}",
          point.on && "on: #{show.(point.on)}",
        ].compact.join(', ')
      end

      # The timeline position (whole notes) of launch point +point+ for a
      # schedule, counting from Session#now, or nil (live mode, invalid).
      def launch_position(session, point)
        session.send(:launch_time, point, [], default: nil)
      end
    end
  end
end
