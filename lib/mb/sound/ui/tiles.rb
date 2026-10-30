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
      #     #          resize, u undo, / search, : palette, Enter into the
      #     #          pane, i REPL, K keyboard, Esc back)
      #     ui.split :cols              # the same operations from Ruby
      #     ui.save :mine               # the current tree as a layout file
      #     # Ctrl-Z: hide the tiles (the set plays on; the console carries
      #     #         on in the normal screen); Ctrl-Z or `ui`: back
      #     ui off
      class Tiles
        include Follow
        include FrameRate
        include Listable

        # Seconds between size checks (besides SIGWINCH).
        SIZE_CHECK = 0.5

        # Frame statistics kept.
        STATS = 2000

        # Seconds a status message shows.
        FLASH = 4.0

        # UI commands the palette runs on this screen (`split :v`); every
        # other line is evaluated in the console binding.
        COMMANDS = %i[split close zoom focus resize equalize swap show undo redo tab layout save theme mouse nav_esc scroll search copy stats keys look message].freeze

        # Keys hinted on the status line per mode.
        HINTS = {
          repl: 'Ctrl-] nav  Ctrl-W one NAV key  Alt-PgUp scroll  F2 keys',
          once: 'one NAV key, then back: arrows pane  Ctrl-W last pane  z zoom  a k t ... into  Ctrl-] stay  Esc back  ? keys',
          overlay: 'Esc closes  a key listed here closes it and acts',
          nav: '? keys  1-9/arrows pane  p last  Enter into it  i REPL  k keys  z zoom  s/v split  x close  S-arrows size  =  u/^R undo  [] tabs  / search  y copy  : cmd',
          grab: 'Ctrl-] nav  F2 back  z..m q..] notes  -/+ octave  Up/Dn velocity  Space sustain  Esc all off  Enter capture  ` note-off  Tab step',
          step: 'Ctrl-] back  z..m notes  1-7 length  8 dot  9 triplet  r rest  t tie  a accent  ` slide  BkSp undo  p play  w swap in  Enter done  Tab play',
        }.freeze

        # NAV keys of mb-sound's own panes (after Router::NAV).
        NAV_EXTRA = Keys::NAV_EXTRA

        # The keys by mode, in groups ({mode => [[group, [[keys, what],
        # ...]], ...]}), from the key table (UI::Keys): the `?` overlay
        # shows the :nav groups and the focused pane's, and `help :ui`
        # prints them (Tiles.key_table).  Built without reading the inputrc
        # (Keys.table lists the REPL keys in effect).
        KEY_HELP = Keys.table(live: false).freeze

        # +text+ as one line for a cell row: control characters become
        # spaces, and a multi-line text keeps its first line and " ...".
        def self.one_line(text)
          t = text.to_s
          first, rest = t.split("\n", 2)
          first = first.to_s.gsub(/\e\[[0-9;?]*[A-Za-z]/, '').gsub(/[\x00-\x1f\x7f]/, ' ')
          rest.to_s.strip.empty? ? first : "#{first} ..."
        end

        # The key table for +modes+ as text lines (for help :ui).
        def self.key_table(*modes)
          table = Keys.table
          modes = table.keys if modes.empty?
          modes.flat_map do |m|
            table.fetch(m).flat_map do |group, keys|
              w = keys.map { |k, _| k.length }.max
              ["#{group}:", *keys.map { |k, what| "  #{k.ljust(w)}  #{what}" }, '']
            end
          end
        end

        # Kitty keyboard protocol flags pushed while KEYS mode has the
        # keyboard: 1 (unambiguous keys), 2 (press, repeat, and release
        # events), 8 (every key as an escape code, which text keys need
        # for their releases).
        KEYS_KITTY_FLAGS = 1 | 2 | 8

        attr_reader :layout_name, :tiler, :host, :router, :term, :rows, :cols, :feed, :mode

        # The size decision (UI::Density) and pane chrome (UI::Chrome::Plan)
        # of the current layout.
        attr_reader :density, :chrome

        # +layout+ a MB::Term::Viewports::Layout with a repl pane; +input+/+output+
        # the terminal (dup'd, so they keep reaching it after :adopt
        # reopens the process's streams); +repl+ :adopt (the console's
        # Pry) or :thread (a Pry of its own, for specs and tools);
        # +context+ the binding the palette evaluates in; +size+ [rows,
        # cols] for a terminal that won't say; +probe+ false skips the
        # terminal feature probe; +keyboard+ the UI::Keyboard for KEYS mode
        # (UI.keyboard), +keys_kitty+ true/false forces the kitty protocol
        # in KEYS mode on or off (nil: if the probe found it); other
        # options as for Band.
        def initialize(layout:, input: STDIN, output: STDOUT, session: nil, repl: :adopt, color: :ansi256, look: :auto,
                       glyphs: UI.glyphs, size: nil, clock: nil, cells: Kernels.cell_grid, fps: 60, panes: UI.panes, source: nil,
                       mouse: false, nav_esc: nil, kitty: false, context: nil, probe: true, scrollback: MB::Term::VT::SCROLLBACK, pry: {},
                       keyboard: nil, keys_kitty: nil, on_key: nil, hints: nil, play_keys: nil, on_action: nil, nav_once: true)
          # (Every instance variable set up front, in one order: one object shape)
          @term = @ambiguous = @host = @stopping = @full = @painter = @reader = @hidden = @relayout = @repl_full = @match = @search = @flash = @reloaded_at = @size_checked_at = @resized = @placed = @placed_layout = @grid = @shown = @canvases = @drawn_at = @first_refresh = @last_cursor = @line_cursor = @old_winch = @signals = @attached = @poll = @polled_at = @poll_warned = @last = @painter_warned = @heard = nil
          raise ArgumentError, "Layout #{layout.name.inspect} has no repl pane (`repl` in the layout block)" unless layout.repl? || repl == :none
          raise ArgumentError, "Unknown color mode #{color.inspect}" unless MB::Term::Cells::MODES.key?(color)

          @layout_name = layout.name
          # (every instance variable from the start, nil until used: one
          # object shape; the warning guard fails specs on shape variations)
          @term = @ambiguous = @host = @stopping = @full = @painter = @reader = @hidden = @relayout = @repl_full = nil
          @match = @search = @flash = @painter_warned = @reloaded_at = @size_checked_at = @resized = nil
          @placed = @placed_layout = @grid = @shown = @canvases = @drawn_at = @first_refresh = @last_cursor = nil
          @line_cursor = @old_winch = @signals = @wake_r = @wake_w = nil
          @attached = @poll = @polled_at = @poll_warned = @last = nil
          @asking = nil # ([pane name, PaneKeys::Ask] while a pane's value prompt is open)
          @temporary_jumps = {} # (pane name => the Proc that takes it away: panes put in by their jump letter)
          @input = input
          @output = output
          @session = session
          @repl_mode = repl
          @mode = color
          @look = look
          @glyphs = glyphs
          @fixed_size = size
          @clock = clock || -> { MB::U.clock_now }
          @cells_class = cells
          init_frame_rate(fps)
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
          # Input handling and mode changes from Ruby (ui.keys) take turns:
          # the Router's state changes one event at a time, and
          # #mode_problems sees whole transitions
          @input_lock = Monitor.new
          @active = false
          @frames = []
          @slowest = []
          @failures = {}
          @states = Hash.new { |h, k| h[k] = {} }
          @scroll = 0
          @palette_history = []
          @search_history = []
          @midi_seen = nil
          @overlay = nil
          @messages_restore = nil
          @messages_from = nil # (the pane NAV m left, when it focused the layout's messages pane)
          @message_close = nil
          @show_fps = false
          @rate_notes_at = nil
          @pane_cpu = Hash.new { |h, k| h[k] = [] }
          @chrome = nil
          @density = nil
          @rows, @cols = @fixed_size || [24, 80]
          @tiler = MB::Term::Viewports::Tiler.new(layout, @cols, @rows - 1)
          # Panes' declared minimum heights (UI::Pane#min_height), and widths:
          # the console keeps REPL_MIN_COLS (ux-fix-1: `ui :studio` at 80x24
          # left it 12 columns between fixed-width panes, which give way
          # down to PANE_MIN_COLS)
          @tiler.mins = ->(name, axis) {
            if axis == :rows
              @panes[name]&.min_height || (name == :repl ? REPL_MIN_ROWS : nil)
            else
              name == :repl ? Tiles.repl_min_cols(@cols) : PANE_MIN_COLS
            end
          }
          @router = MB::Term::Input::Router.new(self, nav_esc: nav_esc, console: repl != :none, nav_once: nav_once,
                                      repl_keys: play_keys || (repl == :none ? nil : Keys.repl_keymap))
          @router.add_keymap(NAV_EXTRA)
          @router.add_keymap(Keys.user[:nav], first: true)
          # Jump letters panes declare (`jump 'a'`), for the panes on screen
          @jump_map = MB::Term::Input::Keymap.new(:jumps) { group 'Jump' }
          @router.add_keymap(@jump_map)
          @on_action = on_action
          @focus_last = nil
          @once_focus = nil
          @mode_pane = nil
          @jumps = {}
          @enter_mark = nil
          @winch = nil
          @stray_warned = false
          @messages_seen = UI.messages.seq
          @decoder = MB::Term::Input::Decoder.new
          @keyboard = keyboard || UI.keyboard
          @keys_kitty = keys_kitty
          @states[:keyboard][:keyboard] = @keyboard
          @kitty_pushed = false
          @start_keys = layout.focus == :keyboard
          @on_key = on_key
          @hints = hints || (play_keys && Keys.hints(play_keys))
          @status_note = nil
          @note_capture = nil # (UI::NoteLog.capture when NAV # opened its prompt)
        end

        # The virtual keyboard (UI::Keyboard) KEYS mode plays.
        attr_reader :keyboard

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
          return show_again if @hidden

          @term = MB::Term::Terminal.new(input: @input.dup, output: @output.dup)
          @term.enter(mouse: @mouse, kitty: @kitty)
          features = @probe ? @term.probe : {}
          @ambiguous = features[:ambiguous] || (::Reline.core.instance_variable_get(:@ambiguous_width) rescue nil) || 1
          @glyphs = :ascii if @ambiguous == 2 && @glyphs == :unicode && ENV['MB_SOUND_UI_GLYPHS'].to_s.empty?
          @rows, @cols = terminal_size
          @tiler.resize_screen(@cols, @rows - 1)
          relayout
          unless @repl_mode == :none
            r = repl_rect || MB::Term::Viewports::Rect.new(0, 0, [@cols, 20].min, [@rows - 1, 5].max)
            @host = MB::Term::Input::ReplHost.new(rows: r.h, cols: r.w, mode: @repl_mode, scrollback: @scrollback, ambiguous_width: @ambiguous,
                                        target: @context || TOPLEVEL_BINDING, pry: @pry_opts)
            @host.start
            # A Pry of our own (:thread) reads through the global Reline,
            # whose Ctrl-]/F2 bindings (ConsoleKeys) act on the screen that
            # owns the reading thread: this one, not a new one on the real
            # terminal (Ctrl-] relayed while hidden reaches Reline)
            @host.thread[:mb_sound_ui_tiles] = self if @host.thread
          end
          @active = true
          @stopping = false
          install_signals
          @full = true
          @term.typed_during_probe.each { |e| handle(e) }
          hook_keyboard
          keys if @start_keys && @tiler.layout.panes.include?(:keyboard)
          # :wall stays opt-in (maintainer, 2026-10-17); big terminals get a tip
          if @host && @layout_name != :wall && @rows >= 60 && @cols >= 200
            flash('a big terminal: ui :wall shows the performance panes at once (ui :session: the set)', :dim)
          end
          if thread
            @painter = Thread.new { paint_loop }
            @wake_r, @wake_w = IO.pipe
            @reader = Thread.new { input_loop }
          end
          self
        end

        # Gives the terminal back (streams, modes, screen) and stops the
        # threads.  Safe to call twice and from at_exit.  Returns self.
        def stop
          return self unless @active || @hidden

          exit_keys
          @stopping = true
          @active = false
          @hidden = false
          [@reader, @painter].each { |t| t&.wakeup rescue nil }
          # (Thread#wakeup doesn't end the reader's wait for input: the
          # wake pipe does, so stop doesn't wait out its 0.5 s timeout)
          @wake_w&.write_nonblock('.', exception: false) rescue nil
          (@reader.join(0.5) || @reader.kill) if @reader && !Thread.current.equal?(@reader)
          @painter&.join(1)
          @painter = @reader = nil
          [@wake_r, @wake_w].each { |io| io&.close rescue nil }
          @wake_r = @wake_w = nil
          restore_signals
          detach
          @host&.relay = nil
          @host&.stop
          @term&.leave
          [@term&.input, @term&.output].each { |io| io&.close rescue nil }
          self
        end

        # True when the screen's REPL is the console's (adopted): stderr
        # goes to its pane, so UI::Messages keeps warnings for the
        # messages pane instead.
        def owns_terminal? = @active && (@repl_mode == :adopt || @repl_mode == :none)

        # True while hidden with Ctrl-Z (#hide): `ui` (or Ctrl-Z again)
        # shows it again with the same panes, scrollback, and REPL.
        def hidden? = @hidden == true

        # Leaves the tiled screen for the plain console without stopping
        # anything (Ctrl-Z): the session keeps playing, and the REPL's pty
        # is relayed to the terminal's normal screen (Pry and Reline keep
        # running there, the line being edited included), while the layout,
        # its edits, and the scrollback wait.  `ui`, `ui :<this layout>`, or
        # Ctrl-Z again bring the tiles back.  Returns self.
        def hide
          return self unless @active && @host # (a screen without a console has nothing to hide to)

          exit_keys
          @router.mode = :nav if @router.mode == :pane # (a pane's mode ends with the tiles; every pane has one since ui-api-1)
          @lock.synchronize do
            @active = false
            @hidden = true
          end
          @painter&.wakeup rescue nil
          @painter&.join(1) unless Thread.current.equal?(@painter)
          @painter = nil
          # (Signal traps stay: Reline's WINCH handler, installed for the
          # line it reads now, wraps ours, and must see the resize below)
          detach
          paste = @host.vt.bracketed_paste?
          @term.write("\e[?2026l\e[?1006l\e[?1002l\e[?1000l\e[0m\e[?25h\e[?1049l#{paste ? '' : "\e[?2004l"}" \
                      "\r\n\e[2m(ui: tiles hidden; the session plays on.  fg, Ctrl-Z, or `ui` brings them back; jobs lists what runs.)\e[0m\r\n")
          @host.relay = @term.output
          # Reline redraws its prompt and line on the terminal, at its size
          rows, cols = @term.size
          @host.resize(rows, cols, force: true)
          self
        end

        # Ctrl-] or F2 read by the Reline of this screen's own Pry thread
        # (ConsoleKeys.switch; :thread mode): back from hidden, then NAV
        # (or KEYS).  Returns self.
        def console_switch(what)
          show_again if hidden?
          what == :keys ? keys : (@router.mode = :nav)
          self
        end

        # Back from #hide (Ctrl-Z or `ui`).
        private def show_again
          @host.relay = nil
          @term.write("\e[?1049h\e[0m\e[H\e[2J#{@mouse ? "\e[?1000h\e[?1002h\e[?1006h" : ''}")
          @lock.synchronize do
            @hidden = false
            @active = true
            @stopping = false
            @rows, @cols = terminal_size
            @tiler.resize_screen(@cols, @rows - 1)
            @relayout = true
            @full = true
            @repl_full = true
            @host.vt.invalidate
          end
          install_signals unless @signals
          # The pane's size, and a redraw of Reline's line in it
          relayout_now
          r = repl_rect
          @host.resize(r.h, r.w, force: true) if r
          @painter = Thread.new { paint_loop } if @reader
          @painter&.wakeup rescue nil
          self
        end

        def relayout_now
          @lock.synchronize { relayout }
        end

        # The panes on screen, for #list (UI::Listable).
        def listed_panes
          order = @tiler.numbered
          @tiler.placed.filter_map do |p|
            next unless p.name
            pane = @panes[p.name]
            kind = p.name == :repl ? :repl : pane ? pane.class.name.split('::').last.downcase.to_sym : :empty
            n = order.index(p.name)
            rate = pane ? @rates.rate(PaneRates.priority_of(p.name, pane), pane.rate, p.opts[:rate]) : nil # (now: UI::PaneRates)
            PaneOnScreen.new(number: n && n + 1, name: p.name, kind: kind, title: pane&.title, rect: p.rect, focused: p.name == @tiler.focus,
                             zoomed: @tiler.layout.zoom == p.name, rate: rate,
                             look: pane&.plot? ? (@states[p.name][:look] || p.opts[:look] || @look) : nil, title_at: @chrome&.frames&.dig(p.name)&.at)
          end
        end

        def listing_mode = @hidden ? :hidden : :tiles
        def listing_layout = @layout_name

        # Draws the next frame (the painter calls this at its rate).
        # Returns the bytes written (nil if nothing changed).
        def refresh(now = @clock.call)
          @lock.synchronize { refresh_unlocked(now) unless @hidden }
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
            fps: fps,
            target_fps: @target_fps,
            pacing: @pacer.breakdown,
            pane_cpu_ms: @pane_cpu.to_h { |name, q| [name, UI.percentiles(q.map { |c| c * 1000 })] },
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
        # The REPL stays (without it the console has nowhere to draw; zoom
        # another pane over it instead).
        def close(name = nil)
          tile do |t|
            name ||= t.focus
            raise MB::Term::Viewports::Error, 'The REPL pane stays (z zooms another pane over it)' if name == :repl
            t.close(name)
          end
        end

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

        # Shows pane +name+ in the focused slot (or +at+).  The REPL pane
        # is never replaced: on it, +name+ goes beside it instead.
        def show(name, at: nil)
          tile do |t|
            at ||= t.focus
            if at == :repl && name != :repl && @host && !t.layout.panes.include?(name)
              t.split(:repl, :cols, name)
            else
              t.show(name, at: at)
            end
          end
        end

        # The look of plot pane +pane+ (default: the focused pane; a scope or
        # spectrum): +name+ a Plot look (:scope Braille, :quad, :blocks,
        # :mosaic, :spark, :ascii, or :auto), or nil for the next one in
        # Panes::Scope::LOOK_CYCLE.  Kept in the layout's pane options, so
        # `ui.save` saves it.  Returns the look.
        #
        #     ui.look            # the focused scope's next look
        #     ui.look :quad, pane: :spectrum
        def look(name = nil, pane: nil)
          pane ||= @tiler.focus
          raise ArgumentError, "#{pane.inspect} isn't a plot pane (scope, spectrum): its look is fixed" unless @panes[pane]&.plot?
          if name.nil?
            cycle = Panes::Scope::LOOK_CYCLE
            now = @states[pane][:look] || @tiler.layout.options_of(pane)[:look]
            name = cycle[((cycle.index(now) || -1) + 1) % cycle.length]
          end
          unless name == :auto || Plot::Text::LOOKS.key?(name)
            raise ArgumentError, "Unknown look #{name.inspect} (:auto, #{Plot::Text::LOOKS.keys.map(&:inspect).join(', ')})"
          end
          tile { |t| t.set_option(pane, :look, name) }
          flash("#{pane}: look #{name.inspect}", :ok)
          name
        end

        # Shows message +n+ (1: the newest; see the messages pane's
        # numbers) in full in a temporary pane below the messages (or
        # wherever a temporary pane goes), wrapped, with its count and age;
        # `ui.message false` closes it.  Returns self.
        def message(n = 1)
          if n == false || n.nil?
            @message_close&.call
            @message_close = nil
            return self
          end
          raise ArgumentError, "Messages are numbered from 1, the newest (got #{n.inspect})" unless n.is_a?(Integer) && n > 0
          @panes[:message].index = n if @panes[:message].respond_to?(:index=)
          @message_close ||= plot_pane(:message, height: 10)
          @full = true
          self
        end

        # Shows +text+ in the page pane: split off the console's slot below
        # it (the console keeps REPL_MIN_ROWS), focused and in its view
        # mode (UI::Panes::Page: j k, PgUp PgDn, g G, / search, y copy;
        # omnibus15, the maintainer: "help in the UI should change focus to
        # the pager where help is displayed").  Esc and q go back to what
        # opened the page (+opener+: the focused pane, the REPL while
        # typing at it; the REPL if that pane has closed), q closing it;
        # Ctrl-] is NAV as anywhere.  +help+ pages (Help.show) are titled
        # "HELP · <title>" (plain "HELP" without one); other text keeps
        # +title+ (`ui.page text, title:`).  `ui.page false` closes it.
        # Returns self.
        def page(text = nil, title: nil, help: false, opener: nil)
          if text.nil? || text == false
            @page_close&.call
            @page_close = nil
            @page_opener = nil
            @full = true
            return self
          end
          if @panes[:page].respond_to?(:show)
            label = help ? ['HELP', title].compact.reject { |t| t.to_s.empty? }.join(' · ') : title
            @panes[:page].show(text, title: label)
          end
          unless @tiler.focus == :page
            @page_opener = opener || (@router.mode == :repl || @tiler.focus.nil? ? :repl : @tiler.focus)
          end
          unless @page_close
            repl = @tiler.rects[:repl] || @tiler.rects.values.max_by(&:area)
            rows = [(repl ? repl.h : @rows) - REPL_MIN_ROWS - 1, 3].max
            temp = nil
            tile { |t| temp = t.open_temporary(:page, rows, keep: t.layout.panes - [:repl], fallback: :repl) }
            @page_close = temp && -> { tile { |t| t.close_temporary(temp) } }
          end
          enter(:page) if @tiler.layout.panes.include?(:page)
          @full = true
          self
        end

        # What opened the page pane (see #page), or nil.
        attr_reader :page_opener

        # Esc in a pane's own mode (MB::Term::Input::Router#pane_key): the page pane
        # goes back to what opened it (true: handled); other panes to NAV.
        def pane_escape
          return false unless @tiler.focus == :page && @page_opener
          back_from_page
          true
        end

        # Focus back to the page's opener: the REPL, or a pane still on
        # screen (into its own mode if it has one), else the REPL.
        private def back_from_page
          to = @page_opener
          if to == :repl || !@tiler.layout.panes.include?(to)
            return @host ? act(MB::Term::Input::Action.of(:mode, :repl)) : (@router.mode = :nav)
          end
          enter(to)
        end

        # Undoes the last layout change (split, close, resize, ...; 100 steps).
        def undo = tile(&:undo)

        # Redoes a layout change undone with #undo.
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
          l = MB::Term::Viewports::Layout.new(name: name, root: l.root, focus: l.focus, zoom: nil, gap: l.gap) unless name == l.name && l.zoom.nil?
          path = UI.save_layout_text(name, l.to_ruby)
          UI.tile_layouts[name] = l
          flash("saved #{path}", :ok)
          path
        end

        # Changes the theme (:default, :paper, :phosphor, :mono, or one in
        # UI.layouts_dir/themes; see MB::Term::Themes).  Without a name, the
        # theme in use.
        def theme(name = nil)
          return MB::Term::Themes.current if name.nil?
          MB::Term::Themes.use(name)
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
          return flash('no console to search here', :warn) && nil unless @host
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

        # Copies the text pane +name+ shows (its body, trailing spaces cut)
        # to the system clipboard (OSC 52); a pane's view mode `y`.  Returns
        # the text.
        def copy_pane(name = @tiler.focus)
          r = @tiler.rects[name] or return flash("#{name}: not on screen", :warn) && nil
          if @panes[name].respond_to?(:full_text)
            # (a page: all of it, not only the rows shown)
            text = @panes[name].full_text
          else
            lines = @lock.synchronize { @grid.to_text(:none) }.split("\n", -1)
            text = lines[r.y, r.h].to_a.map { |l| l[r.x, r.w].to_s.rstrip }.join("\n").sub(/\n+\z/, '')
          end
          @term&.copy(text)
          flash("copied #{text.length} characters of #{name} (OSC 52)", :ok)
          text
        end

        # Copies the search match's line (or the REPL pane's visible text)
        # to the system clipboard with OSC 52.  Returns the text.
        def copy
          return flash('no console to copy from here', :warn) && nil unless @host
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

        # KEYS mode: the computer keyboard plays the virtual keyboard (the
        # `keyboard` pane, put below the REPL if the layout has none) until
        # Ctrl-] (see UI::Keyboard for the keys).  +on+ false leaves it.
        # Options set the keyboard: +off+ the note-off mode (:auto,
        # :release, :hold, :tap, :legato), +step+ true for step entry,
        # +patch+ the default patch's voice block (nil: none; it plays
        # while nothing is armed).
        #
        #     ui.keys                 # play; arm :lead to hear the lead
        #     ui.keys off: :tap       # fixed-length notes
        #     ui.keys step: true      # step entry
        def keys(on = true, off: nil, step: nil, patch: :keep)
          @input_lock.synchronize { keys_unlocked(on, off: off, step: step, patch: patch) }
        end

        private def keys_unlocked(on, off:, step:, patch:)
          return exit_keys.then { self } unless on

          start if @hidden # (from the hidden console: the tiles come back first)
          @keyboard.off_mode = off if off
          @keyboard.entry = step ? :step : :play unless step.nil?
          @keyboard.out.patch = patch if patch != :keep && @keyboard.out.respond_to?(:patch=)
          @router.mode = :grab # (#mode_changed puts the pane in and focuses it)
          self
        end

        # Puts pane +kind+ (:scope, :spectrum, :messages) on the screen for
        # a while (a plot from PlaybackMethods#visualize, the messages
        # pane): nothing if the layout shows it, else a slot of +height+
        # rows taken from the largest flexible pane that isn't the REPL or
        # the keyboard (MB::Term::Viewports::Tiler#open_temporary; the focus
        # stays).  Returns a Proc that closes the slot again, putting the
        # split tree back exactly as it was if nothing else changed it
        # (ux-1 r3 item 30), or nil if nothing changed.
        def plot_pane(kind, height: 10, prefer: nil)
          temp = nil
          tile { |t| temp = t.open_temporary(kind, height, keep: TEMPORARY_KEEP, fallback: :repl, prefer: prefer) }
          return nil unless temp
          -> { tile { |t| t.close_temporary(temp) } }
        end

        # The REPL pane's smallest height.
        REPL_MIN_ROWS = 4

        # The console's narrowest width, taken from fixed-width panes beside
        # it when the terminal is narrow (they keep PANE_MIN_COLS).
        REPL_MIN_COLS = 40
        PANE_MIN_COLS = 12

        # The console's narrowest width wanted on a wider terminal: half the
        # columns, up to this (panel round 2, N10: `ui :session` at 120
        # columns left the REPL 40 columns, wrapping results mid-word).
        REPL_WANT_COLS = 60

        # The REPL's minimum width on a +cols+-column terminal: half of it,
        # from REPL_MIN_COLS up to REPL_WANT_COLS.
        def self.repl_min_cols(cols) = (cols.to_i / 2).clamp(REPL_MIN_COLS, REPL_WANT_COLS)

        # Panes temporary panes never take their rows from.
        TEMPORARY_KEEP = %i[repl keyboard].freeze

        # What is wrong with the mode state, as a list (empty when every
        # invariant holds): KEYS mode's keyboard, kitty flags, and notes
        # follow the router's mode exactly, and nothing plays the keyboard
        # while hidden.  Every way into and out of KEYS goes through
        # #mode_changed, which keeps these; a spec drives random key
        # sequences against them.
        def mode_problems
          @input_lock.synchronize { mode_problems_unlocked }
        end

        private def mode_problems_unlocked
          grab = @router.mode == :grab
          out = []
          out << "keyboard #{@keyboard.active? ? 'active' : 'inactive'} in #{@router.mode} mode" if grab != @keyboard.active?
          out << "kitty flags pushed in #{@router.mode} mode" if @kitty_pushed && !grab
          out << 'KEYS mode while hidden' if grab && @hidden
          out << "notes #{@keyboard.held.inspect} held in #{@router.mode} mode" if !grab && !@keyboard.held.empty?
          out << "keyboard pane not focused in KEYS mode" if grab && @tiler.focus != :keyboard
          if @router.mode == :pane
            out << "pane mode on #{@tiler.focus.inspect}, which has no keys of its own" unless into(@tiler.focus) == :pane
            out << "pane mode marks #{@mode_pane.inspect} but #{@tiler.focus.inspect} is focused" if @mode_pane != @tiler.focus
            out << 'pane mode while hidden' if @hidden
          elsif @mode_pane && !(@router.state == :overlay)
            out << "#{@mode_pane.inspect} marked in its mode in #{@router.mode} mode"
          end
          out << "overlay #{@overlay ? 'shown' : 'hidden'} in #{@router.state} state" if @overlay.nil? == (@router.state == :overlay)
          out << "a prompt line in #{@router.state} state" if @router.line && !(@router.mode == :line || (%i[nav overlay once].include?(@router.mode) && @router.nav_return == :line))
          out << "one-shot NAV from #{@router.once_return.inspect}" if @router.mode == :once && !MB::Term::Input::Router::ONCE_FROM.include?(@router.once_return)
          out << "no prompt line in line mode" if @router.mode == :line && @router.line.nil?
          if @host
            out << 'no REPL pane' unless @tiler.layout.panes.include?(:repl)
            out << "REPL mode with #{@tiler.layout.zoom.inspect} zoomed over the REPL" if @router.mode == :repl && @tiler.layout.zoom && @tiler.layout.zoom != :repl
            out << 'REPL mode without the REPL pane on screen' if @router.mode == :repl && !@hidden && !@tiler.rects.key?(:repl)
            out << "REPL mode with #{@tiler.focus.inspect} focused" if @router.mode == :repl && @tiler.focus != :repl
          else
            out << "#{@router.mode} mode without a console" if @router.mode == :repl
          end
          out
        end

        # Shows (or hides) the key overlay (the Router's :overlay state):
        # NAV's keys and the focused pane's.  Esc, ?, or Ctrl-] close it;
        # any other key closes it and does what it does in NAV.
        def key_help(on = @router.state != :overlay)
          @input_lock.synchronize { key_help_unlocked(on) }
        end

        private def key_help_unlocked(on)
          if on
            @router.mode = :nav unless %i[nav overlay once].include?(@router.mode)
            @router.mode = :overlay
          elsif @router.state == :overlay
            @router.mode = :nav
          end
          self
        end

        # The messages pane (warnings and live errors while the UI is up;
        # see UI::Messages), NAV m.  When the layout has one, a focus
        # toggle: focus goes to it, and again back to where it was (never
        # moving or recreating it; maintainer, 2026-10-18: "If it's already
        # there it should be a focus toggle", "I.e. part of the layout").
        # Otherwise a temporary pane below the REPL (beside the commands
        # that caused the warnings; the largest other pane when the REPL
        # lacks the rows), and again: away, the layout back exactly.  +on+
        # true opens or keeps it (new warnings), false takes a temporary
        # one away.  Marks the messages read.
        def messages(on = :toggle)
          UI.messages.mark_read
          in_layout = @messages_restore.nil? && @tiler.layout.panes.include?(:messages)
          if in_layout
            return self if on == true || on == false
            if @tiler.focus == :messages
              back = @messages_from && @tiler.layout.panes.include?(@messages_from) ? @messages_from : (@tiler.layout.panes.include?(:repl) ? :repl : nil)
              tile { |t| t.focus!(back) } if back
              @messages_from = nil
            else
              @messages_from = @tiler.focus
              tile { |t| t.focus!(:messages) }
            end
          elsif on == true || (on == :toggle && @messages_restore.nil?)
            @messages_restore ||= plot_pane(:messages, height: 8, prefer: :repl)
          elsif @messages_restore
            @messages_restore.call
            @messages_restore = nil
          end
          self
        end

        # Shows the measured frame rate on the status line ("42 fps · 0.3
        # ms · 18 kB/s": frames written per second, the painter's CPU per
        # frame, bytes per second; see FrameRate), or hides it.
        def show_fps(on = true)
          @show_fps = on
          @relayout = true # (the chrome shows each pane's rate beside its number while on)
          self
        end

        # Shows +text+ on the status line for a few seconds (+role+ its
        # color: :ok, :warn, :bad, ...).
        def say(text, role = :text)
          flash(text, role)
          self
        end

        # A note that stays on the status line instead of the hints (nil:
        # none), e.g. "song ended: q quits" for a script's screen.  (Was
        # #note until ui-scaffold-1, when `ui.note` became the UI notes.)
        attr_accessor :status_note

        # True while the key overlay shows.
        def key_help? = @router.state == :overlay

        # Goes into pane +name+ (default: the focused one), as NAV Enter
        # does: the REPL pane into REPL mode, the keyboard into KEYS, a pane
        # with keys of its own (a clip matrix's cursor; UI::PaneKeys
        # `mode_keys`) into its mode until Esc; any other pane just stays
        # focused (NAV).  Returns the mode entered.
        #
        #     ui.enter :clips
        def enter(name = nil)
          @input_lock.synchronize { enter_unlocked(name) }
          @router.mode
        end

        private def enter_unlocked(name)
          # (not pinned to the REPL: going into a pane leaves REPL mode, e.g.
          # a help page opened from the console)
          tile(pin: false) { |t| t.focus!(name) } if name && name != @tiler.focus
          name = @tiler.focus
          case into(name)
          when :repl then act(MB::Term::Input::Action.of(:mode, :repl))
          when :grab then keys_unlocked(true, off: nil, step: nil, patch: :keep)
          when :pane then @router.mode = :pane
          else
            @router.mode = :nav unless %i[nav overlay].include?(@router.mode)
            flash("#{name}: no keys of its own (it stays focused; NAV keys work)", :dim)
          end
        end

        # What going into pane +name+ means: :repl, :grab (the keyboard),
        # :pane (keys of its own), or nil (nothing: it stays focused).
        def into(name)
          return :repl if name == :repl && @host
          return :grab if name == :keyboard
          @panes[name].respond_to?(:mode_keymap) && @panes[name].mode_keymap ? :pane : nil
        end

        # Jumps to pane +name+ (a pane name or kind; NAV's jump letters: i
        # the REPL, k the keyboard, t tracks, e meters, and any a pane kind
        # declares): focuses it (a tab of it comes forward) and goes in as
        # #enter does.  A pane not on screen is named in a flash with how to
        # show it (the keyboard is put in, as KEYS does).
        #
        #     ui.jump :tracks
        def jump(name)
          @input_lock.synchronize { jump_unlocked(name) }
          @router.mode
        end

        private def jump_unlocked(name)
          target = jump_target(name)
          if target.nil?
            return keys_unlocked(true, off: nil, step: nil, patch: :keep) if name == :keyboard
            return act(MB::Term::Input::Action.of(:mode, :repl)) if name == :repl && @host
            # (a pane kind that may come for a while: the library picker on
            # ui :sound's smaller layouts; its q, or the jump again, takes
            # it away)
            if (rows = UI.panes[name]&.temporary_rows(@tiler.layout.panes))
              @temporary_jumps[name] = plot_pane(name, height: [rows, @rows / 2].min, prefer: TEMPORARY_PREFER[name])
              return enter_unlocked(name) if @tiler.layout.panes.include?(name)
            end
            return flash("no #{name} pane here (: show :#{name})", :dim)
          end
          return close_temporary_jump(name) if @temporary_jumps[name] && @tiler.focus == target && @router.mode == :pane
          enter_unlocked(target)
        end

        # NAV #: a prompt line for a UI note (UI::NoteLog), the screen as it
        # is now kept for it (what was looked at, not the prompt).
        def note_prompt
          @note_capture = NoteLog.capture(self)
          @router.open_line(:ui_note, 'ui note: ')
        end

        # The UI note's text (nil: cancelled), saved with the capture.
        def note_done(text)
          capture = @note_capture
          @note_capture = nil
          return flash('no note saved', :dim) if text.nil? || text.strip.empty?
          n = NoteLog.save(text, capture: capture, session: @session || Session.existing)
          flash(Tiles.one_line("note saved to #{n.path} (ui.notes lists today's)"), :ok)
        rescue StandardError => e
          flash(Tiles.one_line("ui note: #{e.class}: #{e.message}"), :bad)
        end

        private :note_prompt, :note_done

        # Panes a temporary jump takes rows from first (else the largest
        # flexible pane).
        TEMPORARY_PREFER = { picker: :inspector }.freeze

        # Takes away pane +name+ opened by its jump letter (#jump_unlocked):
        # the layout comes back as it was, the focus where it was.
        def close_temporary_jump(name)
          restore = @temporary_jumps.delete(name) or return
          act(MB::Term::Input::Action.of(:mode, :nav)) if @tiler.focus == name
          restore.call
          @full = true
          @router.mode
        end
        private :close_temporary_jump

        # The pane on screen for jump name +name+ (its own name first,
        # then the first pane of that kind), or nil.
        def jump_target(name)
          names = @tiler.layout.panes
          return name if names.include?(name)
          names.find { |n| PaneKeys.kind_of(@panes[n]) == name }
        end

        ### Router host (called on the input thread)

        # Where the one-shot NAV (Ctrl-W, the Router's :once) goes after
        # its action: back to +origin+ if the focus stayed, else into the
        # pane it moved to as Enter would (the REPL, KEYS, the pane's own
        # mode, or NAV for a pane without keys of its own).
        def once_target(origin)
          return origin if @tiler.focus == @once_focus
          { repl: :repl, grab: :grab, pane: :pane }.fetch(into(@tiler.focus), :nav)
        end

        # A key in KEYS mode (:grab).
        def grab_key(k)
          handled = @keyboard.key(k, mono_now)
          flash("#{k}: not a key here (Ctrl-] back)", :dim) unless handled || k.release?
          @painter&.wakeup rescue nil
        end

        # A key on a screen without a console (a script's --ui).
        def play_key(k)
          @on_key&.call(k)
        end

        # A key in a pane's own mode (Router :pane): the focused pane's mode
        # keys, then its NAV keys.  Returns true if the pane took it.
        def pane_mode_key(k)
          pane = @panes[@tiler.focus]
          a = pane.respond_to?(:mode_keymap) && pane.mode_keymap&.[](k)
          a ||= pane.respond_to?(:keymap) && pane.keymap&.[](k)
          return false unless a
          pane_action(@tiler.focus, a.name, *a.args)
          true
        end

        # The focused pane's keymap (pane kinds declare one; see
        # UI::PaneKeys), consulted first in NAV.
        def pane_keymap
          pane = @panes[@tiler.focus]
          pane.respond_to?(:keymap) ? pane.keymap : nil
        end

        def repl_key(k)
          return @on_key&.call(k) unless @host
          if @scroll > 0
            @scroll = 0
            @match = nil
            @repl_full = true
          end
          @host.key(k)
        end

        def repl_paste(text)
          @host&.paste(text)
        end

        # The Router's mode changed (every way into and out of a mode comes
        # here, so the invariants in #mode_problems hold).
        def mode_changed(m)
          @full = true
          @once_focus = @tiler.focus if m == :once
          @overlay = m == :overlay ? overlay_groups : nil
          pane_mode(m == :pane ? @tiler.focus : nil)
          if m == :pane && into(@tiler.focus) != :pane
            # (Ctrl-] back from NAV after the focus moved, or the pane went)
            return @router.mode = :nav
          end
          return enter_keys if m == :grab

          leave_keys
          return unless m == :repl && @host

          # Typing goes to the REPL, so it must be on screen and focused
          # (keys go where the focus is): a lost REPL pane comes back, a
          # zoom on another pane ends (zoom the REPL itself to keep a big
          # one)
          ensure_repl
          tile { |t| t.focus!(:repl) } unless @tiler.focus == :repl
          z = @tiler.layout.zoom
          tile { |t| t.zoom(z) } if z && z != :repl
        end

        # Marks pane +name+ as in its own mode (its state's :mode, for
        # drawing a cursor), the pane marked before (if any) as not.
        def pane_mode(name)
          return if name == @mode_pane
          @states[@mode_pane].delete(:mode) if @mode_pane
          @mode_pane = name
          @states[name][:mode] = true if name
        end

        def line_done(kind, text)
          @full = true
          return answer_pane(text) if kind == :pane_value
          return note_done(text) if kind == :ui_note
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
          when :mode
            # (NAV Esc, i, or Enter on the REPL: the REPL, from any pane, KEYS included; a
            # lost REPL pane comes back, in the focused slot if it is empty)
            to = a.args[0]
            ensure_repl(here: true) if to == :repl && @host
            @router.mode = to
          when :interrupt
            @scroll = 0
            @host ? @host.interrupt : @on_key&.call(:interrupt)
          when :hide then @host ? hide : flash('Ctrl-Z: nothing to hide to here (no console)', :dim)
          when :focus_last then focus_last
          when :refused then flash("#{a.args[0]}: #{a.args[1]}", :dim)
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
          when :panic # (a script screen's own panic, e.g. a synth screen's notes off, else the console's)
            @on_action ? @on_action.call(a) : run_safely { UI.run_line('panic', keys_session || Session.current) }
          when :pause # (a script screen's own pause, else the console's transport toggle: start or pause, a take line)
            if @on_action
              @on_action.call(a)
            else
              run_safely {
                s = keys_session || Session.current
                st = UI.run_line(TransportMethods.toggle_line(s), s)
                flash(st.to_s, :dim) if st.is_a?(TransportMethods::Status)
              }
            end
          when :keys then keys
          when :enter then enter
          when :jump then jump(a.args[0])
          when :key_help then key_help
          when :ui_note then note_prompt
          when :messages then messages
          when :show_fps then show_fps(!@show_fps)
          when :call then run_safely { a.args[0].call }
          when :line_changed then pane_line_changed
          when :complete then complete_palette
          when :unbound
            flash(a.args[1] ? "#{a.args[1]} #{a.args[0]}: not a NAV key (the keys are listed here; Esc: back)" : "#{a.args[0]}: not a NAV key (? lists them; Esc or i: the REPL)", :dim)
          when :event then event(a.args[0])
          when :nop then nil
          when :pane_key then pane_action(@tiler.focus, a.args[0].name, *a.args[0].args)
          else
            if @on_action && !respond_to?(a.name)
              @on_action.call(a)
            else
              respond_to?(a.name) ? run_safely { public_send(a.name, *a.args) } : flash("unknown action #{a.name.inspect}", :warn)
            end
          end
        rescue MB::Term::Viewports::Error, ArgumentError => e
          flash(e.message, :bad)
        end

        private

        def mono_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # Makes pane +name+ (just split off below another) +height+ rows by
        # moving its top edge, the rows going to or coming from the pane
        # above (weights round, so it may take a second step).
        def fit_height(t, name, height)
          2.times do
            h = t.rects[name]&.h.to_i
            break if h == height || h == 0
            t.resize(name, :up, height - h)
          end
        end

        # The keyboard's Enter (capture) and step entry's Enter (a clip).
        def hook_keyboard
          @keyboard.on_capture = -> { capture_keys }
          @keyboard.on_finish = ->(clip) { finish_steps(clip) }
          @keyboard.on_swap = ->(clip) { swap_steps(clip) }
        end

        # The Session the keyboard plays into.
        def keys_session
          @keyboard.out.respond_to?(:target_session) ? @keyboard.out.target_session : Session.existing
        end

        # Step entry's swap key: the clip into each armed track at its next
        # launch point (Arrangement#play: a swap if the track plays, else a
        # launch; journaled and undoable like `bg :lead, clip`).
        def swap_steps(clip)
          s = keys_session
          armed = s&.arrangement&.armed || {}
          return flash('swap: arm a track first (arm :lead); Enter puts the clip on the console line instead', :warn) if armed.empty?
          ruby = clip.to_ruby
          landed = armed.keys.map { |name| [name, run_for_track('swap', name) { UI.run_line("bg #{name.inspect}, #{ruby}", s) }] }
          flash_changes('swap', landed, "#{ruby} ")
        end

        # Enter in KEYS mode: `capture` into each armed track (one line
        # each, so a track whose patch fails leaves the others captured).
        def capture_keys
          s = keys_session
          armed = s&.arrangement&.armed || {}
          return flash('capture: arm a track first (arm :lead), then play and press Enter', :warn) if armed.empty?
          landed = armed.keys.map { |name| [name, run_for_track('capture', name) { UI.run_line("capture #{name.inspect}", s) }] }
          flash_changes('capture', landed, 'what you played ')
        end

        # Runs a UI action's change for track +name+.  An error (a patch
        # that doesn't build, ...) goes to the messages pane naming the
        # track and where in the patch it happened; returns :failed.
        def run_for_track(what, name)
          r = yield
          # (live, a failure is a warning, which the messages pane got, and
          # nothing to show for it)
          r.respond_to?(:lands) ? r : :failed
        rescue StandardError, ScriptError => e
          if e.is_a?(Arrangement::Recording::CaptureFailed)
            UI.messages.add(e.message, severity: :error) # (it names the track and line itself)
          else
            where = UI.error_origin(e)
            UI.messages.add("#{what} into #{name.inspect} failed: #{e.class}: #{e.message}#{where ? " (at #{where})" : ''}", severity: :error)
          end
          :failed
        end

        # Says what KEYS mode's Enter or step entry's w did, so an
        # accidental capture is obvious: "capture: what you played loops
        # into :lead at 5:1 (undo takes it back)", and which tracks failed
        # ("; :bass failed (m: messages)").  +landed+ is [track, journal
        # entry, nil, or :failed] pairs.
        def flash_changes(what, landed, thing)
          failed = landed.select { |_, e| e == :failed }.map(&:first)
          ok = landed.reject { |_, e| e.nil? || e == :failed }
          fail_text = failed.empty? ? '' : "#{failed.map(&:inspect).join(', ')} failed (m: messages)"
          if ok.empty?
            flash("#{what}: #{fail_text.empty? ? 'nothing changed' : fail_text}", :bad)
            return
          end
          where = ok.map { |name, e| "#{name.inspect}#{e.respond_to?(:lands) && e.lands ? " at #{e.lands}" : ''}" }.uniq.join(', ')
          flash("#{what}: #{thing}loops into #{where} (undo takes it back)#{fail_text.empty? ? '' : "; #{fail_text}"}", failed.empty? ? :ok : :warn)
        end

        # Enter in step entry: the clip goes to UI.keyboard.clips, and its
        # Ruby into the REPL's line (not run) to name or play.
        def finish_steps(clip)
          @router.mode = :repl
          @host&.paste(clip.to_ruby)
          flash("clip #{@keyboard.clips.length}: ui.keyboard.clip (and in the REPL line: name it, e.g. riff = ...)", :ok)
        end

        def enter_keys
          ensure_keyboard_pane
          @keyboard.active = true
          kitty = @keys_kitty.nil? ? @term&.features&.dig(:kitty) : @keys_kitty
          if kitty && @term && !@kitty_pushed
            @term.write("\e[>#{KEYS_KITTY_FLAGS}u\e[?1004h")
            @kitty_pushed = true
            @keyboard.releases = true
          elsif @term
            @term.write("\e[?1004h")
          end
          Thread.new do
            Thread.current.name = 'MB::Sound::UI keys'
            @keyboard.out.ensure_monitor if @keyboard.out.respond_to?(:ensure_monitor)
          rescue StandardError => e
            flash("keyboard: #{e.class}: #{e.message}", :bad)
          end
        end

        # Every way out of KEYS mode: all notes off, the terminal's keys as
        # before.
        def leave_keys
          return self unless @keyboard.active? || @kitty_pushed

          @keyboard.all_off(mono_now)
          @keyboard.active = false
          @term&.write(@kitty_pushed ? "\e[<u\e[?1004l" : "\e[?1004l") if @term&.entered?
          @kitty_pushed = false
          self
        end

        # Leaves KEYS mode from outside the router (hiding, stopping).
        def exit_keys
          @router.mode == :grab ? (@router.mode = :repl) : leave_keys
        end

        def tile(pin: true)
          @lock.synchronize do
            was = @tiler.focus
            yield @tiler
            # Keys go where the focus is: in REPL mode the REPL keeps it, in
            # KEYS the keyboard (a split or `show` from the console doesn't
            # take it; NAV moves it; #enter does, +pin+ false)
            pin = pin ? { repl: (:repl if @host), grab: :keyboard }[@router.mode] : nil
            @tiler.focus!(pin) if pin && @tiler.focus != pin && @tiler.layout.panes.include?(pin)
            @focus_last = was if @tiler.focus != was && @tiler.layout.panes.include?(was)
            @relayout = true
          end
          # (a pane's own mode ends when the focus leaves it, whatever moved it)
          @router.mode = :nav if @router.mode == :pane && (@tiler.focus != @mode_pane || into(@tiler.focus) != :pane)
          self
        rescue MB::Term::Viewports::Error => e
          flash(e.message, :bad)
          self
        end

        # Shows +text+ on the status line for FLASH seconds: one line, no
        # control characters (a newline in a cell would scroll the whole
        # screen: item 22), "..." where it was longer.  The flash remembers
        # the newest message at the time (UI.messages.seq), so a message
        # the painter notices later can't replace a flash that came after
        # it (#auto_messages).
        def flash(text, role = :text)
          @flash = [Tiles.one_line(text), role, @clock.call + FLASH, UI.messages.seq]
        end

        # Focuses the pane focused before the current one (NAV p, Ctrl-W
        # Ctrl-W).
        def focus_last
          name = @focus_last
          return flash('no previous pane yet', :dim) unless name && @tiler.layout.panes.include?(name)
          tile { |t| t.focus!(name) }
        end

        # Puts the REPL pane back if it is gone (only by a path that
        # should have kept it): in the focused slot if it is empty (+here+),
        # else below the focused pane.  Returns true if it came back.
        def ensure_repl(here: false)
          return false if !@host || @tiler.layout.panes.include?(:repl)
          tile do |t|
            f = t.focus
            if here && !@panes.key?(f) && f != :keyboard
              t.show(:repl, at: f)
            else
              t.split(f, :rows, :repl)
            end
          end
          @repl_full = true
          flash('the REPL came back (its scrollback kept)', :ok)
          true
        end

        # The keyboard pane in the layout (below the REPL, or the focused
        # pane, if missing), focused: KEYS mode plays there.
        def ensure_keyboard_pane
          tile do |t|
            unless t.layout.panes.include?(:keyboard)
              t.split(t.layout.panes.include?(:repl) ? :repl : t.focus, :rows, :keyboard)
              fit_height(t, :keyboard, 8)
            end
            t.focus!(:keyboard)
          end
        end

        # The key overlay's groups: NAV's, the focused pane's keys, and the
        # keyboard's (KEYS or step entry) when it is focused.
        def overlay_groups
          groups = Keys.groups(:nav).dup
          groups += @jump_map.help_groups unless @jump_map.entries.empty?
          pane = pane_keymap
          groups = pane.help_groups.map { |g, k| ["#{g} (#{@tiler.focus})", k] } + groups if pane
          mode = @panes[@tiler.focus].respond_to?(:mode_keymap) && @panes[@tiler.focus].mode_keymap
          groups = mode.help_groups.map { |g, k| ["#{g} (#{@tiler.focus}#{@router.mode == :pane || @router.nav_return == :pane ? '' : ': Enter, then'})", k] } + groups if mode
          groups += Keys.groups(:once) if @router.nav_once
          groups += Keys.groups(@keyboard.entry == :step ? :step : :grab) if @tiler.focus == :keyboard
          groups.freeze
        end

        # A pane keymap's action for the focused pane.
        def pane_action(name, action, *args)
          return copy_pane(name) if action == :copy_text
          pane = @panes[name]
          return flash("#{name}: no pane", :warn) unless pane.respond_to?(:key_action)
          r = pane.key_action(action, @states[name], *args)
          pane_result(name, r)
        end

        # What a pane key or tick returned (one or an Array, in order):
        # Runs run as console lines, a Preview moves a knob live
        # (Session#preview_turn, unjournaled: a held key's gesture), a
        # Commit runs the gesture's line from the Session
        # (Session#gesture_line); then the pane's #lines_ran.  A String
        # flashes.
        def pane_result(name, r)
          ran = false
          Array(r).each do |x|
            case x
            when PaneKeys::Run
              run_pane_line(x)
              ran = true
            when PaneKeys::Preview
              s = @session || Session.existing
              next flash('no session to turn knobs in', :warn) unless s
              begin
                v = s.preview_turn(x.knob, x.value)
                flash("#{x.knob} #{GraphNode::Knob.number(v)}  (held: one line when you let go)", :key)
              rescue ArgumentError => e
                flash("#{e.class}: #{e.message}", :bad)
              end
            when PaneKeys::Commit
              s = @session || Session.existing
              code = s&.gesture_line(x.knob)
              run_pane_line(PaneKeys::Run[code, x.note]) if code
              ran = true
            when PaneKeys::Ask
              # (a value to type: a prompt line; #line_done hands the text to the pane)
              @asking = [name, x]
              @router.open_line(:pane_value, x.prompt)
              @router.line.insert(x.text) unless x.text.empty?
            when PaneKeys::Paste
              # (a line to edit on the REPL's prompt, not run: the REPL, the text typed in)
              if @host
                act(MB::Term::Input::Action.of(:mode, :repl))
                @host.paste(x.code)
                flash(Tiles.one_line(x.note || 'on the console line: Enter runs it'), :key)
              else
                flash(Tiles.one_line("no console here: #{x.code}"), :warn)
              end
            when String
              flash(x, :key)
            when :close
              # (a pane asking to be closed: the page pane's q, back to what
              # opened it)
              if name == :page
                opener = @page_opener
                page(false)
                @page_opener = opener
                back_from_page
                @page_opener = nil
              elsif @temporary_jumps[name]
                close_temporary_jump(name)
              elsif @host
                act(MB::Term::Input::Action.of(:mode, :repl))
              end
            end
          end
          pane = @panes[name]
          pane.lines_ran(@states[name]) if ran && pane.respond_to?(:lines_ran)
          @full = true
        end

        # The typed answer (nil: cancelled) to the open PaneKeys::Ask: the
        # asking pane's key_<answer>, handled like a key's result (a
        # cancelled live Ask gets its key_<changed> with the starting text,
        # so a find puts the list back).
        def answer_pane(text)
          name, ask = @asking
          @asking = nil
          return unless name
          pane = @panes[name] or return
          if text.nil?
            pane.key_action(ask.changed, @states[name], ask.text) if ask.changed
            return flash('cancelled', :dim)
          end
          pane_result(name, pane.key_action(ask.answer, @states[name], text))
        end

        # An edit of an open live Ask's line (PaneKeys::Ask +changed+: the
        # library picker's find-as-you-type): the asking pane's
        # key_<changed> with the text so far; a String it returns flashes.
        def pane_line_changed
          name, ask = @asking
          return unless name && ask.changed && @router.line
          pane = @panes[name] or return
          r = pane.key_action(ask.changed, @states[name], @router.line.text)
          flash(Tiles.one_line(r), :dim) if r.is_a?(String)
          @full = true
        end

        # Seconds until a pane on screen has a line due (UI::PaneKeys
        # key_wait: a gesture ending), or nil.
        def pane_wait
          @tiler.layout.panes.filter_map { |n| (p = @panes[n]).respond_to?(:key_wait) ? p.key_wait(@states[n]) : nil }.min
        end

        # Runs the lines panes on screen have due (key_tick).
        def tick_panes
          @tiler.layout.panes.each do |n|
            p = @panes[n]
            next unless p.respond_to?(:key_tick) && p.respond_to?(:key_wait) && p.key_wait(@states[n])
            r = p.key_tick(@states[n])
            pane_result(n, r) if r
          end
        end

        # Runs a pane key's console line (PaneKeys::Run) through UI.run_line
        # in the screen's session: journaled, undoable, a take line; the
        # Ruby it ran and what it printed go into the REPL pane (the
        # messages without one), its note or result on the status line.
        def run_pane_line(run)
          out = StringIO.new
          r = err = nil
          begin
            with_output_to(out) { r = UI.run_line(run.code, @session || Session.existing) }
          rescue StandardError, ScriptError => e
            err = e
          end
          result = err ? "#{err.class}: #{err.message}" : "=> #{Tiles.one_line(r.inspect)[0, 120]}"
          print_to_repl("# #{run.note || 'ui'}\n#{run.code}\n#{out.string}#{result}\n")
          err ? flash(Tiles.one_line(result), :bad) : flash(Tiles.one_line("#{run.note || run.code}  (#{run.code})"), :ok)
          r
        end

        # After a command whose output is taller than the REPL pane, says
        # once how to scroll back to its start (item 16).
        def note_long_output
          return unless @enter_mark && @host
          h = repl_rect&.h or return
          n = repl_lines - @enter_mark
          return unless n > h
          @enter_mark = nil
          flash("#{n} lines of output: #{scroll_key_name} scrolls back to its start", :key)
        end

        # The REPL key that scrolls back (Alt-PgUp unless the inputrc took
        # it), for hints.
        def scroll_key_name
          b = @router.repl_keys.entries.find { |e| e.action == :scroll && e.args == [:page_up] }
          b ? MB::Term::Input::Keymap.chord_name(b.chord) : 'Ctrl-] PgUp'
        end

        # A new warning or error opens the messages pane below the REPL
        # (item 25: a count on the status line was easy to miss), with a
        # flash; NAV m takes it away again (the layout as it was).  Events
        # count in the order they happened, not the order the painter sees
        # them: a flash shown after the message came (an action's summary
        # naming its own failures, as KEYS mode's Enter capture does) stays,
        # and only the pane opens.
        def auto_messages
          seq = UI.messages.seq
          return if seq == @messages_seen
          @messages_seen = seq
          e = UI.messages.recent(1).first
          return unless e && e.severity != :note && !@tiler.layout.panes.include?(:messages)
          messages(true)
          f = @flash
          return if f && f[3] >= e.seq && @clock.call < f[2]
          flash("#{e.severity}: #{e.text}  (NAV m: away)", e.severity == :error ? :bad : :warn)
        end

        # True if +thread+ is the one running the REPL's commands (the
        # console's main thread when adopted, the Pry thread otherwise),
        # or one the palette runs a command on.
        def repl_thread?(thread = Thread.current)
          return false unless @host
          return true if thread[:mb_sound_ui_repl]
          @host.mode == :adopt ? thread.equal?(Thread.main) : thread.equal?(@host.thread)
        end
        public :repl_thread?

        # Lines the REPL's VT holds (scrollback and screen).
        def repl_lines
          vt = @host.vt
          vt.dropped + vt.scrollback.length + vt.row
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
            # Console Ruby: what it prints and its value go into the REPL
            # pane, as if typed there (item 22: help pages printed over the
            # screen), and a short result on the status line
            out = StringIO.new
            r = nil
            err = nil
            begin
              with_output_to(out) { r = b.eval(code, '(palette)', 1) }
            rescue StandardError, ScriptError => e
              err = e
            end
            text = out.string
            text += err ? "#{err.class}: #{err.message}\n" : "=> #{r.inspect}\n"
            print_to_repl(":#{code}\n#{text}")
            err ? flash("#{err.class}: #{err.message}", :bad) : flash("=> #{r.inspect}", :ok)
            r
          end
        end

        # Runs the block with $stdout and $stderr going to +io+.
        def with_output_to(io)
          out, err = $stdout, $stderr
          $stdout = $stderr = io
          Thread.current[:mb_sound_ui_repl] = true # (its warnings print with its output)
          yield
        ensure
          Thread.current[:mb_sound_ui_repl] = nil
          $stdout, $stderr = out, err
        end

        # Shows +text+ in the REPL pane above the prompt (the REPL redraws
        # its line below it), or in the messages without a console.
        def print_to_repl(text)
          if @host
            @host.print_above(text)
          else
            text.each_line { |l| UI.messages.add(l, severity: :note) }
          end
        end

        def palette_binding
          @context.is_a?(Binding) ? @context : (UI.console_binding || (@context ? @context.instance_eval { binding } : MB::Sound.instance_eval { binding }))
        end

        # Tab in the palette: completes a command or method name.
        def complete_palette
          l = @router.line or return
          word = l.text[0, l.cursor][/[a-z_][a-zA-Z0-9_]*\z/] or return
          names =
            if l.text[0, l.cursor - word.length].end_with?(':')
              # A Symbol: pane names (the catalog) and layouts (`show :sc` Tab)
              UI.pane_catalog.names.map(&:to_s) + UI.layout_table.map { |r| r[0].to_s }
            else
              (COMMANDS + palette_binding.receiver.public_methods(false) + palette_binding.local_variables).map(&:to_s).uniq
            end
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
          when MB::Term::Input::Mouse
            r = repl_rect
            if e.button >= 64 && r&.contains?(e.x, e.y)
              scroll(e.button == 64 ? 3 : -3)
            elsif e.action == :press && e.button < 3
              name, = @tiler.rects.find { |_, rr| rr.contains?(e.x, e.y) }
              tile { |t| t.focus!(name) } if name
            end
          when MB::Term::Input::Focus
            @full = true if e.in
            # Key releases go to the focused window: notes off on the way out
            @keyboard.all_off(mono_now) unless e.in
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

        # Waits up to +wait+ seconds for +io+ to be readable (true) or for
        # #stop's wake pipe (false, as at the timeout).
        def wait_input(io, wait)
          wake = @wake_r
          return io.wait_readable(wait) if wake.nil? || wake.closed?

          ready, = IO.select([io, wake], nil, nil, wait)
          return false unless ready
          wake.read_nonblock(64, exception: false) if ready.include?(wake)
          ready.include?(io)
        rescue IOError
          false
        end

        def read_input(timeout)
          io = @term.input
          now = @clock.call
          mono = mono_now
          waits = [@decoder.pending? ? @decoder.esc_timeout : nil, @router.wait(mono), @keyboard.wait(mono), @input_lock.synchronize { pane_wait }, timeout].compact
          wait = waits.min
          wait = 0.25 if wait.nil? && !timeout.nil?
          ready = wait_input(io, wait.nil? ? 0.5 : wait)
          return now if @stopping
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
          @input_lock.synchronize { @router.tick(Process.clock_gettime(Process::CLOCK_MONOTONIC)) }
          events.each { |e| handle(e) }
          @input_lock.synchronize { tick_panes } # (gestures whose keys stopped: their lines)
          (@painter&.wakeup rescue nil) if @keyboard.tick(mono_now)
          (@painter&.wakeup rescue nil) unless events.empty?
          now
        end

        def handle(e)
          @input_lock.synchronize { handle_unlocked(e) }
        end

        def handle_unlocked(e)
          if @hidden
            relay_event(e)
            return
          end
          @enter_mark = repl_lines if @host && e.is_a?(MB::Term::Input::Key) && e.key == :enter && e.mods.empty? && @router.state == :repl
          # Every key goes through the Router's table (Ctrl-C, Ctrl-Z, F2,
          # the overlay, prefixes included): one owner for input
          @router.event(e)
        rescue => e2
          flash("#{e2.class}: #{e2.message}", :bad)
        end

        # While hidden, input goes to the REPL's pty as typed (Ctrl-C
        # interrupts; Ctrl-Z shows the tiles again).
        def relay_event(e)
          return if e.is_a?(MB::Term::Input::Key) && e.release?

          case e
          when MB::Term::Input::Key
            case e.chord
            when ['c', [:ctrl]] then @host.interrupt
            when ['z', [:ctrl]] then show_again
            else @host.key(e)
            end
          when MB::Term::Input::Paste then @host.paste(e.text)
          end
        end

        ### Painter

        def paint_loop
          paced_loop(-> { @stopping || @hidden })
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
          @density = Density.decide(:tiles, @rows, @cols)
          @tiler.header_rule = @density.header_rule
          level_layout
          @placed = @tiler.placed
          @placed_layout = @tiler.layout
          klass = @cells_class
          if @grid.nil? || @grid.width != @cols || @grid.height != @rows
            @grid = klass.new(@cols, @rows)
            @shown = klass.new(@cols, @rows)
          end
          names = @placed.map(&:name).compact
          @feed.needs = names.flat_map { |n| @panes[n]&.needs || [] }.uniq
          rebuild_jumps(names)
          @chrome = chrome_plan
          # (Chrome draws every pane's title: panes draw their bodies only)
          # (and the screen's size level, for panes whose view depends on it:
          # the inspector's panel at 80x24, sections from 120x40)
          @placed.each do |pl|
            next unless pl.name
            @states[pl.name][:title_in_rule] = true
            @states[pl.name][:level] = @density.level
          end
          @canvases = {}
          @drawn_at = {}
          @relayout = false
          @full = true
          @repl_full = true
          r = repl_rect
          @host&.resize(r.h, r.w) if r && r.w > 0 && r.h > 0
        end

        # A built-in layout with smaller versions (UI.tile_layout_levels)
        # shown at the version for the screen's Density level, while the
        # layout on screen is one of its versions as built.
        def level_layout
          want = UI.tile_layout_at(@layout_name, @density.level) or return
          now = @tiler.layout
          return if now == want
          versions = [UI.tile_layouts[@layout_name], *UI.tile_layout_levels[@layout_name].values]
          @tiler.layout = want if versions.include?(now)
        end

        # Jump letters for the panes on screen ({name => letter}: Keys::JUMPS
        # by name or kind, else the kind's `jump`), and the keymap of the
        # declared ones (NAV_EXTRA binds the built-in letters).
        # NAV f: each pane's measured rate beside its number, refreshed in
        # the chrome once a second (only the changed cells are written).
        def refresh_rate_notes(now)
          return if @rate_notes_at && now - @rate_notes_at < 1.0
          @rate_notes_at = now
          @chrome = chrome_plan
          Chrome.paint(@grid, @chrome, glyphs: @glyphs, nav: %i[nav once].include?(@router.mode))
        end

        def rate_note(p)
          p.name == :repl || p.tabs ? nil : rate_text(p.name)
        end

        def rebuild_jumps(names)
          @jumps = {}
          @jump_map.entries.each { |b| @jump_map.off(b.chord[0]) }
          names.each do |n|
            pane = @panes[n]
            kind = PaneKeys.kind_of(pane) || n
            letter = Keys::JUMPS[n] || (pane.respond_to?(:jump) && pane.jump) || Keys::JUMPS[kind]
            next unless letter && !@jumps.value?(letter)
            @jumps[n] = letter
            next if Keys::JUMPS.value?(letter)
            @jump_map.on(letter, :jump, n, help: "#{pane&.title || n} (focus it, go in)")
          end
          # (panes a jump puts in for a while: Pane#temporary_rows)
          UI.panes.each_value do |pane|
            next if names.include?(pane.name) || !pane.temporary_rows(names)
            letter = pane.jump
            next unless letter && !@jumps.value?(letter) && !Keys::JUMPS.value?(letter)
            @jumps[pane.name] = letter
            @jump_map.on(letter, :jump, pane.name, help: "#{pane.title || pane.name} (put in for a while, go in; again: away)")
          end
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
          auto_messages
          relayout if @relayout || !@placed_layout.equal?(@tiler.layout)
          snap = snapshot
          heard_snap = heard(snap, now) # (meters and scopes: what reaches the speakers now)
          # Taken at the start: a redraw asked for while this frame paints
          # (another thread: a mode change, a closed overlay) stays asked
          # for, instead of being cleared when the frame ends
          full = @full
          @full = false
          if full
            @grid.clear
            Chrome.paint(@grid, @chrome, glyphs: @glyphs, nav: %i[nav once].include?(@router.mode))
          end

          drawn = 0
          items = @placed.filter_map do |p|
            next if p.tabs || p.name == :repl || !@panes[p.name]
            [p.name, p.name, @panes[p.name], p.opts[:rate], @drawn_at[p.name]]
          end
          draw = panes_to_draw(items, now, full, snap)
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
            next unless draw.include?(p.name)
            t0 = thread_cpu
            begin
              r = @chrome.frames[p.name]&.inner || p.rect
              # Every pane draws into the one grid (plot panes too), so the
              # overlays painted after the panes stay on top (ui-fix-3)
              canvas = (@canvases[p.name] ||= Canvas.new(@grid, r.x, r.y, r.w, r.h, glyphs: @glyphs))
              canvas.row = 0
              if pane.plot?
                pane.draw(canvas, pane.needs.empty? ? snap : heard_snap, @states[p.name], look: p.opts[:look] || @look)
              else
                pane.draw(canvas, pane.needs.empty? ? snap : heard_snap, @states[p.name])
              end
              @failures.delete(p.name)
            rescue => e
              pane_failed(p, e)
            end
            @drawn_at[p.name] = now
            @rates.drew(p.name, now)
            d = thread_cpu - t0
            (q = @pane_cpu[p.name]) << d
            q.shift if q.length > 200
            drawn += 1
            Thread.pass
          end
          refresh_rate_notes(now) if @show_fps && !full
          Chrome.paint_overlays(@grid, @chrome) if %i[nav overlay once].include?(@router.mode)
          draw_overlay if @overlay
          note_long_output
          draw_status(now, snap)

          cells = @grid.frame(full ? nil : @shown, @mode, row: 1, col: 1, sync: false)
          cells = '' if cells == "\e[0m" || cells.empty?
          @shown.copy_from(@grid)
          cursor = cursor_bytes
          out = nil
          if !cells.empty? || cursor != @last_cursor || full
            out = "\e[?2026h\e[?25l#{full ? "\e[0m\e[H\e[2J" : ''}#{cells}#{cursor}\e[?2026l"
            write(out)
            note_written(now, out.bytesize)
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
          marks = @match ? [[@match[0], @match[1], @match[2], MB::Term::VT::REVERSE | MB::Term::VT::UNDERLINE]] : nil
          @host.synchronize do
            @host.vt.invalidate if full || @repl_full
            @scroll = @scroll.clamp(0, @host.vt.scrollback.length)
            @host.vt.draw(@grid, r.x, r.y, r.w, r.h, offset: @scroll, marks: marks)
          end
          if @scroll > 0
            tag = @router.mode == :repl ? " #{@scroll} lines up (typing: live) " : " #{@scroll} lines up (G: live) "
            @grid.put_run(r.x + [r.w - tag.length, 0].max, r.y, tag[0, r.w], MB::Term::Cells.pack(Theme.rgb(:queued)), nil, MB::Term::Cells::REVERSE)
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
            @grid.put_run(x, r.y, label[0, [r.x + r.w - x, 0].max], MB::Term::Cells.pack(Theme.rgb(role)), nil, i == p.active ? MB::Term::Cells::REVERSE : 0)
            x += label.length + 1
            break if x >= r.x + r.w
          end
        end

        # The chrome of the current placements (UI::Chrome): rules between
        # panes, each pane's title (in the rule above it, else on a title
        # row when the pane has room) and number, the focused pane marked.
        # Panes right under a tab strip take their title from the strip.
        def chrome_plan
          order = @tiler.numbered
          strips = @placed.select(&:tabs).map(&:rect)
          items = @placed.map do |p|
            r = p.rect
            if p.tabs
              next Chrome::Item.new(name: :"tabs@#{r.x},#{r.y}", rect: r)
            end
            under_tabs = strips.any? { |t| t.y == r.y - 1 && t.x == r.x }
            title = under_tabs || p.name == :repl ? nil : @panes[p.name]&.title || (@panes[p.name] ? p.name.to_s : nil)
            n = order.index(p.name)
            Chrome::Item.new(name: p.name, rect: r, title: title, number: n && n + 1, focused: p.name == @tiler.focus,
                             jump: @jumps[p.name], note: @show_fps ? rate_note(p) : nil)
          end
          Chrome.plan(items, w: @cols, h: @rows - 1, rules: true)
        end

        # The key overlay (#key_help): groups in columns in a box centered
        # on the screen, over the panes.
        def draw_overlay
          cols = @overlay.map do |group, keys|
            kw = keys.map { |k, _| k.length }.max
            lines = [[group, nil]] + keys.map { |k, what| [k.ljust(kw), what] }
            [lines, lines.map { |a, b| b ? a.length + 2 + b.length : a.length }.max]
          end
          # Columns as wide as fit; groups fill each column downward
          avail_w = @cols - 4
          avail_h = @rows - 4
          columns = [[]]
          height = 0
          cols.each do |lines, w|
            if height > 0 && height + lines.length + 1 > avail_h
              columns << []
              height = 0
            end
            columns.last << [lines, w]
            height += lines.length + 1
          end
          widths = columns.map { |c| c.map(&:last).max }
          box_w = [widths.sum + 3 * (widths.length - 1) + 4, avail_w + 2].min
          box_h = [columns.map { |c| c.sum { |l, _| l.length + 1 } - 1 }.max + 4, avail_h + 2].min
          x0 = [(@cols - box_w) / 2, 0].max
          y0 = [(@rows - 1 - box_h) / 2, 0].max
          c = Canvas.new(@grid, x0, y0, box_w, box_h, glyphs: @glyphs).clear
          rule = @glyphs == :ascii ? ['+', '-', '|'] : ['┼', '─', '│']
          border = MB::Term::Cells.pack(Theme.rgb(:key))
          @grid.put_run(x0, y0, (@glyphs == :ascii ? '+' : '┌') + rule[1] * (box_w - 2) + (@glyphs == :ascii ? '+' : '┐'), border, nil, 0)
          @grid.put_run(x0, y0 + box_h - 1, (@glyphs == :ascii ? '+' : '└') + rule[1] * (box_w - 2) + (@glyphs == :ascii ? '+' : '┘'), border, nil, 0)
          (1...(box_h - 1)).each do |dy|
            @grid.put_run(x0, y0 + dy, rule[2], border, nil, 0)
            @grid.put_run(x0 + box_w - 1, y0 + dy, rule[2], border, nil, 0)
          end
          title = ' keys (Esc closes; a key listed here closes and acts) '
          c.text([(box_w - title.length) / 2, 1].max, 0, c.fit(title, box_w - 2), :title)
          x = 2
          columns.each_with_index do |column, i|
            y = 2
            column.each do |lines, _|
              lines.each do |a, b|
                break if y >= box_h - 1
                if b.nil?
                  c.text(x, y, c.fit(a, box_w - x - 2), :title)
                else
                  c.line(y, [a, :key], '  ', [c.fit(b, [box_w - x - a.length - 4, 0].max), :dim], x: x)
                end
                y += 1
              end
              y += 1
            end
            x += widths[i] + 3
            break if x >= box_w - 2
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
          step = mode == :grab && @keyboard.entry == :step
          badge = mode == :once || (mode == :overlay && @router.once_return) ? ' ^W ' : %i[nav overlay].include?(mode) ? ' NAV ' : mode == :grab ? (step ? ' STEP ' : ' KEYS ') : mode == :pane ? " #{@tiler.focus.to_s.upcase} " : @host ? ' REPL ' : ' PLAY '
          role = %i[nav overlay once].include?(mode) ? :armed : mode == :grab ? (step ? :queued : :rec) : mode == :pane ? :queued : :key
          @grid.put_run(0, y, badge, MB::Term::Cells.pack(Theme.rgb(role)), nil, MB::Term::Cells::REVERSE | MB::Term::Cells::BOLD)
          x = badge.length + 1
          right = snap ? "#{snap.playing ? c.glyph(:play) : c.glyph(:stop)} #{snap.stamp} " : ''
          right = "#{frame_rate[:text]}  #{right}" if @show_fps
          unread = UI.messages.unread
          if unread > 0 && !@tiler.layout.panes.include?(:messages)
            badge_w = " ! #{unread} (m) "
            right = badge_w + right
            warn_at = @cols - right.length
          end
          flash = @flash && now < @flash[2] ? @flash : nil
          @flash = nil if @flash && !flash
          x = c.line(0, [@tiler.focus.to_s, :name], (@tiler.layout.zoom ? [' (zoomed)', :warn] : ' '), x: x)
          room = @cols - x - right.length - 1
          if flash
            c.text(x + 1, 0, c.fit(flash[0], room), flash[1])
          else
            hint =
              if @router.state == :pending then "#{MB::Term::Input::Keymap.chord_name(@router.prefix.key.chord)} ..."
              elsif mode == :play then @status_note || @hints || ''
              elsif mode == :pane then "#{enter_hint}Esc nav  ? keys  #{(m = @panes[@tiler.focus]&.mode_keymap) ? Keys.hints(m) : ''}"
              else HINTS[step ? :step : mode] || ''
              end
            c.text(x + 1, 0, c.fit(hint, room), @status_note && mode == :play ? :key : :dim)
          end
          c.text(@cols - right.length, 0, right, :key) unless right.empty?
          c.text(warn_at, 0, badge_w, :warn) if warn_at
        end

        # "Enter: <what it does>  " for the focused pane in its mode, when
        # the pane names it (#enter_hint: the sound-design screen names
        # Enter's action before it is pressed), else "".
        def enter_hint
          p = @panes[@tiler.focus]
          h = p.respond_to?(:enter_hint) ? p.enter_hint(@states[@tiler.focus]) : nil
          h ? "Enter: #{h}  " : ''
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
          r = p.rect
          c = Canvas.new(@grid, r.x, r.y, r.w, r.h, glyphs: @glyphs).clear
          c.puts ["#{p.name} failed: ", :bad], [e.message, :dim]
        end

        # The one way frames reach the terminal (pattern A: one owner).
        # Frames place every cell with cursor moves, so a bare newline or
        # carriage return is a bug that would scroll the screen: it is
        # dropped and warned about (specs fail on the warning).
        def write(str)
          if str.match?(/[\n\r]/)
            unless @stray_warned
              @stray_warned = true
              warn 'UI frame with a raw newline (a cell got a control character); dropped from the frame'
            end
            str = str.delete("\n\r")
          end
          timed_write { @term.write(str) }
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
          return if @signals # (installing twice would chain to our own wrapper)
          tiles = self
          old = nil
          @winch = Signals.handler do |sig|
            tiles.instance_variable_set(:@resized, true)
            old.call(sig) if old.respond_to?(:call)
          end
          old = Signals.chain('WINCH', @winch)
          @old_winch = old
          @signals = true
        rescue ArgumentError
          nil
        end

        def restore_signals
          return unless @signals
          Signals.unchain('WINCH', @winch, @old_winch)
          @signals = false
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
