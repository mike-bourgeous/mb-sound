require 'prism'

module MB
  module Sound
    module UI
      # The tiled console (`ui :tiles`): the terminal's alternate screen,
      # owned cell by cell, with the layout's panes tiled in it and the REPL
      # (the real Pry and Reline, on an in-process pty) in its own pane with
      # a 10 000-line scrollback.  A status line at the bottom shows the
      # mode and keys.  See design/notes/terminal_ui.md.
      #
      # Threads: the input reader (real stdin, raw, decoded into events and
      # routed: REPL keys to the pty, NAV keys to the Tiler), the painter
      # (panes from Snapshots, the REPL pane from its VT, one diffed frame
      # per refresh with synchronized output), and the pty reader (Pry's
      # output into the VT).  Pry itself stays on the main thread.
      #
      #     ui :tiles                   # the default tiled layout
      #     # Ctrl-] : NAV mode (1-9 pick a pane, z zoom, s/v split, arrows
      #     #          resize, u undo, / search, : palette, i back)
      #     ui.split :cols              # the same operations from Ruby
      #     ui.save :mine               # the current tree as a layout file
      #     ui off
      class Tiles
        include Follow

        # Seconds between size checks (besides SIGWINCH).
        SIZE_CHECK = 0.5

        # Frame statistics kept.
        STATS = 2000

        # Seconds a status message shows.
        FLASH = 4.0

        # UI commands the palette runs on this screen (`split :v`); every
        # other line is evaluated in the console binding.
        COMMANDS = %i[split close zoom focus resize equalize swap show undo redo tab layout save theme mouse nav_esc scroll search copy stats].freeze

        # Keys hinted on the status line per mode.
        HINTS = {
          repl: 'Ctrl-] nav',
          nav: '1-9/hjkl pane  z zoom  s/v split  x close  arrows size  =  u/^R undo  [] tabs  / search  y copy  : cmd  i back',
        }.freeze

        attr_reader :layout_name, :tiler, :host, :router, :term, :rows, :cols, :feed, :fps, :mode

        # +layout+ a Viewports::Layout with a repl pane; +input+/+output+
        # the terminal (dup'd, so they keep reaching it after :adopt
        # reopens the process's streams); +repl+ :adopt (the console's
        # Pry) or :thread (a Pry of its own, for specs and tools);
        # +context+ the binding the palette evaluates in; +size+ [rows,
        # cols] for a terminal that won't say; +probe+ false skips the
        # terminal feature probe; other options as for Band.
        def initialize(layout:, input: STDIN, output: STDOUT, session: nil, repl: :adopt, color: :ansi256, look: :quad,
                       glyphs: UI.glyphs, size: nil, clock: nil, native: Plot.native, fps: 60, panes: UI.panes, source: nil,
                       mouse: false, nav_esc: nil, kitty: false, context: nil, probe: true, scrollback: VT::SCROLLBACK, pry: {})
          raise ArgumentError, "Layout #{layout.name.inspect} has no repl pane (`repl` in the layout block)" unless layout.repl?
          raise ArgumentError, "Unknown color mode #{color.inspect}" unless Plot::Text::Cells::MODES.key?(color)

          @layout_name = layout.name
          @input = input
          @output = output
          @session = session
          @repl_mode = repl
          @mode = color
          @look = look
          @glyphs = glyphs
          @fixed_size = size
          @clock = clock || -> { MB::U.clock_now }
          @native = native
          @fps = fps
          @panes = panes
          @source = source
          @mouse = mouse
          @kitty = kitty
          @context = context
          @probe = probe
          @scrollback = scrollback
          @pry_opts = pry
          @feed = Feed.new
          @lock = Monitor.new
          @active = false
          @frames = []
          @slowest = []
          @failures = {}
          @states = Hash.new { |h, k| h[k] = {} }
          @scroll = 0
          @palette_history = []
          @search_history = []
          @midi_seen = nil
          @rows, @cols = @fixed_size || [24, 80]
          @tiler = Viewports::Tiler.new(layout, @cols, @rows - 1)
          @router = Input::Router.new(self, nav_esc: nav_esc)
          @decoder = Input::Decoder.new
        end

        def active? = @active

        # The painter thread (nil while off).
        def thread = @painter

        # The pty reader thread of the REPL (nil while off).
        def pty_thread = @host&.reader

        # Sets up the terminal (alternate screen, raw input), moves the
        # REPL into its pane, and starts the threads (+thread: false+
        # paints only on #refresh and reads input only on #pump, for
        # specs).  Returns self.
        def start(thread: true)
          return self if @active

          @term = Term.new(input: @input.dup, output: @output.dup)
          @term.enter(mouse: @mouse, kitty: @kitty)
          features = @probe ? @term.probe : {}
          @ambiguous = features[:ambiguous] || (::Reline.core.instance_variable_get(:@ambiguous_width) rescue nil) || 1
          @glyphs = :ascii if @ambiguous == 2 && @glyphs == :unicode && ENV['MB_SOUND_UI_GLYPHS'].to_s.empty?
          @rows, @cols = terminal_size
          @tiler.resize_screen(@cols, @rows - 1)
          relayout
          r = repl_rect || Viewports::Rect.new(0, 0, [@cols, 20].min, [@rows - 1, 5].max)
          @host = Input::ReplHost.new(rows: r.h, cols: r.w, mode: @repl_mode, scrollback: @scrollback, ambiguous_width: @ambiguous,
                                      target: @context || TOPLEVEL_BINDING, pry: @pry_opts)
          @host.start
          @active = true
          @stopping = false
          install_signals
          @full = true
          @term.typed_during_probe.each { |e| handle(e) }
          if thread
            @painter = Thread.new { paint_loop }
            @reader = Thread.new { input_loop }
          end
          self
        end

        # Gives the terminal back (streams, modes, screen) and stops the
        # threads.  Safe to call twice and from at_exit.  Returns self.
        def stop
          return self unless @active

          @stopping = true
          @active = false
          [@reader, @painter].each { |t| t&.wakeup rescue nil }
          @reader&.join(0.5)
          @reader&.kill
          @painter&.join(1)
          @painter = @reader = nil
          restore_signals
          detach
          @host&.stop
          @term&.leave
          [@term&.input, @term&.output].each { |io| io&.close rescue nil }
          self
        end

        # Draws the next frame (the painter calls this at its rate).
        # Returns the bytes written (nil if nothing changed).
        def refresh(now = @clock.call)
          @lock.synchronize { refresh_unlocked(now) }
        end

        # Reads and routes pending input without the reader thread (specs).
        def pump(timeout = 0)
          read_input(timeout)
        end

        # The screen as text (plain, or with SGR codes for a color mode).
        def to_text(mode = :none)
          @lock.synchronize { @grid.to_text(mode) }
        end

        # Painter costs, as for Band#stats, plus the REPL's pty bytes and
        # reader CPU.
        def stats
          busy = @frames.select { |f| f[2] > 0 }
          written = @frames.map { |f| f[1] }.reject(&:zero?)
          {
            frames: @frames.length,
            cpu_ms: UI.percentiles(@frames.map { |f| f[0] * 1000 }),
            busy_cpu_ms: UI.percentiles(busy.map { |f| f[0] * 1000 }),
            bytes: { mean: written.empty? ? 0 : written.sum / written.length, max: written.max || 0 },
            panes: @frames.empty? ? 0 : @frames.sum { |f| f[2] }.to_f / @frames.length,
            repl_bytes: @host&.bytes_read.to_i,
            repl_reader_cpu_ms: ((@host&.reader_cpu || 0) * 1000).round(1),
            slowest: @slowest.map { |at, cpu| { at: MB::M.sigfigs(at, 4), cpu_ms: MB::M.sigfigs(cpu * 1000, 3), parts: {} } },
          }
        end

        # Panes that raised (name => message).
        def failures = @failures.dup

        # Redraws everything on the next frame.
        def invalidate
          @full = true
        end

        def inspect
          "#<UI::Tiles #{@layout_name.inspect} #{@rows}x#{@cols}, focus #{@tiler.focus.inspect}#{@tiler.layout.zoom ? ' (zoomed)' : ''}, #{@router.mode}#{@active ? '' : ' (off)'}>"
        end

        ### Commands (the console's `ui.split`, the palette's `split`)

        # Splits the focused pane (or +at+): :cols / :v beside, :rows / :s
        # below; the new pane is +name+ (default :empty1, ...; `show` puts a
        # pane there).
        def split(axis = :cols, name = nil, at: nil)
          axis = { v: :cols, s: :rows, beside: :cols, below: :rows }.fetch(axis, axis)
          tile { |t| t.split(at || t.focus, axis, name) }
        end

        # Closes the focused pane (or +name+).
        def close(name = nil) = tile { |t| t.close(name || t.focus) }

        # Toggles zooming the focused pane (or +name+).
        def zoom(name = nil) = tile { |t| t.zoom(name || t.focus) }

        # Focuses pane +name+ (or the next one).
        def focus(name = nil) = tile { |t| name ? t.focus!(name) : t.focus_next }

        # Moves the focused pane's edge +dir+ (:left, :right, :up, :down) by
        # +cells+.
        def resize(dir, cells = 1, name: nil) = tile { |t| t.resize(name || t.focus, dir, cells) }

        # Equal shares for the focused pane's siblings.
        def equalize(name = nil) = tile { |t| t.equalize(name || t.focus) }

        # Swaps panes +a+ and +b+ (default: the focused one).
        def swap(a, b = nil) = tile { |t| t.swap(a, b || t.focus) }

        # Shows pane +name+ in the focused slot (or +at+).
        def show(name, at: nil) = tile { |t| t.show(name, at: at || t.focus) }

        def undo = tile(&:undo)
        def redo = tile(&:redo)

        # The next (+dir+ 1) or previous tab.
        def tab(dir = 1) = tile { |t| t.tab(dir) }

        # The current layout (prints as Ruby), or switches to layout +name+
        # (one with a repl pane).
        def layout(name = nil)
          return @tiler.layout if name.nil?

          l = UI.tiles_layout_named(name)
          @lock.synchronize do
            @tiler.layout = l
            @layout_name = l.name
            @relayout = true
          end
          self
        end

        # Saves the current tree as layout +name+ (default: its name) in
        # UI.layouts_dir.  Returns the path.
        def save(name = @tiler.layout.name)
          l = @tiler.layout
          l = Viewports::Layout.new(name: name, root: l.root, focus: l.focus, zoom: nil, gap: l.gap) unless name == l.name && l.zoom.nil?
          path = UI.save_layout_text(name, l.to_ruby)
          UI.tile_layouts[name] = l
          flash("saved #{path}", :ok)
          path
        end

        # Changes the theme (:default, :paper, :phosphor, :mono, or one in
        # UI.layouts_dir/themes; see UI::Themes).  Without a name, the
        # theme in use.
        def theme(name = nil)
          return Themes.current if name.nil?
          Themes.use(name)
          @full = true
          self
        end

        # Turns mouse reports on or off (wheel scrolls the REPL, a click
        # focuses a pane; Shift/Option-drag still selects natively).
        def mouse(on = true)
          @mouse = on
          @term&.write(on ? "\e[?1000h\e[?1002h\e[?1006h" : "\e[?1006l\e[?1002l\e[?1000l")
          self
        end

        # Seconds a lone Escape waits before entering NAV (nil/false: Esc
        # always goes to the REPL; true: 0.3).
        def nav_esc(seconds = 0.3)
          seconds = 0.3 if seconds == true
          @router.nav_esc = seconds ? seconds.to_f : nil
          self
        end
        alias nav_esc= nav_esc

        # Scrolls the REPL pane: :page_up, :page_down, :top, :bottom, or a
        # number of lines (positive: back).  Without an argument, the lines
        # scrolled back now.
        def scroll(how = nil)
          return @scroll if how.nil?
          h = (repl_rect&.h || 10)
          max = @host ? @host.vt.scrollback.length : 0
          @scroll =
            case how
            when :page_up then @scroll + [h - 1, 1].max
            when :page_down then @scroll - [h - 1, 1].max
            when :top then max
            when :bottom then @match = nil; 0
            when Integer then @scroll + how
            else raise ArgumentError, "Scroll by :page_up, :page_down, :top, :bottom, or lines (got #{how.inspect})"
            end.clamp(0, max)
          @repl_full = true
          self
        end

        # Searches the REPL's scrollback for +pattern+ (backward), scrolling
        # to the match.  Returns [line, from, to] or nil.
        def search(pattern, dir = 1)
          @search = pattern
          vt = @host.vt
          from = @match ? @match[0] : nil
          m = @host.synchronize { vt.search(pattern, from: from, backward: dir > 0) }
          m ||= @host.synchronize { vt.search(pattern, backward: dir > 0) } if from # wrap around
          @match = m
          if m
            h = repl_rect&.h || 10
            base = vt.dropped + vt.scrollback.length
            @scroll = (base - m[0] + h / 2).clamp(0, vt.scrollback.length)
            @scroll = 0 if m[0] - base >= 0 && m[0] - base < h - h / 2 && @scroll <= h / 2
            flash("/#{pattern}", :key)
          else
            flash("not found: #{pattern}", :warn)
          end
          @repl_full = true
          m
        end

        # Copies the search match's line (or the REPL pane's visible text)
        # to the system clipboard with OSC 52.  Returns the text.
        def copy
          vt = @host.vt
          text = @host.synchronize do
            if @match
              vt.text_between(@match[0], @match[0])
            else
              h = repl_rect&.h || vt.rows
              last = vt.dropped + vt.scrollback.length + vt.rows - 1 - @scroll
              vt.text_between([last - h + 1, vt.dropped].max, last).rstrip
            end
          end
          @term&.copy(text)
          flash("copied #{text.length} characters (OSC 52)", :ok)
          text
        end

        # Binds MIDI note +note+ (a Note or number) to an action: a Symbol
        # (:zoom), an Array ([:resize, :right, 2]), or a block (any console
        # command: `ui.on(C2) { go :drop }`).
        def on(note, action = nil, &block)
          @router.map_midi(:note, note.respond_to?(:number) ? note.number.round : Integer(note), block || action)
          self
        end

        # Binds MIDI controller +number+ (acting when it crosses half way
        # up, like a button) to an action (see #on).
        def on_cc(number, action = nil, &block)
          @router.map_midi(:cc, Integer(number), block || action)
          self
        end

        ### Router host (called on the input thread)

        def repl_key(k)
          if @scroll > 0
            @scroll = 0
            @match = nil
            @repl_full = true
          end
          @host.key(k)
        end

        def repl_paste(text)
          @host.paste(text)
        end

        def mode_changed(_m)
          @full = true
        end

        def line_done(kind, text)
          @full = true
          return if text.nil? || text.strip.empty?
          case kind
          when :palette then run_palette(text)
          when :search
            @match = nil
            search(text)
          end
        end

        # Applies an Action (keys, palette, MIDI).
        def act(a)
          case a.name
          when :mode then @router.mode = a.args[0]
          when :focus_index then tile { |t| t.focus_index(a.args[0]) }
          when :focus_next then tile { |t| t.focus_next(1) }
          when :focus_prev then tile { |t| t.focus_next(-1) }
          when :focus_dir then tile { |t| t.focus_dir(a.args[0]) }
          when :zoom then zoom
          when :split then split(a.args[0] || :cols)
          when :close then close
          when :equalize then equalize
          when :undo then undo
          when :redo then self.redo
          when :tab then tab(a.args[0] || 1)
          when :resize then resize(a.args[0], a.args[1] || 1)
          when :scroll then scroll(a.args[0])
          when :search then @router.open_line(:search, '/', history: @search_history)
          when :search_next then @search ? search(@search, a.args[0] || 1) : flash('no search yet (/)', :warn)
          when :copy then copy
          when :palette then @router.open_line(:palette, ':', history: @palette_history)
          when :redraw then @full = true
          when :panic then run_safely { MB::Sound.panic }
          when :call then run_safely { a.args[0].call }
          when :line_changed then nil
          when :complete then complete_palette
          when :unbound then flash("#{a.args[0]}: not a NAV key (Ctrl-] or i: back to the REPL)", :dim)
          when :event then event(a.args[0])
          when :nop then nil
          else
            respond_to?(a.name) ? run_safely { public_send(a.name, *a.args) } : flash("unknown action #{a.name.inspect}", :warn)
          end
        rescue Viewports::Error, ArgumentError => e
          flash(e.message, :bad)
        end

        private

        def tile
          @lock.synchronize do
            yield @tiler
            @relayout = true
          end
          self
        rescue Viewports::Error => e
          flash(e.message, :bad)
          self
        end

        def flash(text, role = :text)
          @flash = [text.to_s, role, @clock.call + FLASH]
        end

        def run_safely
          r = yield
          flash("=> #{r.inspect[0, 200]}", :ok) unless r.equal?(self)
          r
        rescue StandardError, ScriptError => e
          flash("#{e.class}: #{e.message}", :bad)
          nil
        end

        # The palette: a UI command (`split :v`, `show :scope`) runs on this
        # screen with its arguments evaluated in the console binding; any
        # other Ruby is evaluated in the console binding (locals,
        # constants, and console commands as at the prompt).
        def run_palette(code)
          b = palette_binding
          parsed = Prism.parse(code)
          stmts = parsed.success? ? parsed.value.statements.body : []
          call = stmts.length == 1 && stmts[0].is_a?(Prism::CallNode) && stmts[0].receiver.nil? ? stmts[0] : nil
          if call && COMMANDS.include?(call.name) && call.block.nil?
            args = call.arguments ? call.arguments.slice : ''
            run_safely do
              a, k = b.eval("->(*a, **k) { [a, k] }.call(#{args})", '(palette)', 1)
              public_send(call.name, *a, **k)
            end
          else
            run_safely { b.eval(code, '(palette)', 1) }
          end
        end

        def palette_binding
          @context.is_a?(Binding) ? @context : (UI.console_binding || (@context ? @context.instance_eval { binding } : MB::Sound.instance_eval { binding }))
        end

        # Tab in the palette: completes a command or method name.
        def complete_palette
          l = @router.line or return
          word = l.text[0, l.cursor][/[a-z_][a-zA-Z0-9_]*\z/] or return
          names = (COMMANDS + palette_binding.receiver.public_methods(false) + palette_binding.local_variables).map(&:to_s).uniq
          found = names.select { |n| n.start_with?(word) }.sort
          if found.length == 1
            l.insert(found[0][word.length..])
          elsif found.length > 1
            common = found.reduce { |a, b| a.chars.zip(b.chars).take_while { |x, y| x == y }.map(&:first).join }
            l.insert(common[word.length..]) if common.length > word.length
            flash(found.first(12).join('  '), :dim)
          end
        end

        def event(e)
          case e
          when Input::Mouse
            r = repl_rect
            if e.button >= 64 && r&.contains?(e.x, e.y)
              scroll(e.button == 64 ? 3 : -3)
            elsif e.action == :press && e.button < 3
              name, = @tiler.rects.find { |_, rr| rr.contains?(e.x, e.y) }
              tile { |t| t.focus!(name) } if name
            end
          when Input::Focus
            @full = true if e.in
          end
        end

        ### Input thread

        def input_loop
          Thread.current.name = 'MB::Sound::UI input'
          read_input(nil) until @stopping
        rescue IOError, SystemCallError
          nil
        rescue => e
          warn "UI input: #{e.class}: #{e.message}" unless @stopping
        end

        def read_input(timeout)
          io = @term.input
          now = @clock.call
          waits = [@decoder.pending? ? @decoder.esc_timeout : nil, @router.wait(Process.clock_gettime(Process::CLOCK_MONOTONIC)), timeout].compact
          wait = waits.min
          wait = 0.25 if wait.nil? && !timeout.nil?
          ready = io.wait_readable(wait.nil? ? 0.5 : wait)
          events =
            if ready
              data = io.read_nonblock(4096, exception: false)
              return if data == :wait_readable
              raise IOError, 'terminal closed' if data.nil?
              @decoder.feed(data)
            elsif @decoder.pending?
              @decoder.flush
            else
              []
            end
          @router.tick(Process.clock_gettime(Process::CLOCK_MONOTONIC))
          events.each { |e| handle(e) }
          (@painter&.wakeup rescue nil) unless events.empty?
          now
        end

        def handle(e)
          if e.is_a?(Input::Key) && @router.mode != :line
            case e.chord
            when ['c', [:ctrl]]
              @scroll = 0
              @host.interrupt
              return
            when ['z', [:ctrl]]
              suspend
              return
            end
          end
          @router.event(e)
        rescue => e2
          flash("#{e2.class}: #{e2.message}", :bad)
        end

        # Ctrl-Z: gives the terminal back and stops the process group, as a
        # terminal's Ctrl-Z would; SIGCONT (fg) takes it again.
        def suspend
          @continued = false
          @term.leave
          Process.kill(:TSTP, 0)
          deadline = @clock.call + 0.5
          sleep 0.01 until @continued || @clock.call > deadline
          @term.enter(mouse: @mouse, kitty: @kitty)
          @full = true
        end

        ### Painter

        def paint_loop
          Thread.current.name = 'MB::Sound::UI'
          Thread.current.priority = -1
          tick = 1.0 / @fps
          until @stopping
            t = @clock.call
            begin
              refresh(t)
            rescue => e
              warn "UI painter: #{e.class}: #{e.message}" unless @painter_warned
              @painter_warned = true
            end
            left = tick - (@clock.call - t)
            sleep(left) if left > 0
          end
        rescue => e
          warn "UI painter stopped: #{e.class}: #{e.message}"
        end

        def thread_cpu
          Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
        end

        def terminal_size
          return @fixed_size if @fixed_size
          @term ? @term.size : [24, 80]
        end

        # Seconds between checks of the data files (pane files, theme, layouts).
        RELOAD = 1.0

        def reload_files(now)
          return if @reloaded_at && now - @reloaded_at < RELOAD
          @reloaded_at = now
          r = UI.reload_files
          flash(r[:errors].first, :bad) unless r[:errors].empty?
          if r[:layouts].include?(@layout_name)
            l = UI.tile_layouts[@layout_name]
            @tiler.layout = l if l
            flash("reloaded layout #{@layout_name.inspect}", :ok)
          end
          @full = true if r[:theme] || !r[:panes].empty?
          flash("reloaded panes #{r[:panes].map(&:inspect).join(', ')}", :ok) unless r[:panes].empty? || !r[:errors].empty?
        rescue StandardError => e
          flash("reload: #{e.message}", :bad)
        end

        def check_size(now)
          return unless @resized || @size_checked_at.nil? || now - @size_checked_at >= SIZE_CHECK
          @size_checked_at = now
          @resized = false
          rows, cols = terminal_size
          return if rows == @rows && cols == @cols

          @rows = rows
          @cols = cols
          @tiler.resize_screen(cols, rows - 1)
          @relayout = true
        end

        # Placements, grids, and the separators for the current tree.
        def relayout(*)
          @placed = @tiler.placed
          @placed_layout = @tiler.layout
          klass = @native ? Plot::Text::NativeCells : Plot::Text::Cells
          if @grid.nil? || @grid.width != @cols || @grid.height != @rows
            @grid = klass.new(@cols, @rows)
            @shown = klass.new(@cols, @rows)
          end
          names = @placed.map(&:name).compact
          @feed.needs = names.flat_map { |n| @panes[n]&.needs || [] }.uniq
          @canvases = {}
          @drawn_at = {}
          @relayout = false
          @full = true
          @repl_full = true
          r = repl_rect
          @host&.resize(r.h, r.w) if r && r.w > 0 && r.h > 0
        end

        def repl_rect
          p = @placed&.find { |pl| pl.name == :repl }
          p&.rect
        end

        def refresh_unlocked(now)
          cpu0 = thread_cpu
          @first_refresh ||= now
          attach
          poll(now)
          poll_midi
          check_size(now)
          reload_files(now)
          relayout if @relayout || !@placed_layout.equal?(@tiler.layout)
          snap = snapshot
          full = @full
          if full
            @grid.clear
            draw_gaps
          end

          drawn = 0
          bytes = +''
          @placed.each do |p|
            if p.tabs
              draw_tabs(p) if full
              next
            end
            if p.name == :repl
              drawn += 1 if draw_repl(p, full)
              next
            end
            pane = @panes[p.name]
            unless pane
              draw_placeholder(p) if full
              next
            end
            rate = p.opts[:rate].is_a?(Numeric) && p.opts[:rate] > 0 ? p.opts[:rate] : pane.rate
            next unless full || @drawn_at[p.name].nil? || now - @drawn_at[p.name] >= 1.0 / rate - 0.001
            begin
              r = p.rect
              if pane.bytes?
                b = pane.frame_bytes(snap, @states[p.name], row: r.y + 1, col: r.x + 1, w: r.w, h: r.h, mode: @mode, look: p.opts[:look] || @look, full: full)
                bytes << b if b
              else
                canvas = (@canvases[p.name] ||= Canvas.new(@grid, r.x, r.y, r.w, r.h, glyphs: @glyphs))
                canvas.row = 0
                pane.draw(canvas, snap, @states[p.name])
              end
              @failures.delete(p.name)
            rescue => e
              pane_failed(p, e)
            end
            @drawn_at[p.name] = now
            drawn += 1
            Thread.pass
          end
          draw_badges if @router.mode == :nav
          draw_status(now, snap)

          cells = @grid.frame(full ? nil : @shown, @mode, row: 1, col: 1, sync: false)
          cells = '' if cells == "\e[0m" || cells.empty?
          bytes = '' if bytes.delete("\e[0m").empty?
          @shown.copy_from(@grid)
          @full = false
          cursor = cursor_bytes
          out = nil
          if !cells.empty? || !bytes.empty? || cursor != @last_cursor || full
            out = "\e[?2026h\e[?25l#{full ? "\e[0m\e[H\e[2J" : ''}#{cells}#{bytes}#{cursor}\e[?2026l"
            write(out)
            @last_cursor = cursor
          end
          cpu = thread_cpu - cpu0
          @frames << [cpu, out&.bytesize || 0, drawn]
          @frames.shift if @frames.length > STATS
          note_slow(now, cpu)
          out
        end

        def note_slow(now, cpu)
          return if @slowest.length >= 5 && cpu <= @slowest[-1][1]
          @slowest << [now - @first_refresh, cpu]
          @slowest.sort_by! { |e| -e[1] }
          @slowest.pop if @slowest.length > 5
        end

        # Draws the REPL pane from its VT when it changed.  Returns true if
        # drawn.
        def draw_repl(p, full)
          return false unless @host
          changed = @host.changed!
          return false unless full || changed || @repl_full
          r = p.rect
          marks = @match ? [[@match[0], @match[1], @match[2], VT::REVERSE | VT::UNDERLINE]] : nil
          @host.synchronize do
            @host.vt.invalidate if full || @repl_full
            @scroll = @scroll.clamp(0, @host.vt.scrollback.length)
            @host.vt.draw(@grid, r.x, r.y, r.w, r.h, offset: @scroll, marks: marks)
          end
          if @scroll > 0
            tag = " #{@scroll} lines up (G: live) "
            @grid.put_run(r.x + [r.w - tag.length, 0].max, r.y, tag[0, r.w], Plot::Text::Cells.pack(Theme.rgb(:queued)), nil, Plot::Text::Cells::REVERSE)
          end
          @repl_full = false
          true
        end

        def draw_placeholder(p)
          r = p.rect
          c = Canvas.new(@grid, r.x, r.y, r.w, r.h, glyphs: @glyphs)
          c.puts [p.name.to_s, :title]
          c.puts ['an empty slot: NAV : then', :dim]
          c.puts ['show :scope (or :meters, :tracks, ...)', :dim]
          names = @panes.keys - @placed.map(&:name)
          c.puts [c.fit("panes: #{names.join(' ')}", r.w), :dim] unless names.empty?
        end

        def draw_tabs(p)
          r = p.rect
          x = r.x
          p.tabs.each_with_index do |name, i|
            label = " #{name} "
            role = i == p.active ? :key : :dim
            @grid.put_run(x, r.y, label[0, [r.x + r.w - x, 0].max], Plot::Text::Cells.pack(Theme.rgb(role)), nil, i == p.active ? Plot::Text::Cells::REVERSE : 0)
            x += label.length + 1
            break if x >= r.x + r.w
          end
        end

        # Vertical rules in the columns no pane covers (the gaps), the
        # focused pane's in the key color.
        def draw_gaps
          h = @rows - 1
          covered = Array.new(h) { Array.new(@cols, false) }
          @placed.each do |p|
            r = p.rect
            r.h.times { |dy| covered[r.y + dy]&.fill(true, r.x, r.w) }
          end
          focus = @placed.find { |p| p.name == @tiler.focus }&.rect
          glyph = Themes.glyphs(@glyphs)[:rule] || '|'
          dim = Plot::Text::Cells.pack(Theme.rgb(:dim))
          key = Plot::Text::Cells.pack(Theme.rgb(:key))
          h.times do |y|
            @cols.times do |x|
              next if covered[y][x]
              near = focus && y >= focus.y && y < focus.y + focus.h && (x == focus.x - 1 || x == focus.x + focus.w)
              @grid.put_run(x, y, glyph, near ? key : dim, nil, 0)
            end
          end
        end

        # Pane numbers in NAV mode, in each pane's top right corner.
        def draw_badges
          @tiler.numbered.each_with_index do |name, i|
            r = @placed.find { |p| p.name == name }&.rect or next
            badge = " #{i + 1} #{name == @tiler.focus ? name : ''} ".squeeze(' ')
            badge = " #{i + 1} " if badge.length > r.w
            role = name == @tiler.focus ? :key : :queued
            @grid.put_run(r.x + [r.w - badge.length, 0].max, r.y, badge, Plot::Text::Cells.pack(Theme.rgb(role)), nil, Plot::Text::Cells::REVERSE | Plot::Text::Cells::BOLD)
          end
        end

        def draw_status(now, snap)
          y = @rows - 1
          c = Canvas.new(@grid, 0, y, @cols, 1, glyphs: @glyphs)
          c.clear
          mode = @router.mode
          if mode == :line
            l = @router.line
            c.line(0, [l.prompt, :key], l.text)
            @line_cursor = [y, l.prompt.length + l.cursor]
            return
          end
          @line_cursor = nil
          badge = mode == :nav ? ' NAV ' : ' REPL '
          @grid.put_run(0, y, badge, Plot::Text::Cells.pack(Theme.rgb(mode == :nav ? :armed : :key)), nil, Plot::Text::Cells::REVERSE | Plot::Text::Cells::BOLD)
          x = badge.length + 1
          right = snap ? "#{snap.playing ? c.glyph(:play) : c.glyph(:stop)} #{snap.stamp} " : ''
          flash = @flash && now < @flash[2] ? @flash : nil
          @flash = nil if @flash && !flash
          x = c.line(0, [@tiler.focus.to_s, :name], (@tiler.layout.zoom ? [' (zoomed)', :warn] : ' '), x: x)
          room = @cols - x - right.length - 1
          if flash
            c.text(x + 1, 0, c.fit(flash[0], room), flash[1])
          else
            c.text(x + 1, 0, c.fit(HINTS[mode] || '', room), :dim)
          end
          c.text(@cols - right.length, 0, right, :key) unless right.empty?
        end

        # Where the terminal's cursor goes: the REPL's cursor in its pane,
        # the prompt's in the status line, or hidden.
        def cursor_bytes
          if @line_cursor
            return "\e[#{@line_cursor[0] + 1};#{@line_cursor[1] + 1}H\e[?25h"
          end
          r = repl_rect
          return '' unless r && @host && @router.mode == :repl && @scroll == 0
          vt = @host.vt
          row, col, visible = @host.synchronize { [vt.row, vt.col, vt.cursor_visible?] }
          return '' unless visible && row < r.h && col < r.w
          "\e[#{r.y + row + 1};#{r.x + col + 1}H\e[?25h"
        end

        def pane_failed(p, e)
          msg = "#{p.name}: #{e.class}: #{e.message}"
          @failures[p.name] = msg
          return if @panes[p.name]&.bytes?
          r = p.rect
          c = Canvas.new(@grid, r.x, r.y, r.w, r.h, glyphs: @glyphs).clear
          c.puts ["#{p.name} failed: ", :bad], [e.message, :dim]
        end

        def write(str)
          @term.write(str)
        rescue IOError, SystemCallError
          @stopping = true
        end

        # MIDI notes and controllers for `ui.on` bindings, from the
        # Session's MIDI log (read without the render lock).
        def poll_midi
          return if @router.midi_map.empty?
          s = @attached or return
          n = s.midi_log_length
          @midi_seen = n if @midi_seen.nil? || @midi_seen > n
          return if n == @midi_seen
          s.midi_log(@midi_seen).each do |_name, _epoch, _pos, bytes|
            st, d1, d2 = bytes
            next unless st && d1
            case st & 0xF0
            when 0x90 then @router.midi(:note, d1, d2.to_i / 127.0)
            when 0xB0 then @router.midi(:cc, d1, d2.to_i / 127.0)
            end
          end
          @midi_seen = n
        rescue StandardError => e
          flash("MIDI: #{e.message}", :bad)
        end

        def install_signals
          tiles = self
          old = nil
          old = Signal.trap('WINCH') do |sig|
            tiles.instance_variable_set(:@resized, true)
            old.call(sig) if old.respond_to?(:call)
          end
          @old_winch = old
          old_cont = nil
          old_cont = Signal.trap('CONT') do |sig|
            tiles.instance_variable_set(:@continued, true)
            old_cont.call(sig) if old_cont.respond_to?(:call)
          end
          @old_cont = old_cont
          @signals = true
        rescue ArgumentError
          nil
        end

        def restore_signals
          return unless @signals
          Signal.trap('WINCH', @old_winch || 'DEFAULT')
          Signal.trap('CONT', @old_cont || 'DEFAULT')
          @signals = false
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
