module MB
  module Sound
    module Plot
      # Terminal text rendering: marks are drawn into a Raster of sub-cell
      # dots, then a canvas turns each cell's dots into one character with
      # colors; axes, labels, legends, and colorbars are text around the
      # plot area.  Output is deterministic (no terminal queries, no
      # external process), so specs can compare it exactly.
      module Text
        # A text look: the +canvas+ (dots per cell and how they become
        # characters), the +frame+ (:box axes with tick marks, :ticks
        # labels only, :ascii, :none for sparklines), +grid+ (dotted grid
        # lines), +fill+ (lines filled down to zero), and +color+ (nil for
        # the default mode, or a fixed mode such as :none).
        Look = Data.define(:name, :canvas, :frame, :grid, :fill, :color) do
          def initialize(name:, canvas:, frame: :box, grid: false, fill: false, color: nil)
            super
          end
        end

        # The built-in looks:
        # - :scope - Braille lines (2x4 dots per cell), box axes, dotted grid
        # - :blocks - half blocks (1x2 colored pixels per cell), filled areas
        # - :mosaic - sextants (2x3, two colors per cell), labels only
        # - :quad - quadrants (2x2, two colors per cell), box axes
        # - :spark - eighth blocks (1x8 per cell), filled, no axes
        # - :ascii - plain ASCII (1x3 per cell), no color
        LOOKS = {
          scope: Look.new(name: :scope, canvas: :braille, frame: :box, grid: true),
          blocks: Look.new(name: :blocks, canvas: :half, frame: :box, fill: true),
          mosaic: Look.new(name: :mosaic, canvas: :sextant, frame: :ticks),
          quad: Look.new(name: :quad, canvas: :quadrant, frame: :box),
          spark: Look.new(name: :spark, canvas: :eighths, frame: :none, fill: true),
          ascii: Look.new(name: :ascii, canvas: :ascii, frame: :ascii, color: :none),
        }.freeze

        # [dot columns, dot rows] per character cell for each canvas.
        CANVASES = {
          braille: [2, 4], half: [1, 2], quadrant: [2, 2], sextant: [2, 3], eighths: [1, 8], ascii: [1, 3],
        }.freeze

        # Renders +figure+ (a Figure or Chart) as +height+ lines of +width+
        # columns (Array of Strings with ANSI colors unless +color+ is
        # :none).
        def self.render(figure, width:, height:, look: nil, color: nil, theme: nil)
          Frame.new(width: width, height: height, look: look, color: color, theme: theme).render(figure)
        end

        # The look, color mode, and theme for options as Text.render takes
        # them: [Look, color mode Symbol, Theme].
        def self.options(look, color, theme)
          look = look.is_a?(Look) ? look : LOOKS.fetch((look || Terminal.look).to_sym) { raise ArgumentError, "Unknown look #{look.inspect} (#{LOOKS.keys.join(', ')})" }
          color = (color || look.color || Terminal.color_mode).to_sym
          color = :ansi256 if color == :'256'
          [look, color, Theme[theme || Terminal.theme]]
        end

        # Draws figures into cells in two steps: the layout (titles, axes,
        # labels, legends, colorbars, grid lines; everything but the marks)
        # and the marks.  Plot::Live keeps a Frame and redraws only the marks
        # while the layout stays the same; Text.render uses a new one.
        class Frame
          attr_reader :width, :height, :look, :color, :theme

          # The number of layouts built (Live redraws reuse them).
          attr_reader :layouts

          def initialize(width:, height:, look: nil, color: nil, theme: nil)
            @width = width
            @height = height
            @look, @color, @theme = Text.options(look, color, theme)
            @layouts = 0
            @key = nil
          end

          # Renders +figure+ (a Figure or Chart) as an Array of lines.
          def render(figure)
            draw(figure)
            @cells.lines(@color)
          end

          # Renders +figure+ as one String (lines joined by newlines).
          def text(figure)
            draw(figure)
            @cells.to_text(@color)
          end

          private

          def new_cells
            Plot.native ? NativeCells.new(@width, @height) : Cells.new(@width, @height)
          end

          # Lays out (or reuses the layout) and paints the marks into @cells
          def draw(figure)
            figure = figure.figure
            coords = figure.charts.map(&:coord)
            key = [figure.title, figure.rows, figure.columns, figure.charts.zip(coords).map { |ch, co| Panel.layout_key(ch, co, @theme) }]

            if @base && key == @key
              @cells.copy_from(@base)
              @panels.zip(figure.charts, coords).each do |(panel, layout), chart, coord|
                panel.paint(layout, chart, coord, restore: true) if layout
              end
              return
            end

            # A new layout: static parts into @base, then marks into @cells
            @layouts += 1
            @key = key
            @base = new_cells
            @cells = new_cells
            top = 0
            if figure.title && @height > 3
              @base.text((@width - figure.title.length) / 2, 0, figure.title, fg: @theme.ink, bold: true)
              top = 1
            end

            rows = figure.rows
            cols = figure.columns
            gutter = cols > 1 ? 2 : 0
            avail_w = @width - gutter * (cols - 1)
            avail_h = @height - top
            @panels = figure.charts.each_with_index.map { |chart, i|
              r, c = i.divmod(cols)
              x0 = c * avail_w / cols + c * gutter
              x1 = (c + 1) * avail_w / cols + c * gutter
              y0 = top + r * avail_h / rows
              y1 = top + (r + 1) * avail_h / rows
              panel = Panel.new(chart, @base, x0, y0, x1 - x0, y1 - y0, @look, @theme, @color)
              [panel, panel.layout(coords[i])]
            }

            @cells.copy_from(@base)
            @panels.zip(figure.charts, coords).each do |(panel, layout), chart, coord|
              panel.cells = @cells
              panel.paint(layout, chart, coord, restore: false) if layout
            end
          end
        end

        # A grid of character cells with colors (packed as 0xRRGGBB
        # Integers, nil for none) and attributes: the Ruby mirror of
        # NativeCells (MB::Sound::FastUI::Grid), which gives the same text.
        class Cells
          BOLD = 1
          REVERSE = 2

          # Color modes by number, for FastUI::Grid#lines and #text.
          MODES = { none: 0, truecolor: 1, ansi256: 2, ansi16: 3 }.freeze

          # 0xRRGGBB for [r, g, b] (nil for nil).
          def self.pack(rgb)
            rgb && ((rgb[0] << 16) | (rgb[1] << 8) | rgb[2])
          end

          # [r, g, b] for 0xRRGGBB.
          def self.unpack(c)
            [(c >> 16) & 255, (c >> 8) & 255, c & 255]
          end

          attr_reader :width, :height

          def initialize(width, height)
            @width = width
            @height = height
            n = width * height
            @ch = Array.new(n, ' ')
            @fg = Array.new(n)
            @bg = Array.new(n)
            @attr = Array.new(n, 0)
          end

          # Sets one cell.
          def set(x, y, ch, fg: nil, bg: nil, bold: false, reverse: false)
            return if x < 0 || y < 0 || x >= @width || y >= @height

            i = y * @width + x
            @ch[i] = ch
            @fg[i] = Cells.pack(fg)
            @bg[i] = Cells.pack(bg)
            @attr[i] = (bold ? BOLD : 0) | (reverse ? REVERSE : 0)
          end

          # Sets the cell at index +i+ (no bounds checks; for canvases).
          def put(i, ch, fg, bg, attr)
            @ch[i] = ch
            @fg[i] = Cells.pack(fg)
            @bg[i] = Cells.pack(bg)
            @attr[i] = attr
          end

          # Writes +str+ from (+x+, +y+), clipped to the grid (and to +max+
          # columns).
          def text(x, y, str, fg: nil, bold: false, max: nil)
            str = str.to_s
            str = str[0, max] if max
            str.each_char.with_index do |c, k|
              set(x + k, y, c, fg: fg, bold: bold)
            end
          end

          # The character at (+x+, +y+).
          def char(x, y)
            @ch[y * @width + x]
          end

          # Copies every cell from +other+ (the same size).
          def copy_from(other)
            raise ArgumentError, 'Cells sizes differ' unless other.width == @width && other.height == @height

            @ch.replace(other.instance_variable_get(:@ch))
            @fg.replace(other.instance_variable_get(:@fg))
            @bg.replace(other.instance_variable_get(:@bg))
            @attr.replace(other.instance_variable_get(:@attr))
            self
          end

          # The lines, with SGR codes for +mode+ (:truecolor, :ansi256,
          # :ansi16, :none).
          def lines(mode)
            Array.new(@height) { |y| line(y, mode) }
          end

          # The lines joined by newlines.
          def to_text(mode)
            lines(mode).join("\n")
          end

          private

          def line(y, mode)
            start = y * @width
            return @ch[start, @width].join if mode == :none

            @sgr ||= {}
            out = +''
            styled = false
            pf = pb = nil
            pa = 0
            fga = @fg
            bga = @bg
            aa = @attr
            cha = @ch
            i = start
            stop = start + @width
            while i < stop
              f = fga[i]
              b = bga[i]
              a = aa[i]
              unless f == pf && b == pb && a == pa
                out << "\e[0m" if styled
                styled = !(f.nil? && b.nil? && a == 0)
                out << (@sgr[[f, b, a, mode]] ||= sgr([f, b, a], mode)) if styled
                pf = f
                pb = b
                pa = a
              end
              out << cha[i]
              i += 1
            end
            out << "\e[0m" if styled
            out
          end

          def sgr(style, mode)
            fg, bg, attr = style
            codes = []
            codes << '1' if attr & BOLD != 0
            codes << '7' if attr & REVERSE != 0
            codes << ANSI.color(Cells.unpack(fg), mode, false) if fg
            codes << ANSI.color(Cells.unpack(bg), mode, true) if bg
            "\e[#{codes.join(';')}m"
          end
        end

        # Cells in C (MB::Sound::FastUI::Grid) with Cells' interface; the
        # plot area's dots become characters in Grid#compose.
        class NativeCells < FastUI::Grid
          # Sets one cell.
          def set(x, y, ch, fg: nil, bg: nil, bold: false, reverse: false)
            set_cell(x, y, ch, Cells.pack(fg), Cells.pack(bg), (bold ? Cells::BOLD : 0) | (reverse ? Cells::REVERSE : 0))
          end

          # Sets the cell at index +i+.
          def put(i, ch, fg, bg, attr)
            y, x = i.divmod(width)
            set_cell(x, y, ch, Cells.pack(fg), Cells.pack(bg), attr)
          end

          # Writes +str+ from (+x+, +y+), clipped to the grid (and to +max+
          # columns).
          def text(x, y, str, fg: nil, bold: false, max: nil)
            put_text(x, y, str, Cells.pack(fg), bold ? Cells::BOLD : 0, max)
          end

          # The lines, with SGR codes for +mode+ (see Cells#lines).
          def lines(mode)
            super(Cells::MODES.fetch(mode, 3))
          end

          # The lines joined by newlines.
          def to_text(mode)
            super(Cells::MODES.fetch(mode, 3))
          end
        end

        # SGR color codes in each color mode.
        module ANSI
          BASIC = [
            [0, 0, 0], [205, 49, 49], [13, 188, 121], [229, 229, 16], [36, 114, 200], [188, 63, 188], [17, 168, 205], [229, 229, 229],
            [102, 102, 102], [241, 76, 76], [35, 209, 139], [245, 245, 67], [59, 142, 234], [214, 112, 214], [41, 184, 219], [255, 255, 255],
          ].freeze

          module_function

          # The SGR parameter for +rgb+ as a foreground (or background with
          # +bg+) color in +mode+.
          def color(rgb, mode, bg)
            case mode
            when :truecolor
              "#{bg ? 48 : 38};2;#{rgb[0]};#{rgb[1]};#{rgb[2]}"
            when :ansi256
              "#{bg ? 48 : 38};5;#{index256(rgb)}"
            else
              k = nearest(rgb, BASIC)
              base = k < 8 ? (bg ? 40 : 30) + k : (bg ? 100 : 90) + k - 8
              base.to_s
            end
          end

          # The nearest xterm 256-color index.
          def index256(rgb)
            @cache ||= {}
            @cache[rgb] ||= begin
              levels = [0, 95, 135, 175, 215, 255]
              cube = rgb.map { |v| levels.each_with_index.min_by { |l, _| (l - v).abs }[1] }
              cube_rgb = cube.map { |k| levels[k] }
              gray = ((rgb.sum / 3.0 - 8) / 10).round.clamp(0, 23)
              gray_rgb = [8 + gray * 10] * 3
              if dist(rgb, gray_rgb) < dist(rgb, cube_rgb)
                232 + gray
              else
                16 + 36 * cube[0] + 6 * cube[1] + cube[2]
              end
            end
          end

          def nearest(rgb, table)
            table.each_with_index.min_by { |c, _| dist(rgb, c) }[1]
          end

          def dist(a, b)
            (a[0] - b[0])**2 * 2 + (a[1] - b[1])**2 * 4 + (a[2] - b[2])**2 * 3
          end
        end

        # The drawing surface for marks (see Mark): a Raster of line dots,
        # plus a half-block image layer for heatmaps.
        class Surface
          attr_reader :raster, :image_ids, :image_colors

          def initialize(cols, rows, look, theme)
            @cw, @ch = CANVASES.fetch(look.canvas)
            @cols = cols
            @rows = rows
            @look = look
            @theme = theme
            @raster = Raster.new(cols * @cw, rows * @ch)
            @prio = [0]
            @image_ids = nil
          end

          def width
            @raster.width
          end

          def height
            @raster.height
          end

          # A color index with drawing priority +prio+ (lines over fills
          # over grid when a cell can show only one color).
          def color(rgb, prio)
            c = @raster.color(rgb)
            @prio[c] = [@prio[c] || 0, prio].max
            c
          end

          # Priorities by color index (Numo::Int32).
          def priorities
            Numo::Int32.cast(@prio.map { |v| v || 0 })
          end

          def polyline(xs, ys, rgb, dash: nil, prio: 3)
            @raster.polyline(xs, ys, color(rgb, prio), dash: dash)
          end

          # A series line: filled down to +base+ in filling looks.
          def line(xs, ys, rgb, dash: nil, base: nil)
            if @look.fill && dash.nil? && base
              area(xs, ys, base, rgb)
            else
              polyline(xs, ys, rgb, dash: dash)
            end
          end

          def points(xs, ys, rgb)
            @raster.points(xs, ys, color(rgb, 3))
          end

          def area(xs, ys, base, rgb)
            if Plot.native
              fc = color(fill_color(rgb, 0.45), 2)
              lc = color(rgb, 3)
              return if FastUI.area(@raster.dots, xs, ys, base, fc, lc)
            end
            area_ruby(xs, ys, base, rgb)
          end

          # The Ruby mirror of FastUI.area (see #area).
          def area_ruby(xs, ys, base, rgb)
            mask = @raster.line_mask(xs, ys)
            @raster.fill_between(mask, color(fill_color(rgb, 0.45), 2), base: base)
            @raster.dots[mask.eq(1)] = color(rgb, 3)
          end

          def band(xs, lo, hi, rgb)
            a = @raster.line_mask(xs, lo)
            b = @raster.line_mask(xs, hi)
            @raster.fill_between(a, color(fill_color(rgb, 0.7), 2), mask_b: b)
            c = color(rgb, 3)
            @raster.dots[a.eq(1)] = c
            @raster.dots[b.eq(1)] = c
          end

          # Dotted grid lines at device rows +ys+ and columns +xs+.
          def grid(xs, ys, rgb)
            c = color(rgb, 1)
            step = @cw == 2 ? 2 : 1
            ys.each do |y|
              xs_line = Numo::Int32.new((width + step - 1) / step).seq * step
              @raster.set(xs_line, Numo::Int32.new(xs_line.length).fill(y.round), c)
            end
            xs.each do |x|
              ys_line = Numo::Int32.new((height + 1) / 2).seq * 2
              @raster.set(Numo::Int32.new(ys_line.length).fill(x.round), ys_line, c)
            end
          end

          def image_grid
            [@cols, @rows * 2]
          end

          # The surface's drawing so far (dots, colors, priorities), for
          # #restore.
          def snapshot
            [@raster.snapshot, @prio.dup]
          end

          # Returns the surface to a #snapshot, clearing any image.
          def restore(snap)
            @raster.restore(snap[0])
            @prio.replace(snap[1])
            @image_ids = nil
            @image_colors = nil
          end

          def image(ids, colormap)
            @image_ids = ids
            @image_colors = colormap.colors
          end

          private

          # A dimmer step of +rgb+ toward the background for fills
          def fill_color(rgb, amount)
            target = @theme.name == :light ? [255, 255, 255] : [0, 0, 0]
            Color.mix(rgb, target, 1 - amount)
          end
        end

        # Lays out and draws one chart in a rectangle of cells.
        class Panel
          SHADES = [' ', '░', '▒', '▓', '█'].freeze

          def initialize(chart, cells, x, y, w, h, look, theme, mode = :truecolor)
            @mode = mode
            @chart = chart
            @cells = cells
            @x = x
            @y = y
            @w = w
            @h = h
            @look = look
            @theme = theme
            @cw, @ch = CANVASES.fetch(look.canvas)
          end

          # The cells drawn into (Frame points the marks at its own).
          attr_writer :cells

          # What decides a panel's layout for +chart+ with +coord+ (its
          # scales fit to the data): equal keys draw the same axes, labels,
          # legend, and grid.
          def self.layout_key(chart, coord, theme)
            heat = chart.heatmap
            [
              chart.title, chart.polar, chart.grid, chart.legend_entries(theme),
              Panel.scale_key(coord.x), Panel.scale_key(coord.y),
              heat && [Panel.scale_key(heat.z_scale), heat.colormap_for(theme).colors],
            ]
          end

          # A scale's class and settings (scales are immutable values).
          def self.scale_key(scale)
            [scale.class, *scale.instance_variables.map { |v| scale.instance_variable_get(v) }]
          end

          # Draws the chart: #layout, then #paint.
          def draw
            coord = @chart.coord
            layout = layout(coord)
            paint(layout, @chart, coord, restore: false) if layout
          end

          # Draws everything but the marks (title, legend, axes, labels,
          # colorbar) into the cells, and the grid lines into a new Surface;
          # returns the Layout for #paint, or nil if the panel is too small
          # for a plot.
          def layout(coord)
            return nil if @w < 4 || @h < 1

            entries = @chart.legend_entries(@theme)
            frame = @chart.polar ? :none : @look.frame
            heat = @chart.heatmap

            row = @y
            header = @chart.title || !entries.empty? || (frame != :none && @chart.y.title)
            header = false if @h < 4

            # The legend goes on the title row when it fits, else on rows of
            # its own under the title (as many as leave a usable plot)
            legend = entries.map { |label, rgb, kind| [glyph(kind), label, rgb] }
            title_w = @chart.title ? @chart.title.length + 2 : 0
            if !header || legend.empty? || title_w + legend_width(legend) <= @w
              legend_rows = nil
            else
              max_rows = [@h - 1 - (frame == :none ? 0 : 3) - 3, 0].max
              legend_rows = wrap_legend(legend, max_rows)
            end
            row += 1 if header
            row += legend_rows.length if legend_rows

            notes = frame != :none && !coord.x.secondary_ticks.empty?
            bottom = frame == :none ? 0 : (frame == :ticks ? 1 : 2)
            bottom += 1 if notes
            bottom = 0 if @h - (row - @y) - bottom < 2
            notes = false if bottom == 0
            plot_h = @h - (row - @y) - bottom

            yticks = @chart.polar ? [] : frame == :none ? spark_ticks(coord.y) : coord.y.ticks(tick_count(plot_h, 2.5, min: 3))
            ylabels = yticks.map(&:label).compact
            label_w = ylabels.map(&:length).max || 0
            left = frame == :none ? (label_w > 0 ? label_w + 1 : 0) : label_w + 1
            left = 0 if @w - left < 8

            cbar_w = 0
            if heat
              zt = heat.z_scale.ticks(tick_count(plot_h, 4))
              zw = zt.map { |t| t.label.to_s.length }.max || 0
              cbar_w = 4 + zw
              cbar_w = 0 if @w - left - cbar_w < 8
            end

            plot_x = @x + left
            plot_w = @w - left - cbar_w
            if @chart.polar
              side = [plot_w, plot_h * 2].min
              plot_x += (plot_w - side) / 2
              plot_w = side
            end
            return nil if plot_w < 2 || plot_h < 1

            surface = Surface.new(plot_w, plot_h, @look, @theme)

            xticks = coord.x.ticks(tick_count(plot_w, 10))
            if @chart.polar
              draw_polar_grid(surface, coord)
            elsif @look.grid && @chart.grid && frame != :none && !heat
              gx = xticks.select(&:major).map { |t| coord.x.map(t.value) * (surface.width - 1) }.select { |v| v > 0.5 && v < surface.width - 1.5 }
              gy = yticks.select(&:major).map { |t| (1 - coord.y.map(t.value)) * (surface.height - 1) }.select { |v| v > 0.5 && v < surface.height - 1.5 }
              surface.grid(gx, gy, @theme.grid)
            end

            draw_header(legend, legend_rows, coord, frame) if header
            draw_y_axis(yticks, coord, plot_x, row, plot_h, frame, label_w) if left > 0
            draw_x_axis(xticks, coord, plot_x, row + plot_h, plot_w, frame, notes) if bottom > 0
            draw_colorbar(heat, plot_x + plot_w + 1, row, plot_h) if heat && cbar_w > 0

            Layout.new(surface, surface.snapshot, plot_x, row, plot_w, plot_h)
          end

          # Where a panel's marks go: a Surface with the grid lines drawn
          # (and a snapshot of it), and the plot area in cells.
          Layout = Struct.new(:surface, :snapshot, :x, :y, :w, :h)

          # Draws +chart+'s marks through +coord+ into the plot area of
          # +layout+ (from #layout for a chart with the same layout key),
          # first restoring the surface to its grid lines with +restore+.
          def paint(layout, chart, coord, restore: true)
            surface = layout.surface
            surface.restore(layout.snapshot) if restore
            colors = chart.colors(@theme)
            chart.marks.zip(colors).each do |m, rgb|
              if m.is_a?(Mark::Heatmap)
                m.draw(surface, coord, @theme)
              elsif m.is_a?(Mark::Line)
                draw_line(m, surface, coord, rgb)
              else
                m.draw(surface, coord, rgb)
              end
            end

            compose(surface, layout.x, layout.y, layout.w, layout.h)
          end

          private

          def tick_count(cells, per, min: 2)
            (cells / per.to_f).round.clamp(min, 10)
          end

          # Lines fill to zero (or the bottom) in filling looks
          def draw_line(mark, surface, coord, rgb)
            if @look.fill && mark.dash.nil?
              lo, hi = [coord.y.lo, coord.y.hi].minmax
              base = lo < 0 && hi > 0 && !coord.y.is_a?(Scale::DB) ? 0.0 : lo
              Mark::Area.new(mark.y, x: mark.x, base: base).draw(surface, coord, rgb)
            else
              mark.draw(surface, coord, rgb)
            end
          end

          def spark_ticks(scale)
            return [] if @w < 12

            labels = Format.labels([scale.hi, scale.lo], Format.nice_step(scale.hi - scale.lo, 4), si: :up)
            [Tick.new(value: scale.hi, label: labels[0]), Tick.new(value: scale.lo, label: labels[1])]
          end

          def draw_polar_grid(surface, coord)
            c = @theme.grid
            t = Numo::DFloat.linspace(0, 2 * Math::PI, 181)
            [0.5, 1.0].each do |r|
              xs = (Numo::NMath.cos(t) * r * 0.5 + 0.5) * (surface.width - 1)
              ys = (0.5 - Numo::NMath.sin(t) * r * 0.5) * (surface.height - 1)
              surface.polyline(xs, ys, c, dash: [1, 2], prio: 1)
            end
            cy = (surface.height - 1) / 2.0
            surface.polyline(Numo::DFloat[0, surface.width - 1], Numo::DFloat[cy, cy], c, dash: [1, 2], prio: 1)
            cx = (surface.width - 1) / 2.0
            surface.polyline(Numo::DFloat[cx, cx], Numo::DFloat[0, surface.height - 1], c, dash: [1, 2], prio: 1)
          end

          # Turns the surface's dots into characters in the plot area
          def compose(surface, px, py, pw, ph)
            if @cells.is_a?(NativeCells) && !surface.image_ids
              colors = Numo::Int32.cast(surface.raster.colors.map { |c| c ? Cells.pack(c) : -1 })
              @cells.compose(surface.raster.dots, Canvas::KINDS.fetch(@look.canvas), @cw, @ch, px, py, pw, ph,
                surface.priorities, colors, Canvas::TABLES.fetch(@look.canvas))
              return
            end

            chars, fg, bg, rev = Canvas.cells(surface.raster, @look.canvas, pw, ph, surface.priorities)
            colors = surface.raster.colors

            img = surface.image_ids
            if img
              icol = surface.image_colors
              top = img[(Numo::Int32.new(ph).seq * 2), true].to_a
              bot = img[(Numo::Int32.new(ph).seq * 2 + 1), true].to_a
            end

            ph.times do |r|
              row0 = (py + r) * @cells.width + px
              cr = chars[r]
              fr = fg[r]
              br = bg[r]
              rr = rev[r]
              pw.times do |c|
                ch = cr[c]
                f = fr[c] > 0 ? colors[fr[c]] : nil
                b = br[c] > 0 ? colors[br[c]] : nil
                if img
                  t = top[r][c]
                  u = bot[r][c]
                  if ch == ' ' && @mode == :none
                    lv = [t, u].select { |v| v >= 0 }
                    unless lv.empty?
                      level = lv.sum / lv.length.to_f / (icol.length - 1)
                      @cells.set(px + c, py + r, SHADES[(level * (SHADES.length - 1)).round])
                    end
                    next
                  elsif ch == ' '
                    if t >= 0 || u >= 0
                      if t >= 0 && u >= 0
                        @cells.set(px + c, py + r, '▀', fg: icol[t], bg: icol[u])
                      elsif t >= 0
                        @cells.set(px + c, py + r, '▀', fg: icol[t])
                      else
                        @cells.set(px + c, py + r, '▄', fg: icol[u])
                      end
                      next
                    end
                  else
                    b ||= icol[t] if t >= 0
                  end
                end
                next if ch == ' ' && b.nil?

                @cells.put(row0 + c, ch, f, b, rr[c] == 1 ? Cells::REVERSE : 0)
              end
            end
          end

          def draw_header(legend, legend_rows, coord, frame)
            x = @x
            title = @chart.title
            if title
              @cells.text(x, @y, title, fg: @theme.ink, bold: true, max: @w)
              x += title.length + 2
            end

            inline = legend_rows.nil? && !legend.empty?
            legend_w = inline ? legend_width(legend) : 0
            ytitle = frame != :none ? coord.y.title : nil
            if ytitle && x + ytitle.length + (inline ? legend_w + 2 : 0) <= @x + @w
              @cells.text(x, @y, ytitle, fg: @theme.muted)
              x += ytitle.length + 2
            end

            if inline
              draw_legend_row(legend, @x + @w - legend_w, @y)
            elsif legend_rows
              legend_rows.each_with_index { |entries, i| draw_legend_row(entries, @x, @y + 1 + i) }
            end
          end

          def draw_legend_row(entries, x, y)
            entries.each do |g, l, rgb|
              @cells.text(x, y, g, fg: rgb)
              @cells.text(x + g.length + 1, y, l, fg: @theme.ink)
              x += g.length + 1 + l.length + 2
            end
          end

          def legend_width(legend)
            legend.sum { |g, l, _| g.length + 1 + l.length + 2 } - 2
          end

          # Legend entries in rows of the panel's width (at most +max_rows+;
          # entries past them are left out)
          def wrap_legend(legend, max_rows)
            rows = []
            current = []
            legend.each do |entry|
              if !current.empty? && legend_width(current + [entry]) > @w
                rows << current
                current = []
              end
              current << entry
            end
            rows << current unless current.empty?
            rows.first(max_rows)
          end

          def glyph(kind)
            ascii = @look.canvas == :ascii
            case kind
            when :area then ascii ? '#' : '█'
            when :band then ascii ? '%' : '▒'
            when :points then ascii ? 'o' : '•'
            else ascii ? '--' : '━━'
            end
          end

          def tick_row(coord, value, row, plot_h)
            v = coord.y.map(value)
            return nil unless v.finite? && v >= -1e-9 && v <= 1 + 1e-9

            dot = ((1 - v) * (plot_h * @ch - 1)).round
            row + dot / @ch
          end

          def draw_y_axis(ticks, coord, plot_x, row, plot_h, frame, label_w)
            axis_x = plot_x - 1
            muted = @theme.muted
            case frame
            when :box
              plot_h.times { |r| @cells.set(axis_x, row + r, '│', fg: muted) }
            when :ascii
              plot_h.times { |r| @cells.set(axis_x, row + r, '|', fg: muted) }
            end

            used = {}
            ticks.each do |t|
              r = tick_row(coord, t.value, row, plot_h)
              next unless r

              case frame
              when :box then @cells.set(axis_x, r, t.major ? '┤' : '│', fg: muted)
              when :ascii then @cells.set(axis_x, r, '+', fg: muted) if t.major
              end
              next if t.label.nil? || used[r]

              used[r] = true
              @cells.text(axis_x - t.label.length, r, t.label, fg: muted)
            end
          end

          def draw_x_axis(ticks, coord, plot_x, row, plot_w, frame, notes)
            muted = @theme.muted
            label_row = row
            if frame == :box || frame == :ascii
              @cells.set(plot_x - 1, row, frame == :box ? '└' : '+', fg: muted)
              plot_w.times { |c| @cells.set(plot_x + c, row, frame == :box ? '─' : '-', fg: muted) }
              label_row = row + 1
            end

            cols = ticks.map { |t|
              u = coord.x.map(t.value)
              next nil unless u.finite? && u >= -1e-9 && u <= 1 + 1e-9

              [t, plot_x + (u * (plot_w * @cw - 1)).round / @cw]
            }.compact

            if frame == :box || frame == :ascii
              cols.each do |t, c|
                @cells.set(c, row, frame == :box ? (t.major ? '┬' : '┴') : (t.major ? '+' : '-'), fg: muted) if t.major || frame == :box
              end
            end

            # The axis title (with its unit) goes at the right end, ahead of
            # the tick labels it would cover
            xtitle = coord.x.title
            limit = @x + @w
            if xtitle && xtitle.length <= @w / 3
              limit = @x + @w - xtitle.length - 1
              @cells.text(limit + 1, label_row, xtitle, fg: muted)
            end
            place_labels(cols, label_row, muted, limit: limit)

            return unless notes

            notes_cols = coord.x.secondary_ticks.map { |t|
              u = coord.x.map(t.value)
              [t, plot_x + (u * (plot_w * @cw - 1)).round / @cw]
            }
            place_labels(notes_cols, label_row + 1, @theme.series(2))
          end

          # Writes labels centered on their columns without overlaps;
          # returns the end column of the last one.
          def place_labels(cols, row, fg, limit: @x + @w)
            last_end = @x - 1
            cols.each do |t, c|
              next unless t.label

              x = c - t.label.length / 2
              x = x.clamp(@x, @x + @w - t.label.length)
              next if x <= last_end + 1 && last_end >= @x
              next if x + t.label.length > limit

              @cells.text(x, row, t.label, fg: fg)
              last_end = x + t.label.length - 1
            end
            last_end
          end

          def draw_colorbar(heat, x, row, plot_h)
            cmap = heat.colormap_for(@theme)
            n = plot_h * 2
            plot_h.times do |r|
              top = cmap.at(1 - (2 * r) / (n - 1).to_f)
              bot = cmap.at(1 - (2 * r + 1) / (n - 1).to_f)
              if @mode == :none
                shade = SHADES[((1 - (2 * r + 0.5) / (n - 1).to_f).clamp(0, 1) * (SHADES.length - 1)).round]
                @cells.set(x, row + r, shade)
                @cells.set(x + 1, row + r, shade)
              else
                @cells.set(x, row + r, '▀', fg: top, bg: bot)
                @cells.set(x + 1, row + r, '▀', fg: top, bg: bot)
              end
            end

            zs = heat.z_scale
            used = {}
            zs.ticks(tick_count(plot_h, 4)).each do |t|
              v = zs.map(t.value)
              next unless v.between?(-1e-9, 1 + 1e-9) && t.label

              r = row + ((1 - v) * (plot_h - 1)).round
              next if used[r]

              used[r] = true
              @cells.text(x + 3, r, t.label, fg: @theme.muted)
            end
          end
        end

        # Conversion of raster dots to characters for each canvas.
        module Canvas
          BRAILLE_WEIGHTS = Numo::Int32[1, 8, 2, 16, 4, 32, 64, 128]
          QUADRANTS = [' ', '▘', '▝', '▀', '▖', '▌', '▞', '▛', '▗', '▚', '▐', '▜', '▄', '▙', '▟', '█'].freeze
          SEXTANTS = Array.new(64) { |c|
            case c
            when 0 then ' '
            when 63 then '█'
            when 21 then '▌'
            when 42 then '▐'
            else (0x1FB00 + c - 1 - (c > 21 ? 1 : 0) - (c > 42 ? 1 : 0)).chr(Encoding::UTF_8)
            end
          }.freeze
          BRAILLE = Array.new(256) { |c| c == 0 ? ' ' : (0x2800 + c).chr(Encoding::UTF_8).freeze }.freeze
          LOWER = [' ', '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'].freeze
          ASCII = [' ', "'", '-', '|', '.', ':', '|', '|'].freeze

          # Canvas numbers and codepoint tables for FastUI::Grid#compose
          KINDS = { braille: 0, half: 1, quadrant: 2, sextant: 3, eighths: 4, ascii: 5 }.freeze
          TABLES = {
            braille: BRAILLE,
            half: [' ', '█', '▀', '▄'],
            quadrant: QUADRANTS,
            sextant: SEXTANTS,
            eighths: LOWER + ['▀', '▔'],
            ascii: ASCII,
          }.transform_values { |t| Numo::Int32.cast(t.map(&:ord)).freeze }.freeze

          module_function

          # [chars, fg, bg, reverse] as Arrays of rows (Ruby Arrays) for a
          # raster of +cols+ x +rows+ cells; fg and bg are color indexes (0
          # = none).
          def cells(raster, canvas, cols, rows, prio)
            cw, ch = CANVASES.fetch(canvas)
            k = cw * ch
            dots = raster.dots.reshape(rows, ch, cols, cw).transpose(0, 2, 1, 3).dup.reshape(rows, cols, k)

            # The highest-priority color in each cell is the foreground
            pr = prio[dots.flatten].reshape(rows, cols, k)
            best = pr.max_index(axis: 2)
            fg = dots.flatten[best.flatten].reshape(rows, cols)
            set = dots.gt(0)
            bg = Numo::UInt16.zeros(rows, cols)
            rev = Numo::UInt8.zeros(rows, cols)

            case canvas
            when :braille
              code = (Numo::Int32.cast(set) * BRAILLE_WEIGHTS.reshape(1, 1, 8)).sum(axis: 2)
              chars = code.to_a.map { |r| r.map { |c| BRAILLE[c] } }

            when :half
              top = dots[true, true, 0]
              bot = dots[true, true, 1]
              chars = Array.new(rows) { Array.new(cols, ' ') }
              fga = Array.new(rows) { Array.new(cols, 0) }
              bga = Array.new(rows) { Array.new(cols, 0) }
              ta = top.to_a
              ba = bot.to_a
              rows.times do |r|
                cr = chars[r]
                tr = ta[r]
                br = ba[r]
                fr = fga[r]
                bgr = bga[r]
                cols.times do |c|
                  t = tr[c]
                  b = br[c]
                  next if t == 0 && b == 0

                  if t == b
                    cr[c] = '█'
                    fr[c] = t
                  elsif b == 0
                    cr[c] = '▀'
                    fr[c] = t
                  elsif t == 0
                    cr[c] = '▄'
                    fr[c] = b
                  else
                    cr[c] = '▀'
                    fr[c] = t
                    bgr[c] = b
                  end
                end
              end
              return [chars, fga, bga, rev.to_a]

            when :quadrant, :sextant
              table = canvas == :quadrant ? QUADRANTS : SEXTANTS
              on = dots.eq(fg.reshape(rows, cols, 1)) & set
              weights = Numo::Int32.cast(Array.new(k) { |i| 1 << i }).reshape(1, 1, k)
              code = (Numo::Int32.cast(on) * weights).sum(axis: 2)

              # A second color fills the rest of the cell when it covers
              # more of the cell than the empty dots
              other = set & ~on
              n_other = Numo::Int32.cast(other).sum(axis: 2)
              n_empty = Numo::Int32.cast(~set).sum(axis: 2)
              big = Numo::Int32.new(*dots.shape).fill(1 << 30)
              op = pr.dup
              op[~other] = 1 << 30
              second = op.min_index(axis: 2)
              bgc = dots.flatten[second.flatten].reshape(rows, cols)
              use = (n_other > 0) & (n_other >= n_empty)
              bg[use] = bgc[use]
              chars = code.to_a.map { |r| r.map { |c| table[c] } }

            when :eighths
              cnt = Numo::Int32.cast(set).sum(axis: 2)
              first = Numo::Int32.cast(set).max_index(axis: 2) % k
              last = (k - 1) - (Numo::Int32.cast(set.reverse(2)).max_index(axis: 2) % k)
              ca = cnt.to_a
              fa = first.to_a
              la = last.to_a
              chars = Array.new(rows) { Array.new(cols, ' ') }
              revs = Array.new(rows) { Array.new(cols, 0) }
              rows.times do |r|
                cols.times do |c|
                  n = ca[r][c]
                  next if n == 0

                  f = fa[r][c]
                  l = la[r][c]
                  if f == 0 && l == 7
                    chars[r][c] = '█'
                  elsif l == 7 || (7 - l) <= f
                    # Touches (or nearer) the bottom: lower blocks up to the top dot
                    chars[r][c] = LOWER[8 - f]
                  elsif l == 3
                    chars[r][c] = '▀'
                  elsif l == 0
                    chars[r][c] = '▔'
                  else
                    # Upper blocks: a reversed lower block
                    chars[r][c] = LOWER[7 - l]
                    revs[r][c] = 1
                  end
                end
              end
              return [chars, fg.to_a, bg.to_a, revs]

            when :ascii
              code = (Numo::Int32.cast(set) * Numo::Int32[1, 2, 4].reshape(1, 1, 3)).sum(axis: 2)
              chars = code.to_a.map { |r| r.map { |c| ASCII[c] } }
            end

            [chars, fg.to_a, bg.to_a, rev.to_a]
          end
        end
      end
    end
  end
end
