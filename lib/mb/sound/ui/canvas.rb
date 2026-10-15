module MB
  module Sound
    module UI
      # Colors by role (what a thing is, not which color it is), resolved
      # when cells are written.  Roles: :text, :dim, :title, :name, :key
      # (values worth noticing), :ok, :warn, :bad, :rec, :armed, :queued,
      # :low/:mid/:high (meter zones).
      module Theme
        ROLES = {
          text: [208, 208, 208],
          dim: [128, 128, 128],
          title: [135, 175, 215],
          name: [215, 215, 175],
          key: [95, 215, 255],
          ok: [95, 215, 95],
          warn: [255, 215, 95],
          bad: [255, 95, 95],
          rec: [255, 75, 75],
          armed: [255, 175, 0],
          queued: [135, 135, 255],
          low: [95, 175, 95],
          mid: [215, 215, 95],
          high: [255, 95, 95],
        }.freeze

        module_function

        # The [r, g, b] for +role+ (a Symbol or an [r, g, b] Array; nil for
        # the terminal's default color).
        def rgb(role)
          return nil if role.nil?
          return role if role.is_a?(Array)
          ROLES.fetch(role) { raise ArgumentError, "Unknown UI color role #{role.inspect} (#{ROLES.keys.map(&:inspect).join(', ')})" }
        end
      end

      # State glyphs.  Several Unicode ones (▶ ● ◉ ○) are East Asian
      # "ambiguous" width, drawn wide by terminals set to treat ambiguous
      # characters as wide; UI.glyphs = :ascii avoids them.
      GLYPHS = {
        unicode: { play: '▶', stop: '■', on: '●', off: '○', armed: '◉', rec: '●', queued: '◷', sep: '│', arrow: '→' }.freeze,
        ascii: { play: '>', stop: '#', on: '*', off: 'o', armed: '@', rec: 'R', queued: '~', sep: '|', arrow: '->' }.freeze,
      }.freeze

      # A pane's rectangle of a cell grid (Plot::Text::NativeCells, or the
      # Ruby mirror Plot::Text::Cells): panes write text, meters, and
      # sparklines in their own coordinates, clipped to the rectangle.
      #
      #     pane :hello, height: 2 do |c, s|
      #       c.puts ['bar ', :dim], [s.stamp, :key]
      #       c.meter s.load.to_f, width: 10
      #     end
      class Canvas
        # Eighth blocks for meters (0 to 8 eighths).
        EIGHTHS = [' ', '▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'].freeze

        # Levels for sparklines (lowest to highest).
        SPARKS = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'].freeze

        attr_reader :x, :y, :w, :h, :grid

        # The row #puts writes next.
        attr_accessor :row

        def initialize(grid, x, y, w, h, glyphs: :unicode)
          @grid = grid
          @x = x
          @y = y
          @w = w
          @h = h
          @row = 0
          @glyphs = GLYPHS.fetch(glyphs)
        end

        # A glyph by name (see GLYPHS).
        def glyph(name) = @glyphs.fetch(name)

        # Blanks the rectangle and moves #row to the top.
        def clear
          blank = (@blank ||= (' ' * @w).freeze)
          @h.times { |r| @grid.text(@x, @y + r, blank) }
          @row = 0
          self
        end

        # Writes +str+ at (+x+, +y+) in +role+'s color, clipped to the pane.
        # Returns the column after it.
        def text(x, y, str, role = nil, bold: false)
          str = str.to_s
          return x + str.length if y < 0 || y >= @h || x >= @w

          if x < 0
            str = str[-x..] || ''
            x = 0
          end
          @grid.text(@x + x, @y + y, str, fg: Theme.rgb(role), bold: bold, max: @w - x)
          x + str.length
        end

        # Writes segments on row +y+ from column +x+: Strings, or [String,
        # role] pairs.  Returns the column after them.
        def line(y, *segments, x: 0)
          segments.each do |seg|
            str, role = seg.is_a?(Array) ? seg : [seg, nil]
            x = text(x, y, str, role)
          end
          x
        end

        # Writes segments (see #line) on the next row.  Returns self.
        def puts(*segments)
          line(@row, *segments)
          @row += 1
          self
        end

        # A horizontal meter of +width+ cells filled to +fraction+ (0..1)
        # in eighths, at (+x+, +y+) (default: the next #puts row, from the
        # left).  +zones+ colors the fill by position: [[upto, role], ...]
        # (fractions of the width, rising); +role+ colors it all.  Returns
        # the column after it.
        def meter(fraction, width: @w, x: 0, y: @row, role: :ok, zones: nil, hold: nil)
          f = fraction.to_f
          f = 0.0 unless f.finite?
          eighths = (f.clamp(0.0, 1.0) * width * 8).round
          hold_at = hold && hold > 0 ? (hold.to_f.clamp(0.0, 1.0) * width).floor : nil
          # Runs of one color become one write
          cx = x
          run = +''
          run_role = nil
          width.times do |i|
            e = (eighths - i * 8).clamp(0, 8)
            ch = EIGHTHS[e]
            r = zones ? zone_role(zones, (i + 0.5) / width) : role
            if e == 0 && hold_at == i
              ch = '▏'
              r = zones ? zone_role(zones, hold.to_f) : role
            end
            if r != run_role && !run.empty?
              cx = text(cx, y, run, run_role)
              run = +''
            end
            run_role = r
            run << ch
          end
          text(cx, y, run, run_role) unless run.empty?
          x + width
        end

        # A sparkline of +values+ from +lo+ to +hi+ (the last values that
        # fit +width+).  Returns the column after it.
        def sparkline(values, lo: 0.0, hi: 1.0, width: @w, x: 0, y: @row, role: :key)
          vals = values.last(width)
          span = (hi - lo).to_f
          str = vals.map { |v|
            f = span > 0 ? ((v.to_f - lo) / span).clamp(0.0, 1.0) : 0.0
            SPARKS[(f * (SPARKS.length - 1)).round]
          }.join
          text(x, y, str, role)
        end

        # A sub-rectangle (in this pane's coordinates) as its own Canvas.
        def sub(x, y, w, h)
          w = [[w, @w - x].min, 0].max
          h = [[h, @h - y].min, 0].max
          Canvas.new(@grid, @x + x, @y + y, w, h, glyphs: @glyphs.equal?(GLYPHS[:ascii]) ? :ascii : :unicode)
        end

        # Text cut to +n+ characters (with an ellipsis when cut).
        def fit(str, n)
          str = str.to_s
          return str if str.length <= n
          return str[0, n] if n < 2
          "#{str[0, n - 1]}…"
        end

        # Text padded or cut to exactly +n+ characters.
        def pad(str, n)
          fit(str, n).ljust(n)
        end

        private

        def zone_role(zones, at)
          zones.each { |upto, role| return role if at <= upto }
          zones.last[1]
        end
      end
    end
  end
end
