module MB
  module Sound
    # The one-line progress of a file render (PlaybackMethods#render;
    # ux-fix-1, 2026-10-18: renders of one section pre-rolled 30 bars
    # unheard with no output for half a minute).  In a terminal that
    # animates (ColorPolicy.animate?) it redraws one line on +io+ at most
    # every UPDATE_SECONDS: `render nb.flac  pre-roll bar 21 → :drop` then
    # `render nb.flac  bar 35  0:07 written`; elsewhere (logs, pipes) it
    # prints nothing per buffer.  #notice prints a line either way.
    class RenderProgress
      # Wall-clock seconds between redraws.
      UPDATE_SECONDS = 0.25

      # Pre-rolls longer than this many bars mention the faster seek.
      LONG_PREROLL_BARS = 8

      # +label+ names the render (the file); +session+ is the rendering
      # Session.
      def initialize(session, label:, io: $stderr, animate: ColorPolicy.animate?(io))
        @session = session
        @label = label
        @io = io
        @animate = animate
        @last = nil
        @shown = false
        @phase = nil
      end

      # Redraws the line (throttled): +phase+ is :preroll (with +target+,
      # the window's start) or :render (with +frames+ written so far).
      def update(phase, frames: 0, target: nil)
        return unless @animate

        now = MB::U.clock_now
        return if @last && now - @last < UPDATE_SECONDS && phase == @phase

        @last = now
        @phase = phase
        bar = @session.transport.bar_at(@session.transport.position).floor
        text = if phase == :preroll
                 "render #{@label}  pre-roll bar #{bar} → #{target.inspect}"
               else
                 "render #{@label}  bar #{bar}  #{clock(frames.to_f / @session.output.sample_rate)} written"
               end
        @io.write("\r\e[K#{text}")
        @io.flush
        @shown = true
      end

      # Prints +text+ on a line of its own (above the progress line).
      def notice(text)
        clear
        @io.puts(text)
      end

      # Erases the progress line.
      def clear
        return unless @shown

        @io.write("\r\e[K")
        @io.flush
        @shown = false
      end

      # "m:ss" for +seconds+.
      def clock(seconds)
        format('%d:%04.1f', seconds / 60, seconds % 60)
      end
    end
  end
end
