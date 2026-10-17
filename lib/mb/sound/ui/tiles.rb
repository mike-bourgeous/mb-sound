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
          repl: 'Ctrl-] nav  F2 keys',
          nav: '? keys  1-9/hjkl pane  z zoom  s/v split  x close  arrows size  =  u/^R undo  [] tabs  / search  y copy  : cmd  p keys  i back',
          grab: 'Ctrl-]/F2 back  z..m q..] notes  -/+ octave  Up/Dn velocity  Space sustain  Esc all off  Enter capture  ` note-off  Tab step',
          step: 'Ctrl-] back  z..m notes  1-7 length  8 dot  9 triplet  r rest  t tie  a accent  ` slide  BkSp undo  p play  w swap in  Enter done  Tab play',
        }.freeze

        # NAV keys of mb-sound's own panes (after Router::NAV).
        NAV_EXTRA = Input::Keymap.new(:tiles) do
          on 'p', :keys
          on '?', :key_help
          on 'm', :messages
          on 'f', :show_fps
        end

        # The keys by mode, in groups ([group, [[keys, what], ...]]): the
        # `?` overlay in NAV mode shows the :nav groups and the focused
        # pane's (the keyboard's :grab or :step), and `help :ui` prints
        # them (Tiles.key_table).
        KEY_HELP = {
          nav: [
            ['Panes', [
              ['1-9', 'pick a pane by its number'], ['Tab S-Tab h j k l', 'next, previous, by direction'],
              ['z', 'zoom (again: back)'], ['s v', 'split below, beside'], ['x', 'close (the REPL stays)'],
              ['=', 'even out sizes'], ['arrows', 'resize by 1 (Shift: 5)'], ['[ ]', 'previous, next tab'],
              ['u Ctrl-R', 'undo, redo'],
            ]],
            ['Console', [
              ['PgUp PgDn', 'scroll the REPL (also Ctrl-B Ctrl-F)'], ['g G', 'oldest line, live'],
              ['/ n N', 'search back, next, previous'], ['y', 'copy the match or the view (OSC 52)'],
              [':', 'run a line of Ruby (show :knobs, go :drop)'], ['Ctrl-L', 'redraw'],
            ]],
            ['Modes', [
              ['p F2', 'play the keyboard (KEYS; F2 also from the REPL)'], ['m', 'messages (warnings) pane, again: away'], ['f', 'frame rate on the status line'], ['i Esc Enter Ctrl-]', 'back to the REPL'],
              ['Ctrl-Z', 'hide the tiles (the set plays on; Ctrl-Z or ui: back)'], ['?', 'this help'],
            ]],
          ],
          grab: [
            ['Keyboard', [
              ['z s x d c v ...', 'notes from C3 (lower row)'], ['q 2 w 3 e r ...', 'notes from C4 (upper row)'],
              ['- + Left Right', 'octave down, up'], ['Up Down', 'velocity'], ['Shift / Ctrl', 'accent / soft'],
              ['Space', 'sustain'], ['Esc', 'all notes off'], ['Enter', 'capture into the armed tracks'],
              ['`', 'note-off mode'], ['Tab', 'step entry'], ['Ctrl-] Ctrl-C F2', 'back to the REPL'],
            ]],
          ],
          step: [
            ['Step entry', [
              ['z x c v ...', 'a note (several at once: a chord)'], ['1-7', 'whole .. 64th'], ['8 9', 'dotted, triplet'],
              ['r t', 'rest, tie'], ['a `', 'accent, slide the last step'], ['BkSp Del', 'undo a step, clear'],
              ['p', 'play the clip'], ['w', 'swap it into the armed tracks'], ['Enter', 'done: its Ruby on the REPL line'],
              ['Tab', 'back to playing'],
            ]],
          ],
        }.freeze

        # The key table for +modes+ as text lines (for help :ui).
        def self.key_table(*modes)
          modes = KEY_HELP.keys if modes.empty?
          modes.flat_map do |m|
            KEY_HELP.fetch(m).flat_map do |group, keys|
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

        # +layout+ a Viewports::Layout with a repl pane; +input+/+output+
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
                       glyphs: UI.glyphs, size: nil, clock: nil, native: Plot.native, fps: 60, panes: UI.panes, source: nil,
                       mouse: false, nav_esc: nil, kitty: false, context: nil, probe: true, scrollback: VT::SCROLLBACK, pry: {},
                       keyboard: nil, keys_kitty: nil, on_key: nil, hints: nil)
          # (Every instance variable set up front, in one order: one object shape)
          @term = @ambiguous = @host = @stopping = @full = @painter = @reader = @hidden = @relayout = @repl_full = @match = @search = @flash = @reloaded_at = @size_checked_at = @resized = @placed = @placed_layout = @grid = @shown = @canvases = @drawn_at = @first_refresh = @last_cursor = @line_cursor = @old_winch = @signals = @attached = @poll = @polled_at = @poll_warned = @last = @painter_warned = nil
          raise ArgumentError, "Layout #{layout.name.inspect} has no repl pane (`repl` in the layout block)" unless layout.repl? || repl == :none
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
          @message_close = nil
          @show_fps = false
          @pane_cpu = Hash.new { |h, k| h[k] = [] }
          @chrome = nil
          @density = nil
          @rows, @cols = @fixed_size || [24, 80]
          @tiler = Viewports::Tiler.new(layout, @cols, @rows - 1)
          # Panes' declared minimum heights (UI::Pane#min_height)
          @tiler.mins = ->(name, axis) { axis == :rows ? @panes[name]&.min_height || (name == :repl ? REPL_MIN_ROWS : nil) : nil }
          @router = Input::Router.new(self, nav_esc: nav_esc)
          @router.add_keymap(NAV_EXTRA)
          @decoder = Input::Decoder.new
          @keyboard = keyboard || UI.keyboard
          @keys_kitty = keys_kitty
          @states[:keyboard][:keyboard] = @keyboard
          @kitty_pushed = false
          @start_keys = layout.focus == :keyboard
          @on_key = on_key
          @hints = hints
          @note = nil
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

          @term = Term.new(input: @input.dup, output: @output.dup)
          @term.enter(mouse: @mouse, kitty: @kitty)
          features = @probe ? @term.probe : {}
          @ambiguous = features[:ambiguous] || (::Reline.core.instance_variable_get(:@ambiguous_width) rescue nil) || 1
          @glyphs = :ascii if @ambiguous == 2 && @glyphs == :unicode && ENV['MB_SOUND_UI_GLYPHS'].to_s.empty?
          @rows, @cols = terminal_size
          @tiler.resize_screen(@cols, @rows - 1)
          relayout
          unless @repl_mode == :none
            r = repl_rect || Viewports::Rect.new(0, 0, [@cols, 20].min, [@rows - 1, 5].max)
            @host = Input::ReplHost.new(rows: r.h, cols: r.w, mode: @repl_mode, scrollback: @scrollback, ambiguous_width: @ambiguous,
                                        target: @context || TOPLEVEL_BINDING, pry: @pry_opts)
            @host.start
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
            flash('a big terminal: ui :wall shows every pane at once', :dim)
          end
          if thread
            @painter = Thread.new { paint_loop }
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
          @reader&.join(0.5) unless Thread.current.equal?(@reader)
          @reader&.kill unless Thread.current.equal?(@reader)
          @painter&.join(1)
          @painter = @reader = nil
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
            rate = p.opts[:rate].is_a?(Numeric) ? p.opts[:rate] : pane&.rate
            PaneOnScreen.new(number: n && n + 1, name: p.name, kind: kind, title: pane&.title, rect: p.rect, focused: p.name == @tiler.focus,
                             zoomed: @tiler.layout.zoom == p.name, rate: rate,
                             look: pane&.bytes? ? (@states[p.name][:look] || p.opts[:look] || @look) : nil, title_at: @chrome&.frames&.dig(p.name)&.at)
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
            raise Viewports::Error, 'The REPL pane stays (z zooms another pane over it)' if name == :repl
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

        # Shows pane +name+ in the focused slot (or +at+).
        def show(name, at: nil) = tile { |t| t.show(name, at: at || t.focus) }

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
          raise ArgumentError, "#{pane.inspect} isn't a plot pane (scope, spectrum): its look is fixed" unless @panes[pane]&.bytes?
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
          return exit_keys.then { self } unless on

          start if @hidden # (from the hidden console: the tiles come back first)
          @keyboard.off_mode = off if off
          @keyboard.entry = step ? :step : :play unless step.nil?
          @keyboard.out.patch = patch if patch != :keep && @keyboard.out.respond_to?(:patch=)
          unless @tiler.layout.panes.include?(:keyboard)
            tile do |t|
              t.split(@tiler.layout.panes.include?(:repl) ? :repl : t.focus, :rows, :keyboard)
              fit_height(t, :keyboard, 8)
            end
          end
          tile { |t| t.focus!(:keyboard) }
          @router.mode = :grab
          self
        end

        # Puts pane +kind+ (:scope, :spectrum, :messages) on the screen for
        # a while (a plot from PlaybackMethods#visualize, the messages
        # pane): nothing if the layout shows it, else a slot of +height+
        # rows taken from the largest flexible pane that isn't the REPL or
        # the keyboard (UI::Viewports::Tiler#open_temporary; the focus
        # stays).  Returns a Proc that closes the slot again, putting the
        # split tree back exactly as it was if nothing else changed it
        # (ux-1 r3 item 30), or nil if nothing changed.
        def plot_pane(kind, height: 10)
          temp = nil
          tile { |t| temp = t.open_temporary(kind, height, keep: TEMPORARY_KEEP, fallback: :repl) }
          return nil unless temp
          -> { tile { |t| t.close_temporary(temp) } }
        end

        # The REPL pane's smallest height.
        REPL_MIN_ROWS = 4

        # Panes temporary panes never take their rows from.
        TEMPORARY_KEEP = %i[repl keyboard].freeze

        # What is wrong with the mode state, as a list (empty when every
        # invariant holds): KEYS mode's keyboard, kitty flags, and notes
        # follow the router's mode exactly, and nothing plays the keyboard
        # while hidden.  Every way into and out of KEYS goes through
        # #mode_changed, which keeps these; a spec drives random key
        # sequences against them.
        def mode_problems
          grab = @router.mode == :grab
          out = []
          out << "keyboard #{@keyboard.active? ? 'active' : 'inactive'} in #{@router.mode} mode" if grab != @keyboard.active?
          out << "kitty flags pushed in #{@router.mode} mode" if @kitty_pushed && !grab
          out << 'KEYS mode while hidden' if grab && @hidden
          out << "notes #{@keyboard.held.inspect} held in #{@router.mode} mode" if !grab && !@keyboard.held.empty?
          if @host
            out << 'no REPL pane' unless @tiler.layout.panes.include?(:repl)
            out << "REPL mode with #{@tiler.layout.zoom.inspect} zoomed over the REPL" if @router.mode == :repl && @tiler.layout.zoom && @tiler.layout.zoom != :repl
          end
          out
        end

        # Shows (or hides) the key overlay: NAV's keys, and the focused
        # pane's (the keyboard's).  Any key closes it.
        def key_help(on = @overlay.nil?)
          @lock.synchronize do
            @overlay =
              if on
                groups = KEY_HELP[:nav].dup
                groups += KEY_HELP[@keyboard.entry == :step ? :step : :grab] if @tiler.focus == :keyboard
                groups
              end
            @full = true
          end
          self
        end

        # Shows the messages pane (warnings and live errors while the UI is
        # up; see UI::Messages) in a slot below the REPL, or takes it away
        # again (+on+ false).  Marks the messages read.
        def messages(on = !@tiler.layout.panes.include?(:messages))
          UI.messages.mark_read
          if on
            @messages_restore ||= plot_pane(:messages, height: 8)
          elsif @messages_restore
            @messages_restore.call
            @messages_restore = nil
          else
            close(:messages) if @tiler.layout.panes.include?(:messages)
          end
          self
        end

        # Shows the measured frame rate on the status line ("42 fps · 0.3
        # ms · 18 kB/s": frames written per second, the painter's CPU per
        # frame, bytes per second; see FrameRate), or hides it.
        def show_fps(on = true)
          @show_fps = on
          self
        end

        # Shows +text+ on the status line for a few seconds (+role+ its
        # color: :ok, :warn, :bad, ...).
        def say(text, role = :text)
          flash(text, role)
          self
        end

        # A note that stays on the status line instead of the hints (nil:
        # none), e.g. "song ended: q quits" for a script's screen.
        attr_accessor :note

        # True while the key overlay shows.
        def key_help? = !@overlay.nil?

        ### Router host (called on the input thread)

        # A key in KEYS mode (:grab).
        def grab_key(k)
          handled = @keyboard.key(k, mono_now)
          flash("#{k}: not a key here (Ctrl-] back)", :dim) unless handled || k.release?
          @painter&.wakeup rescue nil
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

        def mode_changed(m)
          @full = true
          return enter_keys if m == :grab

          was = @keyboard.active?
          leave_keys
          # Out of KEYS, the focus goes back to the REPL, so a NAV round
          # trip (Ctrl-] i or Enter) comes back to the REPL, not into the
          # keyboard (where Up and Down change the velocity)
          tile { |t| t.focus!(:repl) } if was && m == :repl && @tiler.layout.panes.include?(:repl)
          # Typing goes to the REPL, so it must be on screen: a zoom on
          # another pane ends (zoom the REPL itself to keep a big one)
          z = @tiler.layout.zoom
          tile { |t| t.zoom(z) } if m == :repl && z && z != :repl && @host
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
          when :mode
            # i or Enter on the keyboard pane go back into it
            to = a.args[0] == :repl && @tiler.focus == :keyboard && @router.mode == :nav ? :grab : a.args[0]
            @router.mode = to
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
          when :panic then run_safely { UI.run_line('panic', keys_session || Session.current) }
          when :keys then keys
          when :key_help then key_help
          when :messages then messages
          when :show_fps then show_fps(!@show_fps)
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

        def read_input(timeout)
          io = @term.input
          now = @clock.call
          mono = mono_now
          waits = [@decoder.pending? ? @decoder.esc_timeout : nil, @router.wait(mono), @keyboard.wait(mono), timeout].compact
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
          (@painter&.wakeup rescue nil) if @keyboard.tick(mono_now)
          (@painter&.wakeup rescue nil) unless events.empty?
          now
        end

        def handle(e)
          if @hidden
            relay_event(e)
            return
          end
          if @overlay && e.is_a?(Input::Key) && !e.release?
            # Any key closes the key overlay (and does nothing else); under
            # the screen lock, so a frame being painted can't drop the
            # full redraw that takes it off
            key_help(false)
            return
          end
          if e.is_a?(Input::Key) && @router.mode != :line
            return if e.release? && @router.mode != :grab
            case e.chord
            when ['c', [:ctrl]]
              if @router.mode == :grab
                # Ctrl-C in KEYS mode: everything off, back to the REPL
                @keyboard.all_off(mono_now)
                @router.mode = :repl
                return
              end
              @scroll = 0
              @host ? @host.interrupt : @on_key&.call(:interrupt)
              return
            when ['z', [:ctrl]]
              hide if @host
              return
            when [:f2, []]
              # F2: between the REPL and KEYS
              return if e.release?
              @router.mode == :grab ? (@router.mode = :repl) : keys
              return
            end
          end
          @router.event(e)
        rescue => e2
          flash("#{e2.class}: #{e2.message}", :bad)
        end

        # While hidden, input goes to the REPL's pty as typed (Ctrl-C
        # interrupts; Ctrl-Z shows the tiles again).
        def relay_event(e)
          return if e.is_a?(Input::Key) && e.release?

          case e
          when Input::Key
            case e.chord
            when ['c', [:ctrl]] then @host.interrupt
            when ['z', [:ctrl]] then show_again
            else @host.key(e)
            end
          when Input::Paste then @host.paste(e.text)
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
          @placed = @tiler.placed
          @placed_layout = @tiler.layout
          klass = @native ? Plot::Text::NativeCells : Plot::Text::Cells
          if @grid.nil? || @grid.width != @cols || @grid.height != @rows
            @grid = klass.new(@cols, @rows)
            @shown = klass.new(@cols, @rows)
          end
          names = @placed.map(&:name).compact
          @feed.needs = names.flat_map { |n| @panes[n]&.needs || [] }.uniq
          @chrome = chrome_plan
          # (Chrome draws every pane's title: panes draw their bodies only)
          @placed.each { |pl| @states[pl.name][:title_in_rule] = true if pl.name }
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
          # Taken at the start: a redraw asked for while this frame paints
          # (another thread: a mode change, a closed overlay) stays asked
          # for, instead of being cleared when the frame ends
          full = @full
          @full = false
          if full
            @grid.clear
            Chrome.paint(@grid, @chrome, glyphs: @glyphs, nav: @router.mode == :nav)
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
            t0 = thread_cpu
            begin
              r = @chrome.frames[p.name]&.inner || p.rect
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
            d = thread_cpu - t0
            (q = @pane_cpu[p.name]) << d
            q.shift if q.length > 200
            drawn += 1
            Thread.pass
          end
          Chrome.paint_overlays(@grid, @chrome) if @router.mode == :nav
          draw_overlay if @overlay
          draw_status(now, snap)

          cells = @grid.frame(full ? nil : @shown, @mode, row: 1, col: 1, sync: false)
          cells = '' if cells == "\e[0m" || cells.empty?
          bytes = '' if bytes.delete("\e[0m").empty?
          @shown.copy_from(@grid)
          cursor = cursor_bytes
          out = nil
          if !cells.empty? || !bytes.empty? || cursor != @last_cursor || full
            out = "\e[?2026h\e[?25l#{full ? "\e[0m\e[H\e[2J" : ''}#{cells}#{bytes}#{cursor}\e[?2026l"
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
            Chrome::Item.new(name: p.name, rect: r, title: title, number: n && n + 1, focused: p.name == @tiler.focus)
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
          border = Plot::Text::Cells.pack(Theme.rgb(:key))
          @grid.put_run(x0, y0, (@glyphs == :ascii ? '+' : '┌') + rule[1] * (box_w - 2) + (@glyphs == :ascii ? '+' : '┐'), border, nil, 0)
          @grid.put_run(x0, y0 + box_h - 1, (@glyphs == :ascii ? '+' : '└') + rule[1] * (box_w - 2) + (@glyphs == :ascii ? '+' : '┘'), border, nil, 0)
          (1...(box_h - 1)).each do |dy|
            @grid.put_run(x0, y0 + dy, rule[2], border, nil, 0)
            @grid.put_run(x0 + box_w - 1, y0 + dy, rule[2], border, nil, 0)
          end
          title = ' keys (any key closes) '
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
          badge = mode == :nav ? ' NAV ' : mode == :grab ? (step ? ' STEP ' : ' KEYS ') : @host ? ' REPL ' : ' PLAY '
          role = mode == :nav ? :armed : mode == :grab ? (step ? :queued : :rec) : :key
          @grid.put_run(0, y, badge, Plot::Text::Cells.pack(Theme.rgb(role)), nil, Plot::Text::Cells::REVERSE | Plot::Text::Cells::BOLD)
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
            hint = mode == :repl && !@host ? (@note || @hints || '') : (HINTS[step ? :step : mode] || '')
            c.text(x + 1, 0, c.fit(hint, room), @note && mode == :repl && !@host ? :key : :dim)
          end
          c.text(@cols - right.length, 0, right, :key) unless right.empty?
          c.text(warn_at, 0, badge_w, :warn) if warn_at
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
          tiles = self
          old = nil
          old = Signal.trap('WINCH') do |sig|
            tiles.instance_variable_set(:@resized, true)
            old.call(sig) if old.respond_to?(:call)
          end
          @old_winch = old
          @signals = true
        rescue ArgumentError
          nil
        end

        def restore_signals
          return unless @signals
          Signal.trap('WINCH', @old_winch || 'DEFAULT')
          @signals = false
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
