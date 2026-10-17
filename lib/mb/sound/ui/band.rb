require 'io/console'

module MB
  module Sound
    module UI
      # The dashboard band: a few rows at the top (or bottom) of the
      # terminal kept out of scrolling with a scroll region (DECSTBM), so
      # Pry runs unchanged in the rest of the screen.  A painter thread
      # draws the layout's panes from the feed's snapshots into a native
      # cell grid, each at its own rate, passing the GVL between panes,
      # and writes only the cells that changed, each refresh one write:
      # synchronized output (DEC 2026), save cursor, cursor moves and
      # cells, restore cursor.  See design/notes/terminal_ui.md.
      #
      # Resizes (SIGWINCH, and a size check twice a second) reissue the
      # region and redraw; every REASSERT seconds the region is reissued
      # and the band redrawn anyway, in case something reset the terminal
      # (`reset`, a pager, Ctrl-L).
      class Band
        include FrameRate
        include Follow

        # Seconds between reissuing the scroll region with a full redraw.
        REASSERT = 2.0

        # Seconds between size checks (besides SIGWINCH).
        SIZE_CHECK = 0.5

        # Seconds between Poll runs (slow data).
        POLL = 0.25

        # Rows the terminal must have below (or above) the band.
        MIN_PROMPT_ROWS = 3

        # Frame statistics kept.
        STATS = 2000

        # Painter CPU seconds above which a pane (or the poll) is listed in
        # a slow refresh (Band#stats[:slowest]).
        SLOW_PART = 0.0005

        # Slowest refreshes kept for #stats.
        SLOWEST = 5

        attr_reader :layout, :position, :mode, :look, :rows, :cols, :height, :placed, :feed

        # The size decision (UI::Density), the layout as shown at its level
        # (`only: :big` panes in or out), and the pane chrome (UI::Chrome).
        attr_reader :density, :shown_layout, :chrome

        # The painter thread (nil while off or painting only on #refresh).
        attr_reader :thread

        # +layout+ a Layout; +io+ the terminal; +session+ a Session (nil to
        # follow Session.existing); +at+ :bottom (default, maintainer
        # 2026-10-17: lines scrolled out reach the terminal's scrollback) or
        # :top; +color+ a
        # Plot::Text color mode (:ansi256 by default: the fewest bytes per
        # frame for color); +look+ the scope panes' Plot look; +size+
        # [rows, cols] for a non-terminal +io+; +clock+ a Proc returning
        # seconds (for specs); +native+ false draws into the Ruby mirror
        # grid (Plot::Text::Cells); +source+ a Proc returning the Snapshot
        # to draw instead of following a Session (specs, captures).
        def initialize(layout:, io: $stdout, session: nil, at: :bottom, color: :ansi256, look: :auto, glyphs: UI.glyphs, size: nil, clock: nil, native: Plot.native, fps: 60, panes: UI.panes, source: nil)
          # (Every instance variable set up front, in one order: one object shape)
          @stopping = @thread = @first_refresh = @reasserted_at = @full = @resized = @rows = @cols = @density = @shown_layout = @boxed = @height = @placed = @rule_row = @grid = @shown = @chrome = @size_checked_at = @old_winch = @winch_installed = @attached = @poll = @polled_at = @poll_warned = @last = @painter_warned = nil
          raise ArgumentError, "at: is :top or :bottom (got #{at.inspect})" unless %i[top bottom].include?(at)
          raise ArgumentError, "Unknown color mode #{color.inspect}" unless Plot::Text::Cells::MODES.key?(color)

          @layout = layout
          @io = io
          @session = session
          @position = at
          @messages_seen = UI.messages.seq
          @mode = color
          @look = look
          @glyphs = glyphs
          @fixed_size = size
          @clock = clock || -> { MB::U.clock_now }
          @native = native
          init_frame_rate(fps)
          @panes = panes
          @source = source
          @feed = Feed.new
          @refresh_lock = Mutex.new
          @active = false
          @frames = []
          @slowest = []
          @yields = 0
          @failures = {}
          relayout(*terminal_size)
        end

        # True while the band is on screen.
        def active?
          @active
        end

        # True for a band at the top of the screen.
        def top?
          @position == :top
        end

        # The first row of the band (1-based).
        def band_top
          top? ? 1 : @rows - @height + 1
        end

        # The scroll region left for Pry: [first, last] rows (1-based).
        def region
          top? ? [@height + 1, @rows] : [1, @rows - @height]
        end

        # Sets up the terminal (scrolls the screen to make room, sets the
        # scroll region) and starts the painter thread (+thread: false+
        # paints only on #refresh, for specs).  Returns self.
        def start(thread: true)
          return self if @active

          @active = true
          setup_terminal
          install_winch
          RelineGuard.install
          @stopping = false
          @thread = Thread.new { paint_loop } if thread
          self
        end

        # Stops painting, resets the scroll region, and clears the band.
        def stop
          return self unless @active

          @stopping = true
          @thread&.wakeup rescue nil
          @thread&.join(2)
          @thread = nil
          @active = false
          restore_winch
          detach
          clear = (0...@height).map { |r| "\e[#{band_top + r};1H\e[2K" }.join
          write("\e7\e[r#{clear}\e8")
          self
        end

        # Draws the next frame now (the painter thread calls this at its
        # rate).  Returns the bytes written (nil if nothing changed).
        def refresh(now = @clock.call)
          @refresh_lock.synchronize { refresh_unlocked(now) }
        end

        private def refresh_unlocked(now)
          cpu0 = thread_cpu
          @first_refresh ||= now
          parts = nil
          attach
          poll(now)
          check_size(now)
          snap = snapshot
          c = thread_cpu
          (parts ||= {})[:poll] = c - cpu0 if c - cpu0 > SLOW_PART

          # Warnings kept off the terminal show in a strip of messages
          if (seen = UI.messages.seq) != @messages_seen
            @messages_seen = seen
            plot_pane(:messages, height: 4) if owns_terminal? && !@shown_layout.pane_names.include?(:messages)
          end

          reassert = @full || @reasserted_at.nil? || now - @reasserted_at >= REASSERT
          @reasserted_at = now if reassert
          return nil if @rows < @height + MIN_PROMPT_ROWS

          # Taken at the start: a redraw asked for while this frame paints
          # (another thread: a new layout) stays asked for
          full = reassert
          @full = false

          top = band_top
          drawn = 0
          bytes = +''
          paint_chrome if full
          @placed.each do |p|
            next unless full || p.drawn_at.nil? || now - p.drawn_at >= 1.0 / p.pane.rate - 0.001

            c = thread_cpu
            r = p.state[:inner]
            begin
              if r.h <= 0
                nil
              elsif p.pane.bytes?
                b = p.pane.frame_bytes(snap, p.state, row: top + r.y, col: 1 + r.x, w: r.w, h: r.h, mode: @mode, look: @look, full: full)
                bytes << b if b
              else
                canvas = (p.state[:canvas] ||= Canvas.new(@grid, r.x, r.y, r.w, r.h, glyphs: @glyphs))
                canvas.row = 0
                p.pane.draw(canvas, snap, p.state)
              end
              @failures.delete(p.pane.name)
            rescue => e
              pane_failed(p, e)
            end
            p.drawn_at = now
            d = thread_cpu - c
            (parts ||= {})[p.pane.name] = d if d > SLOW_PART
            drawn += 1
            @yields += 1
            Thread.pass # the render thread waits at most one pane's draw for the GVL
          end

          cells = @grid.frame(full ? nil : @shown, @mode, row: top, col: 1, sync: false)
          cells = '' if cells == EMPTY_FRAMES[@mode]
          bytes = '' if bytes.empty? || bytes.delete("\e[0m").empty?
          @shown.copy_from(@grid)
          region_cmd = reassert ? "\e[#{region[0]};#{region[1]}r" : ''

          out = nil
          if !cells.empty? || !bytes.empty? || reassert
            out = "\e[?2026h\e7#{region_cmd}#{cells}#{bytes}\e8\e[?2026l"
            write(out)
            note_written(now, out.bytesize)
          end

          cpu = thread_cpu - cpu0
          @frames << [cpu, out&.bytesize || 0, drawn]
          @frames.shift if @frames.length > STATS
          note_slow(now, cpu, parts) if cpu > SLOW_PART
          out
        end

        # Redraws everything on the next frame (after the screen was
        # cleared).
        def invalidate
          @full = true
        end

        # Painter costs over the last frames: :frames, :cpu_ms (p50, p99,
        # max of the painter's CPU time per refresh, including frames with
        # nothing to draw), :busy_cpu_ms (the same over refreshes that drew
        # a pane), :bytes (mean and max per written frame), :panes (mean
        # drawn per refresh), :yields (Thread.pass calls so far),
        # :slowest (the slowest refreshes: when (seconds after the first), CPU ms,
        # and the poll or panes that took over half a millisecond).
        def stats
          busy = @frames.select { |f| f[2] > 0 }
          written = @frames.map { |f| f[1] }.reject(&:zero?)
          {
            frames: @frames.length,
            cpu_ms: UI.percentiles(@frames.map { |f| f[0] * 1000 }),
            busy_cpu_ms: UI.percentiles(busy.map { |f| f[0] * 1000 }),
            bytes: { mean: written.empty? ? 0 : written.sum / written.length, max: written.max || 0 },
            panes: @frames.empty? ? 0 : @frames.sum { |f| f[2] }.to_f / @frames.length,
            yields: @yields,
            fps: fps,
            target_fps: @target_fps,
            pacing: @pacer.breakdown,
            slowest: @slowest.map { |at, cpu, parts|
              { at: MB::M.sigfigs(at, 4), cpu_ms: MB::M.sigfigs(cpu * 1000, 3), parts: (parts || {}).transform_values { |v| MB::M.sigfigs(v * 1000, 3) } }
            },
          }
        end

        # The band's text now (the cells, without the scope panes' bytes),
        # in color +mode+ (:none for plain text).
        def to_text(mode = :none)
          @grid.to_text(mode)
        end

        # Panes that raised (name => message); a failing pane shows its
        # error and is retried at its rate.
        def failures
          @failures.dup
        end

        # Replaces the layout (keeping the band on screen).
        def layout=(layout)
          old_height = @height
          @layout = layout
          relayout(@rows, @cols)
          if @active && old_height != @height
            # Clear the old band and set the new region
            clear = (1..@rows).select { |r| top? ? r <= [old_height, @height].max : r > @rows - [old_height, @height].max }.map { |r| "\e[#{r};1H\e[2K" }.join
            write("\e7\e[r#{clear}\e8")
            setup_terminal(scroll: @height > old_height ? @height - old_height : 0)
          end
          @full = true
        end

        # True when the band draws on the process's terminal (so stderr
        # would land in it: UI::Messages keeps warnings off it).
        def owns_terminal?
          @active && @io.respond_to?(:tty?) && @io.tty? && $stderr.tty?
        rescue IOError
          false
        end

        # Puts pane +kind+ (:scope, :spectrum) on the band for a plot (see
        # PlaybackMethods#visualize): nothing if the layout has it, else a
        # row of it under the layout.  Returns a Proc that takes the row
        # out again (nil if nothing changed).
        def plot_pane(kind, height: 8)
          return nil if @shown_layout.pane_names.include?(kind)
          old = @layout
          l = Layout.new(old.name) { cols { pane kind, height: height } }
          l.root.children.unshift(*old.root.children)
          self.layout = l
          -> { self.layout = old if @layout.equal?(l) }
        end

        # Saves the layout as Ruby (see LayoutLoader) to UI.layouts_dir, as
        # +name+ (default: the layout's name), with the band's position.
        # Returns the path.
        def save(name = @layout.name)
          raise ArgumentError, "Layout names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          dir = UI.layouts_dir
          FileUtils.mkdir_p(dir)
          path = File.join(dir, "#{name}.rb")
          text = @layout.to_ruby(at: @position).sub(/\Alayout #{Regexp.escape(@layout.name.inspect)}/, "layout #{name.inspect}")
          File.write(path, "# mb-sound terminal UI layout: `ui #{name.inspect}` shows it (see help :ui)\n#{text}")
          path
        end

        def inspect
          "#<UI::Band #{@layout.name.inspect} #{@height} rows at the #{@position} of #{@rows}x#{@cols}, #{@placed.length} panes, #{@mode}#{@active ? '' : ' (off)'}>"
        end

        # Called from the SIGWINCH trap: checks the size on the next frame.
        def resized!
          @resized = true
          @thread&.wakeup rescue nil
        end

        private

        # The bytes Cells#frame gives when no cell changed, per color mode.
        EMPTY_FRAMES = Plot::Text::Cells::MODES.keys.to_h { |m| [m, m == :none ? '' : "\e[0m"] }.freeze

        def thread_cpu
          Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
        end

        # Keeps the SLOWEST refreshes (time, CPU seconds, slow parts).
        def note_slow(now, cpu, parts)
          return if @slowest.length >= SLOWEST && cpu <= @slowest[-1][1]
          @slowest << [now - (@first_refresh ||= now), cpu, parts]
          @slowest.sort_by! { |e| -e[1] }
          @slowest.pop if @slowest.length > SLOWEST
        end

        def paint_loop
          paced_loop(-> { @stopping })
        end

        def write(str)
          timed_write do
            @io.write(str)
            @io.flush if @io.respond_to?(:flush)
          end
        rescue IOError, SystemCallError => e
          warn "UI band: can't write to the terminal (#{e.class}: #{e.message}); stopping" unless @stopping
          @stopping = true
        end

        def pane_failed(p, e)
          msg = "#{p.pane.name}: #{e.class}: #{e.message}"
          warn "UI pane #{msg}" unless @failures.key?(p.pane.name)
          @failures[p.pane.name] = msg
          return if p.pane.bytes?

          r = p.state[:inner]
          c = Canvas.new(@grid, r.x, r.y, r.w, r.h, glyphs: @glyphs).clear
          c.puts ["#{p.pane.name} failed: ", :bad], [e.message, :dim]
        end

        # The terminal's [rows, cols].
        def terminal_size
          return @fixed_size if @fixed_size
          size = @io.respond_to?(:winsize) && @io.tty? ? @io.winsize : nil
          size && size[0] > 0 && size[1] > 0 ? size : [24, 80]
        rescue SystemCallError, IOError
          [24, 80]
        end

        def relayout(rows, cols)
          @rows = rows
          @cols = cols
          @density = Density.decide(:band, rows, cols)
          @shown_layout = @layout.at_level(@density.level)
          natural = @shown_layout.height(@panes)
          groups = @shown_layout.root.children.length
          # Boxes (a big terminal) only for bands with panes taller than a row
          @boxed = @density.boxes && natural > groups
          if @boxed
            inner = natural + groups - 1
            inner = [inner, @density.max_band_rows - 2].max if @density.max_band_rows
            @height = inner + 2
            @placed = @shown_layout.place(cols - 2, @panes, height: inner, row_gap: 1, x: 1, y: 1)
            @rule_row = nil
          else
            @height = natural + (@density.rule ? 1 : 0)
            body_y = @density.rule && !top? ? 1 : 0
            @placed = @shown_layout.place(cols, @panes, y: body_y)
            @rule_row = @density.rule ? (top? ? @height - 1 : 0) : nil
          end
          klass = @native ? Plot::Text::NativeCells : Plot::Text::Cells
          @grid = klass.new(cols, @height)
          @shown = klass.new(cols, @height)
          @chrome = chrome_plan
          @placed.each do |p|
            p.state[:inner] = @chrome.frames[p.pane.name]&.inner || Viewports::Rect.new(p.x, p.y, p.w, p.h)
            p.state[:title_in_rule] = true # (the chrome draws titles)
          end
          paint_chrome
          @feed.needs = @placed.flat_map { |p| p.pane.needs }
          @full = true
        end

        # The chrome of the placed panes (UI::Chrome): titles on their own
        # rows, and with boxes, the frame and rules with titles set in.
        def chrome_plan
          items = @placed.map { |p| Chrome::Item.new(name: p.pane.name, rect: Viewports::Rect.new(p.x, p.y, p.w, p.h), title: p.pane.title) }
          Chrome.plan(items, w: @cols, h: @height, rules: @boxed, inside: true)
        end

        def paint_chrome
          Chrome.paint(@grid, @chrome, glyphs: @glyphs, focus_edges: false)
          Chrome.hrule(@grid, @rule_row, @cols, glyphs: @glyphs) if @rule_row
        end

        def check_size(now)
          return unless @resized || @size_checked_at.nil? || now - @size_checked_at >= SIZE_CHECK
          @size_checked_at = now
          @resized = false
          rows, cols = terminal_size
          return if rows == @rows && cols == @cols

          relayout(rows, cols)
          @reasserted_at = nil
        end

        # Scrolls the screen up to make room for the band, then sets the
        # scroll region and puts the cursor back on its line.
        def setup_terminal(scroll: @height)
          row = cursor_row
          a, b = region
          out = +"\e[#{@rows};1H#{"\n" * scroll}\e[#{a};#{b}r"
          # The cursor's line moved up with the screen
          target = ((row || @rows) - scroll).clamp(a, b)
          out << "\e[#{target};1H"
          write(out)
          @full = true
          @reasserted_at = @clock.call
        end

        # The cursor's row (1-based) from the terminal, or nil.
        def cursor_row
          return nil unless @io.respond_to?(:tty?) && @io.tty? && $stdin.tty?
          IO.console&.cursor&.first&.+(1)
        rescue StandardError
          nil
        end

        def install_winch
          return unless @io.respond_to?(:tty?) && @io.tty?
          band = self
          old = nil
          old = Signal.trap('WINCH') do |sig|
            band.resized!
            old.call(sig) if old.respond_to?(:call)
          end
          @old_winch = old
          @winch_installed = true
        rescue ArgumentError
          nil
        end

        def restore_winch
          return unless @winch_installed
          Signal.trap('WINCH', @old_winch || 'DEFAULT')
          @winch_installed = false
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
