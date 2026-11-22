require_relative 'number_nudge'

module MB
  module Sound
    module UI
      # The prompt's number nudge (repl-scrub-1, 2026-11-21; the
      # maintainer's takes of that day recalled and edited one long line
      # fifty to sixty times, changing one number per try): with the
      # cursor on or right after a number, Alt-Up/Alt-Down steps it in
      # place (UI::NumberNudge's rule) and runs the line again, exactly as
      # Enter would (Pry's eval, the take, the journal, undo), landing where
      # the same command typed again lands (`fx`, `track`, `swap`: their
      # usual launch point).  The edited line comes back on the next prompt
      # with the cursor where it was, ready for the next nudge.
      #
      #     Alt-Up Alt-Down              one step (300 -> 301, 0.125 -> 0.126)
      #     Alt-Shift-Up/Down            a fine step (0.125 -> 0.1251; refused on an Integer)
      #     Ctrl-Alt-Up/Down             a coarse step (10 steps)
      #     Alt-Shift-Right/Left         the cursor to the next, previous number
      #     Esc, then the same arrows    the same, for terminals that eat Alt-arrows
      #                                  (the arrow within Reline's keyseq timeout,
      #                                  0.5 s; measured reliable to 0.3 s, tiles too)
      #
      # With the cursor off every number, the first nudge moves it to the
      # nearest number (the next one, else the last) without changing it.
      # A numeric argument steps that many times (Alt-5 Alt-Up: 5 steps).
      # Keys arriving within SETTLE seconds of each other are one run of
      # the line (a held key, or presses typed while the line still ran:
      # the latest text runs once, when the keys stop); a key other than a
      # nudge in that time leaves the edit on the prompt for Enter.  An
      # incomplete buffer is only edited.  A line that fails prints its
      # error as Enter's would and stays on the prompt with the stepped
      # number (nothing is rolled back).  History keeps the line as it was
      # recalled plus one entry for the latest nudged version (UI::
      # NudgeHistory), not one per step.
      #
      # Reline *default* bindings (MB::Term::Input::RelineKeys.bind), so an
      # inputrc binding of the same bytes wins; an inputrc can bind other
      # bytes to these functions by name (`"\e[1;9A": mb-sound-nudge-up`).
      # Inside the tiles the REPL pane passes the keys' bytes to the same
      # Reline.  Refused nudges (no number on the line, a hex literal, a
      # fine step of an Integer) flash on the tiles' status line, or ring
      # the terminal's bell without a screen.  Prepended to
      # Reline::LineEditor by .install! (bin/sound.rb).
      module NudgeKeys
        # [key names for the docs, byte sequences, LineEditor method].
        # Each key: the xterm form (Konsole, VTE, iTerm2 with Option as
        # Esc+, the tiles' forwarding), Esc then the key (terminals that
        # send Alt as an Esc prefix, or Esc typed by hand), and the "meta"
        # modifier forms some macOS terminals send (1;9, 1;10, 1;13).
        BINDINGS = [
          ['Alt-Up', ["\e[1;3A", "\e\e[A", "\e[1;9A"], :mb_sound_nudge_up],
          ['Alt-Down', ["\e[1;3B", "\e\e[B", "\e[1;9B"], :mb_sound_nudge_down],
          ['Alt-Shift-Up', ["\e[1;4A", "\e\e[1;2A", "\e[1;10A"], :mb_sound_nudge_up_fine],
          ['Alt-Shift-Down', ["\e[1;4B", "\e\e[1;2B", "\e[1;10B"], :mb_sound_nudge_down_fine],
          ['Ctrl-Alt-Up', ["\e[1;7A", "\e\e[1;5A", "\e[1;13A"], :mb_sound_nudge_up_coarse],
          ['Ctrl-Alt-Down', ["\e[1;7B", "\e\e[1;5B", "\e[1;13B"], :mb_sound_nudge_down_coarse],
          ['Alt-Shift-Right', ["\e[1;4C", "\e\e[1;2C", "\e[1;10C"], :mb_sound_number_next],
          ['Alt-Shift-Left', ["\e[1;4D", "\e\e[1;2D", "\e[1;10D"], :mb_sound_number_prev],
        ].freeze

        # Seconds a nudge waits for another key before it runs the line.
        SETTLE = 0.15

        class << self
          # Seconds a nudge waits for another key (SETTLE unless set).
          attr_writer :settle
          def settle = @settle || SETTLE

          # What a refused nudge does, for specs: a Proc called with the
          # reason (nil: flash or bell).
          attr_accessor :handler

          # Prepends the editor methods, adds the bindings, and installs
          # NudgeHistory (once).  Returns true if Reline is there.
          def install!
            return false unless defined?(::Reline::LineEditor)
            ::Reline::LineEditor.prepend(self) unless ::Reline::LineEditor.ancestors.include?(self)
            unless @bound
              BINDINGS.each { |_name, seqs, func| seqs.each { |s| MB::Term::Input::RelineKeys.bind(s, func) } }
              @bound = true
            end
            NudgeHistory.install!
            true
          end

          # Shows why a nudge can't happen: the tiles' status line, else
          # the terminal's bell (through Reline).
          def refuse(reason)
            return @handler.call(reason) if @handler
            t = Thread.current[:mb_sound_ui_tiles]
            t ||= UI.tiles if UI.respond_to?(:tiles) && UI.tiles&.active? && !UI.tiles.hidden?
            if t
              t.act(MB::Term::Input::Action.of(:refused, 'nudge', reason))
            else
              ::Reline.core.io_gate.write("\a")
            end
            nil
          rescue IOError, SystemCallError
            nil
          end

          # True if another key arrives within +seconds+ (Reline's input
          # has bytes waiting).
          def more_input?(seconds)
            io = ::Reline.core.io_gate
            return false unless io.respond_to?(:in_pasting?)
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
            loop do
              return true if io.in_pasting?
              return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              sleep 0.005
            end
          end

          # Puts +lines+ back on the next prompt with the cursor on line
          # +line_index+ at byte +byte_pointer+ (Reline.pre_input_hook,
          # chained to a hook already set).
          def prefill(lines, line_index, byte_pointer)
            prev = ::Reline.pre_input_hook
            ::Reline.pre_input_hook = lambda do
              ::Reline.pre_input_hook = prev
              prev&.call
              ::Reline.core.line_editor.mb_sound_nudge_restore(lines, line_index, byte_pointer)
            end
          end

          # Marks +text+ as the line a nudge is running (for NudgeHistory).
          def submitting(text)
            @submitted = text
          end

          # True (once) if +line+ is the line a nudge ran.
          def take_submitted(line)
            s = @submitted
            return false unless s
            @submitted = nil
            s.chomp == line.to_s.chomp
          end
        end

        # Sets the buffer to +lines+ with the cursor on line +line_index+ at
        # byte +byte_pointer+ (the next prompt's line after a nudge ran).
        def mb_sound_nudge_restore(lines, line_index, byte_pointer)
          @buffer_of_lines = lines.map(&:dup)
          @buffer_of_lines = [+''] if @buffer_of_lines.empty?
          @line_index = line_index.clamp(0, @buffer_of_lines.length - 1)
          @byte_pointer = byte_pointer.clamp(0, @buffer_of_lines[@line_index].bytesize)
        end

        private

        def mb_sound_nudge_up(_key, arg: 1) = mb_sound_nudge(arg, :normal)
        def mb_sound_nudge_down(_key, arg: 1) = mb_sound_nudge(-arg, :normal)
        def mb_sound_nudge_up_fine(_key, arg: 1) = mb_sound_nudge(arg, :fine)
        def mb_sound_nudge_down_fine(_key, arg: 1) = mb_sound_nudge(-arg, :fine)
        def mb_sound_nudge_up_coarse(_key, arg: 1) = mb_sound_nudge(arg, :coarse)
        def mb_sound_nudge_down_coarse(_key, arg: 1) = mb_sound_nudge(-arg, :coarse)
        def mb_sound_number_next(_key, arg: 1) = mb_sound_number_jump(arg)
        def mb_sound_number_prev(_key, arg: 1) = mb_sound_number_jump(-arg)

        # The buffer as one String and the cursor's byte offset in it.
        def mb_sound_nudge_code
          code = @buffer_of_lines.join("\n")
          pos = @buffer_of_lines.first(@line_index).sum { |l| l.bytesize + 1 } + @byte_pointer
          [code, pos]
        end

        # Puts the cursor at byte offset +pos+ of the buffer (+lines+ the
        # new buffer, else as it is).
        def mb_sound_nudge_place(pos, lines = nil)
          @buffer_of_lines = lines if lines
          line = 0
          while line < @buffer_of_lines.length - 1 && pos > @buffer_of_lines[line].bytesize
            pos -= @buffer_of_lines[line].bytesize + 1
            line += 1
          end
          @line_index = line
          @byte_pointer = pos.clamp(0, @buffer_of_lines[line].bytesize)
        end

        def mb_sound_nudge(steps, size)
          code, pos = mb_sound_nudge_code
          unless NumberNudge.at(code, pos)
            lit = NumberNudge.nearest(code, pos) or return NudgeKeys.refuse('no number on this line')
            return mb_sound_nudge_place(lit.stop - 1)
          end
          r = NumberNudge.nudge(code, pos, steps, size)
          mb_sound_nudge_place(r[:pos], r[:code].split("\n", -1))
          mb_sound_nudge_run
        rescue NumberNudge::Refused => e
          NudgeKeys.refuse(e.message)
        end

        def mb_sound_number_jump(dir)
          code, pos = mb_sound_nudge_code
          lit = nil
          dir.abs.times do
            n = NumberNudge.neighbor(code, lit ? lit.stop - 1 : pos, dir <=> 0) or break
            lit = n
          end
          return NudgeKeys.refuse("no number #{dir > 0 ? 'after' : 'before'} the cursor") unless lit
          mb_sound_nudge_place(lit.stop - 1)
        end

        # Runs the edited line as Enter would, unless another key follows
        # within NudgeKeys.settle (that key's nudge runs it) or the buffer
        # is incomplete Ruby (only edited).
        def mb_sound_nudge_run
          return if NudgeKeys.more_input?(NudgeKeys.settle)
          return if @is_multiline && @confirm_multiline_termination_proc && !confirm_multiline_termination

          lines = whole_lines
          NudgeKeys.prefill(lines, @line_index, @byte_pointer)
          NudgeKeys.submitting(lines.join("\n"))
          process_insert(force: true)
          finish
        end
      end

      # Pry's history for nudged lines (UI::NudgeKeys): the first nudge of
      # a run adds the line once, each further one replaces that entry
      # while it is the newest, so sixty steps are one entry beside the
      # line as it was recalled.  The history file gets the latest version
      # when the next line is entered (or at exit), not every step.
      # Prepended to Pry::History by NudgeKeys.install!.
      module NudgeHistory
        class << self
          def install!
            return unless defined?(::Pry::History)
            ::Pry::History.prepend(self) unless ::Pry::History.ancestors.include?(self)
          end

          # The nudged line not yet written to the history file: [history,
          # line], or nil.
          attr_accessor :pending

          # Writes the pending nudged line to its history's file.
          def flush
            h, line = @pending
            @pending = nil
            h&.mb_sound_nudge_save(line)
          end

          # ExitClose: the last nudged line reaches the file at exit.
          def close = flush
        end

        def push(line)
          unless NudgeKeys.take_submitted(line)
            NudgeHistory.flush
            @mb_sound_nudge_last = nil
            return super
          end
          return line if line.empty?

          if !@history.empty? && @history[-1] == line
            # (Reline added it already: readline with add_history, as the
            # tiles' own Pry thread reads; the run's previous entry goes)
            @history.delete_at(-2) if @mb_sound_nudge_last && @history.length > 1 && @history[-2] == @mb_sound_nudge_last
          elsif @mb_sound_nudge_last && !@history.empty? && @history[-1] == @mb_sound_nudge_last
            @history[-1] = line
          else
            NudgeHistory.flush
            @history << line
            @history_line_count += 1
          end
          @mb_sound_nudge_last = line
          NudgeHistory.pending = [self, line]
          ExitClose.register(NudgeHistory) if defined?(ExitClose)
          line
        end

        # (Pry's `alias << push` names the original method: Pry::Instance
        # pushes with <<)
        def <<(line) = push(line)

        # Writes +line+ to the history file as Pry's #push would.
        def mb_sound_nudge_save(line)
          @saver.call(line) if !should_ignore?(line) && ::Pry.config.history_save
        end
      end
    end
  end
end
