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
      # (a quarter-note beat within the bar, counting from 1).  Returns a
      # schedule id for #cancel, or nil if that time has already passed.
      def at_bar(bar, beat: 1, &block)
        raise ArgumentError, "Bar must be a number of at least 1 (got #{bar.inspect})" unless bar.is_a?(Numeric) && bar >= 1
        raise ArgumentError, "Beat must be a number of at least 1 (got #{beat.inspect})" unless beat.is_a?(Numeric) && beat >= 1

        session = Session.current
        time = session.transport.bar_position(bar) + (beat.to_r - 1) / 4
        description = beat == 1 ? "bar #{bar}" : "bar #{bar} beat #{beat}"

        if time < session.transport.position
          warn "Not scheduling for #{description}: the timeline is already at bar #{session.transport.bar} beat #{session.transport.beat}"
          return nil
        end

        session.schedule(time, description: description, &block)
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
      # the next bar line (so `after 1` runs at the next bar).  Returns a
      # schedule id for #cancel.
      def after(bars, &block)
        session = Session.current
        t = session.transport
        bars = Sequence::Duration.bars(bars, t.bar_length, transport: t)
        raise ArgumentError, "Bars must be a number of at least 1 (got #{bars.inspect})" unless bars.is_a?(Numeric) && bars >= 1

        first = t.next_bar_line(t.position)
        time = t.bar_position(t.bar_at(first) + bars.to_r - 1)
        session.schedule(time, description: "bar #{t.bar_at(time).floor}", &block)
      end

      # Runs the block every +bars+ bars, on bar +:offset+ + 1 of each group
      # (e.g. `every 4, offset: 3` runs on bars 4, 8, 12, ... for fills),
      # starting with the next such bar.  +bars+ and +:offset+ may also be
      # Durations (e.g. `every 2.beats`).  Returns a schedule id for #cancel.
      def every(bars, offset: 0, &block)
        session = Session.current
        t = session.transport
        bars = Sequence::Duration.bars(bars, t.bar_length, transport: t)
        offset = Sequence::Duration.bars(offset, t.bar_length, transport: t)
        raise ArgumentError, "Bars must be a positive number (got #{bars.inspect})" unless bars.is_a?(Numeric) && bars > 0
        raise ArgumentError, "Offset must be a number from 0 up to the bar count (got #{offset.inspect})" unless offset.is_a?(Numeric) && offset >= 0 && offset < bars

        # The first bar line whose number is offset more than a multiple of
        # bars (counting from bar 1, through the meter map); the period is
        # in whole notes at that bar's meter
        b = t.bar_at(t.position)
        n = ((b - 1 - offset.to_r) / bars.to_r).ceil * bars.to_r + 1 + offset.to_r
        time = t.bar_position(n)
        period = bars.to_r * t.bar_length(time)

        session.schedule(time, period: period, description: "every #{bars} bars from bar #{t.bar_at(time).floor}", &block)
      end

      # Returns a Hash from schedule id to a description of when it runs.
      def scheduled
        Session.current.scheduled
      end

      # Cancels scheduled blocks (all of them if no ids are given).  Returns
      # the ids that were cancelled.
      def cancel(*ids)
        Session.current.cancel(*ids)
      end
    end
  end
end
