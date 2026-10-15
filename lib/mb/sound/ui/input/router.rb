require_relative 'events'

module MB
  module Sound
    module UI
      module Input
        # Routes input events by mode, so one stream of Actions comes from
        # keys, the palette, and MIDI alike.
        #
        # - :repl: every key goes to the REPL (the host's #repl_key), except
        #   the NAV key (Ctrl-], always) and, when #nav_esc is set, a lone
        #   Escape: held for #nav_esc seconds, it enters :nav if nothing
        #   follows, else goes to the REPL with what followed (Alt-keys,
        #   vi mode).  Pastes go to the REPL whole.
        # - :nav: keys go through NAV (numbers pick panes, z zooms, s/v
        #   split, arrows resize, u and Ctrl-R undo and redo, : the palette,
        #   / search), then the extra keymaps; Ctrl-], i, Enter, or Esc go
        #   back to :repl.
        # - :line (the palette and search prompts): keys edit a one-line
        #   input (LineInput); Enter submits, Esc cancels.
        #
        # The host receives #act(Action) for everything else.
        class Router
          # The NAV key: Ctrl-] (0x1D), distinct in every terminal (ssh,
          # tmux) and unused by Reline.
          NAV_KEY = Key.of(']', :ctrl)

          NAV = Keymap.new :nav do
            on '1'..'9', :focus_index
            on :tab, :focus_next
            on [:tab, :shift], :focus_prev
            on 'h', :focus_dir, :left
            on 'j', :focus_dir, :down
            on 'k', :focus_dir, :up
            on 'l', :focus_dir, :right
            on 'z', :zoom
            on 's', :split, :rows
            on 'v', :split, :cols
            on 'x', :close
            on '=', :equalize
            on 'u', :undo
            on ['r', :ctrl], :redo
            on ']', :tab, 1
            on '[', :tab, -1
            %i[left right up down].each do |dir|
              on dir, :resize, dir, 1
              on [dir, :shift], :resize, dir, 5
            end
            on :page_up, :scroll, :page_up
            on :page_down, :scroll, :page_down
            on ['b', :ctrl], :scroll, :page_up
            on ['f', :ctrl], :scroll, :page_down
            on 'g', :scroll, :top
            on 'G', :scroll, :bottom
            on '/', :search
            on 'n', :search_next, 1
            on 'N', :search_next, -1
            on 'y', :copy
            on ':', :palette
            on 'i', :mode, :repl
            on :escape, :mode, :repl
            on :enter, :mode, :repl
            on ['l', :ctrl], :redraw
          end

          # Keys that act in every mode (none by default; e.g.
          # `Router::GLOBAL.on ['\\', :ctrl], :panic`).
          GLOBAL = Keymap.new :global

          attr_reader :mode

          # Seconds a lone Escape waits before entering NAV (nil: Escape
          # always goes to the REPL; 0.25-0.4 is a comfortable range).
          attr_accessor :nav_esc

          # The palette or search prompt while in :line mode.
          attr_reader :line

          # +host+ responds to #repl_key(Key), #repl_paste(String),
          # #act(Action), #line_done(kind, text or nil), #mode_changed(mode).
          def initialize(host, nav: NAV, nav_esc: nil)
            @host = host
            @nav = nav
            @nav_esc = nav_esc
            @mode = :repl
            @held = nil
            @extra = []
            @midi = {}
            @last_cc = {}
          end

          # Adds a keymap consulted in :nav after NAV (pane keymaps).
          def add_keymap(map)
            @extra << map unless @extra.include?(map)
            self
          end

          # Changes mode (:repl, :nav).
          def mode=(m)
            return if m == @mode
            @mode = m
            @line = nil unless m == :line
            @host.mode_changed(m)
          end

          # Opens a one-line prompt (+kind+ :palette or :search).
          def open_line(kind, prompt, history: [])
            @line = LineInput.new(kind, prompt, history)
            @return_mode = @mode == :line ? @return_mode : @mode
            self.mode = :line
          end

          # Seconds until #tick has something to do (a held Escape), or nil.
          def wait(now)
            @held && [@held_at + @nav_esc - now, 0].max
          end

          # Acts on a held Escape whose time ran out.
          def tick(now)
            return unless @held && now - @held_at >= @nav_esc
            @held = nil
            self.mode = :nav
          end

          # Routes one event (Key, Paste, Mouse, Focus, Reply) at time +now+.
          def event(e, now = Process.clock_gettime(Process::CLOCK_MONOTONIC))
            case e
            when Paste then paste(e.text)
            when Key then key(e, now)
            else @host.act(Action.of(:event, e))
            end
          end

          def key(k, now = Process.clock_gettime(Process::CLOCK_MONOTONIC))
            if @held
              # Something followed the Escape in time: both go to the REPL
              esc = @held
              @held = nil
              @host.repl_key(esc)
              return @host.repl_key(k) unless k.chord == NAV_KEY.chord
            end

            if k.chord == NAV_KEY.chord
              return (self.mode = @mode == :nav ? :repl : :nav) unless @mode == :line
              return line_cancel
            end
            if (a = GLOBAL[k])
              return @host.act(a)
            end

            case @mode
            when :repl
              if k.key == :escape && k.mods.empty? && @nav_esc
                @held = k
                @held_at = now
                return
              end
              @host.repl_key(k)
            when :nav
              a = @nav[k] || @extra.lazy.map { |m| m[k] }.find(&:itself)
              return @host.act(a) if a
              @host.act(Action.of(:unbound, k))
            when :line
              line_key(k)
            end
          end

          # Text pasted: to the REPL, or into the prompt.
          def paste(text)
            if @mode == :line
              @line.insert(text.delete("\r\n"))
              @host.act(Action.of(:line_changed))
            else
              if @held
                @host.repl_key(@held)
                @held = nil
              end
              @host.repl_paste(text)
            end
          end

          # MIDI bindings: `map_midi(:note, 36, :zoom)`,
          # `map_midi(:cc, 21, [:resize, :right, 2])`, or a Proc.
          def map_midi(type, number, action)
            raise ArgumentError, "MIDI bindings are :note or :cc (got #{type.inspect})" unless %i[note cc].include?(type)
            raise ArgumentError, "MIDI numbers are 0..127 (got #{number.inspect})" unless (0..127).cover?(number)
            @midi[[type, number]] = action
            self
          end

          # Removes a MIDI binding.
          def unmap_midi(type, number)
            @midi.delete([type, number])
            self
          end

          # MIDI bindings ({[type, number] => action}).
          def midi_map
            @midi.dup
          end

          # A MIDI event (+type+ :note or :cc, +number+, +value+ 0..1):
          # notes act on note-on, CCs when they cross 0.5 upward (a button),
          # so a held pad doesn't repeat.  Returns the Action, or nil.
          def midi(type, number, value)
            binding = @midi[[type, number]] or return nil
            if type == :cc
              was = @last_cc[number] || 0
              @last_cc[number] = value
              return nil unless was < 0.5 && value >= 0.5
            else
              return nil unless value > 0
            end
            a = binding.is_a?(Proc) ? Action.of(:call, binding) : Action.of(*Array(binding))
            @host.act(a)
            a
          end

          private

          def line_key(k)
            l = @line
            case k.key
            when :enter
              kind = l.kind
              text = l.text
              l.remember
              @line = nil
              self.mode = @return_mode || :repl
              @host.line_done(kind, text)
              return
            when :escape then return line_cancel
            when :backspace then k.mods.include?(:alt) ? l.delete_word : l.backspace
            when :left then l.move(-1)
            when :right then l.move(1)
            when :home then l.move(-l.cursor)
            when :end then l.move(l.text.length)
            when :up then l.history_step(-1)
            when :down then l.history_step(1)
            when :tab then @host.act(Action.of(:complete))
            else
              if k.text?
                l.insert(k.key)
              elsif k.mods == [:ctrl]
                case k.key
                when 'a' then l.move(-l.cursor)
                when 'e' then l.move(l.text.length)
                when 'u' then l.kill_back
                when 'w' then l.delete_word
                when 'c' then return line_cancel
                end
              end
            end
            @host.act(Action.of(:line_changed))
          end

          def line_cancel
            kind = @line&.kind
            @line = nil
            self.mode = @return_mode || :repl
            @host.line_done(kind, nil)
          end
        end

        # A one-line prompt (the palette, search): text, cursor, history.
        class LineInput
          attr_reader :kind, :prompt, :text, :cursor

          def initialize(kind, prompt, history)
            @kind = kind
            @prompt = prompt
            @history = history
            @hpos = history.length
            @text = +''
            @cursor = 0
          end

          def insert(s)
            @text.insert(@cursor, s)
            @cursor += s.length
          end

          def backspace
            return if @cursor == 0
            @text.slice!(@cursor - 1)
            @cursor -= 1
          end

          def delete_word
            start = @text[0, @cursor].rstrip.rindex(/[\s.(:,]/)
            start = start ? start + 1 : 0
            @text.slice!(start...@cursor)
            @cursor = start
          end

          def kill_back
            @text.slice!(0, @cursor)
            @cursor = 0
          end

          def move(n)
            @cursor = (@cursor + n).clamp(0, @text.length)
          end

          def history_step(d)
            return if @history.empty?
            @hpos = (@hpos + d).clamp(0, @history.length)
            @text = (@history[@hpos] || '').dup
            @cursor = @text.length
          end

          def remember
            @history << @text.dup unless @text.empty? || @history.last == @text
            @history.shift while @history.length > 100
          end
        end
      end
    end
  end
end
