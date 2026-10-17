module MB
  module Sound
    module UI
      # Switching between the tiled screen, the band, and nothing (ux-r3
      # item 41): leaving the tiles used to lose the REPL lines they held
      # (the alternate screen's exit brings back the normal screen as it
      # was when the tiles started) and, when the switch came from a key or
      # the palette, left Reline's prompt undrawn.  A switch is now a
      # transition with declared steps (STEPS), run in order by .run:
      #
      # - :capture_repl - the REPL pane's recent lines (UI::VT scrollback
      #   and screen, up to the cursor), before the tiles stop.
      # - :stop_tiles / :stop_band - the old screen gives the terminal back.
      # - :replay_repl - prints the captured lines on the normal screen, so
      #   the history the tiles held stays above the prompt.
      # - :start_band / :start_tiles - the new screen (its scroll region
      #   goes below or above the replayed lines).
      # - :redraw_prompt - asks Reline to draw its prompt and the line being
      #   edited again (a resize signal), when the switch came from outside
      #   the console's own evaluation; a `ui :deck` typed at the prompt
      #   gets its prompt from Pry when it returns.
      #
      # The tiled screen's console can only be given back while it is
      # evaluating: stopping it while Reline waits for a line (a switch from
      # the palette, on the screen's input thread) closed the pty under
      # Reline, which read the end of input and ended the console (found by
      # this branch's pty spec).  So a switch out of the tiles from another
      # thread is run by the console (.defer_to_console): the line being
      # edited is put aside (Ctrl-C), the command is typed into the REPL,
      # and the line comes back at the next prompt (Reline.pre_input_hook).
      module Switch
        # The screen kinds.
        KINDS = %i[off band tiles].freeze

        # Steps for each [from, to] (every pair declared).
        STEPS = {
          [:off, :off] => [],
          [:off, :band] => %i[start_band],
          [:off, :tiles] => %i[start_tiles],
          [:band, :off] => %i[stop_band],
          [:band, :band] => %i[start_band],
          [:band, :tiles] => %i[stop_band start_tiles],
          [:tiles, :off] => %i[capture_repl stop_tiles replay_repl redraw_prompt],
          [:tiles, :band] => %i[capture_repl stop_tiles replay_repl start_band redraw_prompt],
          [:tiles, :tiles] => %i[start_tiles],
        }.freeze

        # How many REPL lines a switch out of the tiles prints again.
        REPLAY_LINES = 40

        class << self
          # The kind of screen on now (:off, :band, or :tiles; a hidden
          # tiled screen counts as :off, since the console has the normal
          # screen).
          def current
            UI.tiles&.active? ? :tiles : UI.band&.active? ? :band : :off
          end

          # True if a switch out of the tiled screen must be run by the
          # console (see the module comment): the tiles are on with the
          # console's own REPL in them, and this isn't the console's thread.
          def defer?
            t = UI.tiles
            current == :tiles && t.host && t.host.mode == :adopt && !Thread.current.equal?(Thread.main)
          end

          # Types +code+ (e.g. "ui :mini") into the tiled screen's REPL for
          # the console to run, putting the line being edited aside and back
          # at the next prompt.  Returns the tiles.
          def defer_to_console(code)
            t = UI.tiles
            saved = (::Reline.line_buffer.to_s rescue '')
            unless saved.empty?
              ::Reline.pre_input_hook = -> {
                ::Reline.pre_input_hook = nil
                ::Reline.insert_text(saved)
              }
            end
            t.host.write("\x05\x15") unless saved.empty? # (Ctrl-E Ctrl-U: Reline clears the line, then reads the command)
            t.host.write("#{code}\r")
            t
          end

          # The console line for UI.show(+name+, **+opts+) or UI.off (+name+
          # :off).
          def console_line(name, opts = {})
            return 'ui off' if name == :off
            args = [name&.inspect, *opts.compact.map { |k, v| "#{k}: #{v.inspect}" }].compact
            args.empty? ? 'ui' : "ui #{args.join(', ')}"
          end

          # The steps from +from+ to +to+ (see STEPS).
          def steps(from, to)
            STEPS.fetch([from, to]) { raise ArgumentError, "No screen switch from #{from.inspect} to #{to.inspect} (#{KINDS.join(', ')})" }
          end

          # Leaves the tiled screen for +to+ (:band or :off) by the
          # declared steps up to the new screen's start, which the caller
          # does (UI.show/.off); returns the steps still to run after it
          # (see #finish).  A no-op when the tiles aren't on.
          def leave_tiles(to)
            return [] unless current == :tiles
            todo = steps(:tiles, to).dup
            lines = nil
            while (step = todo.first) && !%i[start_band redraw_prompt].include?(step)
              todo.shift
              case step
              when :capture_repl then lines = repl_lines(UI.tiles)
              when :stop_tiles then UI.tiles.stop
              when :replay_repl then replay(lines)
              end
            end
            todo.delete(:start_band)
            @from_console = Thread.current.equal?(Thread.main)
            todo
          end

          # Runs what #leave_tiles left (:redraw_prompt).
          def finish(todo)
            todo.each do |step|
              redraw_prompt if step == :redraw_prompt && !@from_console
            end
            nil
          end

          # The last +n+ lines of +tiles+' REPL pane, up to and including
          # the cursor's line when it holds the console's own command (the
          # switch was typed at the prompt), else up to the line above it
          # (Reline draws the prompt and its line again).  Trailing spaces
          # are trimmed; blank lines after the last text are dropped.
          def repl_lines(tiles, n = REPLAY_LINES)
            vt = tiles&.host&.vt
            return [] unless vt
            last = vt.dropped + vt.scrollback.length + vt.row
            last -= 1 unless Thread.current.equal?(Thread.main)
            first = [vt.dropped, last - n + 1].max
            lines = (first..last).map { |i| vt.line_at(i)&.to_s.to_s.rstrip }
            lines.shift while lines.first&.empty?
            lines.pop while lines.last&.empty?
            lines
          rescue StandardError
            []
          end

          private

          # Prints +lines+ on the normal screen.
          def replay(lines)
            return if lines.nil? || lines.empty?
            $stdout.write("\r\e[K" + lines.join("\r\n") + "\r\n")
            $stdout.flush
          rescue IOError, SystemCallError
            nil
          end

          # Makes Reline draw its prompt and line again (as on a resize).
          def redraw_prompt
            Process.kill(:WINCH, Process.pid)
          rescue SystemCallError, ArgumentError
            nil
          end
        end
      end
    end
  end
end
