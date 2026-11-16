module MB
  module Sound
    module Plot
      # A text plot pane redrawn many times a second (a scope, a spectrum,
      # a meter): each #redraw draws a new chart, reusing the layout (axes,
      # tick labels, legend, title, grid lines) while it stays the same, so
      # a frame costs only the marks.  The text is exactly what
      # Plot::Text.render gives for the same chart.
      #
      #     pane = MB::Sound::Plot::Live.new(width: 60, height: 16, look: :scope)
      #     loop do
      #       print "\e[H", pane.redraw(MB::Sound::Plot.waveform(buffer, range: -1.0..1.0))
      #     end
      #
      # Fixed scale domains (+range:+ in the presets) keep the layout;
      # scales fit to each frame's data change it whenever the fit does.
      class Live
        attr_reader :width, :height

        # +look+, +color+, and +theme+ are as for Plot::Text.render (nil for
        # the terminal's defaults); +cells+ the cells' class (NativeCells
        # or Cells: the class of the grid #draw paints into; by default the
        # :cell_grid kernel's, see MB::Sound::Kernels).
        def initialize(width:, height:, look: nil, color: nil, theme: nil, cells: Kernels.cell_grid)
          @width = width
          @height = height
          @frame = Text::Frame.new(width: width, height: height, look: look, color: color, theme: theme, cells: cells)
          @shown = nil
          @drawn = nil # (the chart #draw drew last, while the frame's cells are its)
          @trace = nil
        end

        # A live scope's lines drawn again from new samples without a chart
        # (ui-perf-2: the scope's chart path allocated about 220 objects a
        # frame).  Made by Live#trace from a chart this Live drew: one panel
        # of plain lines over the index (no steps, dashes, or polar
        # coordinates), each longer than two points a column, so every frame
        # is a regular min/max decimation of fixed length.  Keeps the device
        # x of each index, the y projection, the colors, and buffers for the
        # decimated points (#points, the :plot_trace kernel).
        class Trace
          attr_reader :ox, :oy, :rgbs, :compose_colors, :compose_prio, :compose_count

          # +lines+ the chart's Mark::Lines, +surface+ its panel's surface,
          # +coord+ its coordinates, +rgbs+ the lines' colors.
          def initialize(lines, surface, coord, rgbs)
            n = lines[0].y.length
            @n = n
            @count = lines.length
            @columns = surface.width
            @ends = Mark.vector?(surface)
            @dx = Mark::Base.instance_method(:device_c).bind_call(lines[0], surface, coord, lines[0].x, Numo::DFloat[0.0])[0]
            @py = coord.y.projection
            @mul = surface.height - 1
            g = @ends ? (n / @columns.to_f).ceil : (n / @columns.to_f).floor
            g = 1 if g < 1
            len = (n / g.to_f).ceil * 2
            @ox = Array.new(@count) { Numo::DFloat.zeros(len) }
            @oy = Array.new(@count) { Numo::DFloat.zeros(len) }
            @rgbs = rgbs
            @compose_colors = @compose_prio = @compose_count = nil
          end

          # True for +lines+ (Arrays of samples) this trace can draw.
          def fits?(lines)
            return false unless lines.length == @count
            i = 0
            while i < @count
              return false unless lines[i].length == @n
              i += 1
            end
            true
          end

          # (Panel#compose's packed colors and priorities for this trace.)
          def keep_compose(count, colors, prio)
            @compose_count = count
            @compose_colors = colors
            @compose_prio = prio
          end

          # Fills ox[k] and oy[k] with line +k+'s device points from samples
          # +ys+ (a DFloat or SFloat): what Mark::Line#draw gives the surface.
          # The :plot_trace kernel: #points_c (FastUI.trace) or #points_ruby.
          def points_c(ys, k)
            return if FastUI.trace(@ox[k], @oy[k], @dx, ys, @py[0], @py[1], @py[2], @py[3], @mul, true, @columns, @ends)

            points_ruby(ys, k)
          end

          # The Ruby mirror of FastUI.trace: FastUI.project's map, then the
          # regular decimation's mirror.
          def points_ruby(ys, k)
            kind, lo, span, reverse = @py
            v = Numo::DFloat.cast(ys)
            if kind == 1
              v = v.dup
              v[v <= 0] = Float::NAN
              u = (Numo::NMath.log10(v) - lo) / span
            else
              u = (v - lo) / span
            end
            u = 1 - u if reverse
            dy = (1 - u) * @mul
            ox, oy = Geometry.decimate_ruby(@dx, dy, @columns, regular: true, ends: @ends)
            @ox[k].store(ox)
            @oy[k].store(oy)
            nil
          end
        end

        # Keeps a Trace of +chart+ (the chart the last #draw drew) for
        # #retrace when it can be traced (see Trace); returns it or nil.
        def trace(chart)
          @trace = nil
          parts = @frame.single_panel or return nil
          panel, layout, coord = parts
          return nil if coord.polar? || !chart.respond_to?(:marks) || chart.marks.empty?
          lines = chart.marks
          surface = layout.surface
          return nil unless lines.all? { |m| m.instance_of?(Mark::Line) && !m.step && m.dash.nil? && m.regular? && m.y.length == lines[0].y.length }
          return nil unless lines[0].y.length > surface.width * 2 && coord.x.linear? && coord.x.projection && coord.y.projection
          # (filling looks draw an Area whose x is an Array, decimated as
          # irregular points: left to the chart)
          return nil if look.fill
          @trace = Trace.new(lines, surface, coord, chart.colors(theme))
        end

        # Draws the kept Trace's lines from new samples +lines+ (Arrays of
        # DFloat or SFloat, as long as the traced ones) into +grid+ at
        # (+x+, +y+) like #draw of the traced chart with these samples, the
        # same cells, without building a chart.  Returns false (nothing
        # drawn) when there is no trace or the samples don't fit it.
        def retrace(lines, grid, x:, y:)
          t = @trace
          return false unless t&.fits?(lines)
          @frame.retrace(t, lines)
          @drawn = nil
          grid.blit(@frame.cells, x, y)
          true
        end

        # Draws +chart+ (a Chart or Figure) and returns its text: the lines
        # joined by newlines, with ANSI colors unless the color mode is
        # :none.
        def redraw(chart)
          @drawn = nil
          @frame.text(chart)
        end

        # Draws +chart+ and returns its lines (see #redraw).
        def lines(chart)
          @drawn = nil
          @frame.render(chart)
        end

        # Draws +chart+ into +grid+ (a screen's NativeCells or Cells, of the
        # class given to the constructor) with its top left corner at
        # 0-based cell (+x+, +y+), clipped to the grid.  Screens composite
        # their plot panes this way, so whatever they draw over the panes
        # afterwards (key overlays, badges) stays on top and only the
        # screen's own changed-cell frame reaches the terminal (ui-fix-3).
        # Returns +grid+.
        #
        #     live.draw(MB::Sound::Plot.waveform(buffer, range: -1.0..1.0), screen_grid, x: 10, y: 2)
        #
        # The same chart object as the last #draw (charts are immutable: a
        # pane keeping its chart while nothing changed) is blitted again
        # without drawing it (ui-wave-perf-1: the RENDER pane redrew its
        # unchanged chart 10 times a second).
        def draw(chart, grid, x:, y:)
          unless chart.equal?(@drawn)
            @frame.update(chart)
            @drawn = chart
          end
          grid.blit(@frame.cells, x, y)
        end

        # Draws +chart+ and returns the terminal bytes that put it on the
        # screen at 1-based (+row+, +col+): only the cells that changed
        # since the last #frame or #write (every cell the first time, after
        # #invalidate, or with +full+), placed with cursor moves, inside
        # DEC 2026 synchronized output with +sync+.
        #
        #     print pane.frame(MB::Sound::Plot.waveform(buffer, range: -1.0..1.0), row: 2)
        def frame(chart, row: 1, col: 1, full: false, sync: true)
          @drawn = nil
          @frame.update(chart)
          prev = shown(full)
          out = @frame.cells.frame(prev, color, row: row, col: col, sync: sync)
          remember
          out
        end

        # Like #frame, but writes the bytes to +io+ (with the C cells,
        # encoding and writing without holding the GVL, so the audio
        # thread can run); returns the number of bytes written.
        def write(io, chart, row: 1, col: 1, full: false, sync: true)
          @drawn = nil
          @frame.update(chart)
          prev = shown(full)
          cells = @frame.cells
          n =
            if cells.is_a?(Text::NativeCells)
              cells.write_frame(io, prev, color, row: row, col: col, sync: sync)
            else
              io.write(cells.frame(prev, color, row: row, col: col, sync: sync))
            end
          remember
          n
        end

        # Makes the next #frame or #write draw every cell (after the screen
        # was cleared or scrolled).
        def invalidate
          @shown = nil
        end

        # How many layouts were built so far (one per change of scales,
        # titles, or legend).
        def layouts
          @frame.layouts
        end

        # The look, color mode, and theme in use.
        def look = @frame.look
        def color = @frame.color
        def theme = @frame.theme

        private

        # What the screen shows (nil to draw everything)
        def shown(full)
          return nil if full || @shown.nil? || @shown.class != @frame.cells.class

          @shown
        end

        # Copies the frame just drawn as what the screen shows
        def remember
          cells = @frame.cells
          @shown = cells.class.new(@width, @height) if @shown.nil? || @shown.class != cells.class
          @shown.copy_from(cells)
        end

        public

        def inspect
          "#<#{self.class.name} #{@width}x#{@height} #{look.name} #{color} #{layouts} layout#{'s' unless layouts == 1}>"
        end
      end

      Kernels.register :plot_trace, on: Live::Trace, as: :points, c: :points_c, ruby: :points_ruby, state: %i[@ox @oy], covers: %w[FastUI.trace]

      # A Plot::Live pane (see there).
      def self.live(width:, height:, **opts)
        Live.new(width: width, height: height, **opts)
      end
    end
  end
end
