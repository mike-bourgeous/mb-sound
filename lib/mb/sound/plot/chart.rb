module MB
  module Sound
    module Plot
      # Output methods shared by Chart and Figure.  Text options: +look+
      # (Plot::Text::LOOKS: :scope, :blocks, :mosaic, :quad, :spark,
      # :ascii), +color+ (:truecolor, :ansi256, :ansi16, :none, or :auto
      # from the environment), +theme+ (:dark or :light).  Image options:
      # +theme+ (:paper, :studio, :phosphor).
      module Renderable
        # The terminal text as one String (lines joined with newlines).
        def to_s(**opts)
          lines(**opts).join("\n")
        end

        # The terminal text as an Array of lines, each +width+ columns
        # (default from the terminal), +height+ lines in all.
        def lines(width: nil, height: nil, **opts)
          width ||= Terminal.width
          height ||= default_height
          Text.render(figure, width: width, height: height, **opts)
        end

        # An SVG document (String).
        def to_svg(width: 960, height: nil, theme: :paper, **opts)
          SVG.render(figure, width: width, height: height || default_pixel_height(width), theme: theme, **opts)
        end

        # A PNG image (binary String), drawn by Plot::Image.
        def to_png(width: 960, height: nil, theme: :studio, **opts)
          Image.render(figure, width: width, height: height || default_pixel_height(width), theme: theme, **opts).to_png
        end

        # Writes the plot to +path+ by its extension: .svg, .png, .txt (plain
        # text), .ans (text with ANSI colors), or .html (colored text in a
        # page).  Returns +path+.
        def save(path, **opts)
          data =
            case File.extname(path).downcase
            when '.svg' then to_svg(**opts)
            when '.png' then to_png(**opts)
            when '.txt' then to_s(color: :none, **opts) + "\n"
            when '.ans' then to_s(color: :truecolor, **opts) + "\n"
            when '.html' then AnsiHtml.page(to_s(color: :truecolor, **opts), title: figure.title || 'plot')
            else raise ArgumentError, "Unknown plot file extension in #{path.inspect} (.svg, .png, .txt, .ans, .html)"
            end
          File.binwrite(path, data)
          path
        end

        # Prints the plot in the terminal: as an inline image with +image+
        # (true for the detected protocol, or :sixel, :kitty, :iterm) when
        # the terminal supports one, else as text.  Returns nil.
        def show(image: nil, io: $stdout, **opts)
          image = Terminal.image_protocol if image == true || (image.nil? && Terminal.images_by_default?)
          if image
            w, h = Terminal.pixel_size
            img = Image.render(figure, width: opts[:width] || w, height: opts[:height] || h, theme: opts[:theme] || :studio)
            io.write(Terminal.image_escape(img, image, columns: Terminal.width))
            io.write("\n")
          else
            io.puts lines(**opts)
          end
          nil
        end

        private

        def default_height
          rows = figure_rows
          term = Terminal.height
          [[rows * 16, (term * 0.6).round].max, [term - 3, 8].max].min
        end

        def default_pixel_height(width)
          rows = figure_rows
          cols = figure.columns
          (width * 9 / 16.0 * rows / [cols, 1].max).round.clamp(120, 4000)
        end

        def figure_rows
          figure.rows
        end
      end

      # One panel: scales, a coordinate system, marks, and guide settings.
      # Build with Plot.chart (or MB::Sound.chart) and a block:
      #
      #     Plot.chart(title: 'Spectrum') {
      #       x :frequency, notes: true
      #       y :db, -90..0
      #       line levels, x: freqs, label: 'saw'
      #       rule y: -6, dash: [2, 2]
      #     }
      #
      # Charts are immutable values; renderers fit the scales to the data.
      class Chart
        include Renderable

        attr_reader :title, :x, :y, :marks, :legend, :grid, :polar

        def initialize(title: nil, x: nil, y: nil, marks: [], legend: :auto, grid: true, polar: false)
          @title = title&.to_s
          @x = x || Scale::Linear.new(nice: false)
          @y = y || Scale::Linear.new
          @marks = marks.dup.freeze
          @legend = legend
          @grid = grid
          @polar = polar
          freeze
        end

        # A Figure holding only this chart.
        def figure
          Figure.new([self])
        end

        # A copy with +changes+ (keywords of #initialize).
        def with(**changes)
          Chart.new(title: @title, x: @x, y: @y, marks: @marks, legend: @legend, grid: @grid, polar: @polar, **changes)
        end

        # The coordinate system with scales fit to the data.
        def coord
          xs = @x
          ys = @y
          if !xs.ready? || !ys.ready?
            ext = @marks.map { |m| m.extent(@x, @y) }
            xlo, xhi = span(ext.map { |e| e[0] }, ext.map { |e| e[1] })
            ylo, yhi = span(ext.map { |e| e[2] }, ext.map { |e| e[3] })
            if @polar
              xlo, xhi = 0.0, 1.0
              ylo = 0.0
            end
            xs = xs.fit(xlo, xhi) unless xs.ready?
            ys = ys.fit(ylo, yhi) unless ys.ready?
          end
          (@polar ? Coord::Polar : Coord::Cartesian).new(x: xs, y: ys)
        end

        # [rgb, ...] for each mark under +theme+: palette slots in order for
        # series without a color, the muted color for rules.
        def colors(theme)
          slot = 0
          @marks.map { |m|
            case m.color
            when nil
              if m.series?
                c = theme.series(slot)
                slot += 1
                c
              else
                theme.muted
              end
            when Integer then theme.series(m.color)
            else Color.rgb(m.color)
            end
          }
        end

        # [[label, rgb, kind], ...] for the legend (empty when off, or for
        # one series under :auto, which the title names).
        def legend_entries(theme)
          return [] if @legend == false || @legend == :none

          entries = @marks.zip(colors(theme)).select { |m, _| m.label && !m.label.empty? && m.kind != :image }.map { |m, c| [m.label, c, m.kind] }
          return [] if @legend == :auto && entries.length < 2 && @title

          entries
        end

        # The first heatmap mark (for the colorbar), or nil.
        def heatmap
          @marks.find { |m| m.is_a?(Mark::Heatmap) }
        end

        def inspect
          "#<MB::Sound::Plot::Chart #{@title.inspect} #{@marks.length} mark#{'s' unless @marks.length == 1}: #{@marks.map { |m| m.class.name.split('::').last }.join(', ')}>"
        end

        private

        def span(los, his)
          los = los.compact
          his = his.compact
          [los.min, his.max]
        end
      end

      # Several charts in a grid (+columns+ wide; default about square),
      # with an optional +title+ over them.
      class Figure
        include Renderable

        attr_reader :charts, :title, :columns, :rows

        def initialize(charts, columns: nil, rows: nil, title: nil)
          @charts = charts.flat_map { |c| c.is_a?(Figure) ? c.charts : [c] }.freeze
          n = [@charts.length, 1].max
          if columns
            @columns = columns.clamp(1, n)
            @rows = (n.to_f / @columns).ceil
          elsif rows
            @rows = rows.clamp(1, n)
            @columns = (n.to_f / @rows).ceil
          else
            @rows = Math.sqrt(n).ceil
            @columns = (n.to_f / @rows).ceil
          end
          @title = title&.to_s
          freeze
        end

        def figure
          self
        end

        def inspect
          "#<MB::Sound::Plot::Figure #{@title.inspect} #{@rows}x#{@columns}: #{@charts.map(&:title).inspect}>"
        end
      end

      # The block receiver for Plot.chart: methods set scales and add
      # marks.  A block taking an argument gets the builder instead (so the
      # block's own methods stay callable).
      class ChartBuilder
        def initialize(**kwargs)
          @opts = { marks: [] }.merge(kwargs)
          @opts[:marks] = @opts[:marks].dup
        end

        # Sets the chart title.
        def title(text)
          @opts[:title] = text
          self
        end

        # Sets the x scale: a Scale, a Range (linear domain), or a kind
        # Symbol (:linear, :log, :frequency, :db, :time, :samples, :bars,
        # :symmetric, :categorical) with an optional domain Range and the
        # scale's keywords (+label:+, +unit:+, +sample_rate:+, +notes:+,
        # +nice:+, ...).
        def x(spec = nil, domain = nil, **kwargs)
          @opts[:x] = Scale.build(spec, domain, **kwargs)
          self
        end

        # Sets the y scale (see #x).
        def y(spec = nil, domain = nil, **kwargs)
          @opts[:y] = Scale.build(spec, domain, **kwargs)
          self
        end

        # Polar coordinates: x is the angle (+turn+ data units per turn,
        # default 1 cycle), y the radius.
        def polar(turn: 1.0)
          @opts[:polar] = true
          @opts[:x] = Scale::Linear.new(0..turn, nice: false)
          self
        end

        # +false+ hides the legend, +true+ shows it even for one series.
        def legend(show = true)
          @opts[:legend] = show
          self
        end

        # Turns grid lines on or off.
        def grid(show = true)
          @opts[:grid] = show
          self
        end

        # Adds a connected line (see Mark::Line).
        def line(y, **kwargs)
          add Mark::Line.new(y, **kwargs)
        end

        # Adds a staircase line.
        def step(y, **kwargs)
          add Mark::Line.new(y, step: true, **kwargs)
        end

        # Adds points.
        def points(y, **kwargs)
          add Mark::Points.new(y, **kwargs)
        end
        alias scatter points

        # Adds stems from a base value (default 0).
        def stems(y, **kwargs)
          add Mark::Stems.new(y, **kwargs)
        end
        alias bars stems

        # Adds a filled area under a line.
        def area(y, **kwargs)
          add Mark::Area.new(y, **kwargs)
        end

        # Adds a filled band between two lines.
        def band(lo, hi, **kwargs)
          add Mark::Band.new(lo, hi, **kwargs)
        end

        # Adds a heatmap (rows of +z+ bottom to top; see Mark::Heatmap).
        def heatmap(z, **kwargs)
          add Mark::Heatmap.new(z, **kwargs)
        end
        alias image heatmap

        # Adds a reference line at +x:+ or +y:+.
        def rule(**kwargs)
          add Mark::Rule.new(**kwargs)
        end

        # Adds any mark object.
        def add(mark)
          @opts[:marks] << mark
          self
        end
        alias << add

        # The Chart built so far.
        def build
          Chart.new(**@opts)
        end
      end

      # The block receiver for Plot.figure: #chart adds a panel.
      class FigureBuilder
        def initialize
          @charts = []
        end

        # Adds a chart built from a block (see Plot.chart), or +chart+.
        def chart(chart = nil, title: nil, **kwargs, &block)
          @charts << (chart || Plot.chart(title: title, **kwargs, &block))
          self
        end
        alias panel chart

        # The charts added so far.
        def charts
          @charts.dup
        end
      end

      # Builds a Chart from a block (see ChartBuilder), plus any keywords
      # of ChartBuilder's setters as initial values (+title:+, +x:+, +y:+).
      def self.chart(title: nil, x: nil, y: nil, legend: :auto, grid: true, &block)
        b = ChartBuilder.new(title: title, x: x && Scale.build(x), y: y && Scale.build(y), legend: legend, grid: grid)
        if block
          block.arity == 0 ? b.instance_exec(&block) : block.call(b)
        end
        b.build
      end

      # Builds a Figure from a block calling #chart for each panel, or from
      # +charts+.
      def self.figure(*charts, columns: nil, rows: nil, title: nil, &block)
        if block
          b = FigureBuilder.new
          block.arity == 0 ? b.instance_exec(&block) : block.call(b)
          charts += b.charts
        end
        Figure.new(charts, columns: columns, rows: rows, title: title)
      end
    end
  end
end
