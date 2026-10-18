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

        # The color for +role+ in the current theme (UI::Themes): [r, g, b]
        # or a palette index (a Symbol role, or an [r, g, b] Array or index
        # as is; nil for the terminal's default color).
        def rgb(role)
          Themes.rgb(role)
        end
      end

      # State glyphs.  Several Unicode ones (▶ ● ◉ ○) are East Asian
      # "ambiguous" width, drawn wide by terminals set to treat ambiguous
      # characters as wide; UI.glyphs = :ascii avoids them.
      GLYPHS = {
        unicode: { play: '▶', will: '▷', stop: '■', on: '●', off: '○', armed: '◉', rec: '●', queued: '◷', sep: '│', arrow: '→' }.freeze,
        ascii: { play: '>', will: ')', stop: '#', on: '*', off: 'o', armed: '@', rec: 'R', queued: '~', sep: '|', arrow: '->' }.freeze,
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
          @glyph_set = glyphs
          @glyphs = Themes.glyphs(glyphs)
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

        # Writes +str+ at (+x+, +y+) in +role+'s color, clipped to the pane:
        # text cut at the right edge ends in an ellipsis (never a silent
        # chop; ux-1 r3 item 38), unless only blanks were cut.  Returns the
        # column after it.
        def text(x, y, str, role = nil, bold: false)
          str = str.to_s
          return x + str.length if y < 0 || y >= @h || x >= @w

          if x < 0
            str = str[-x..] || ''
            x = 0
          end
          @grid.text(@x + x, @y + y, Canvas.clip(str, @w - x), fg: Theme.rgb(role), bold: bold || Themes.bold?(role), max: @w - x)
          x + str.length
        end

        # +str+ cut to +room+ columns: with a final ellipsis when anything
        # but blanks was cut.
        def self.clip(str, room)
          return str if str.length <= room || room <= 0
          return str[0, room] if str[room..].strip.empty?
          "#{str[0, room - 1]}…"
        end

        # Continuation mark for a word broken across lines by .wrap.
        BREAK = '\\'

        # +text+ as lines of at most +width+ columns: words wrapped at
        # spaces (newlines kept), words longer than a line broken with a
        # BREAK at the end of each piece; lines after the first get +indent+
        # spaces (a hanging indent), counted in +width+.  The same rule as
        # the help pages' wrapping (MB::U.wrap), plus long words.
        def self.wrap(text, width, indent: 0)
          width = [width, indent + 2].max
          out = []
          lead = -> { out.empty? ? 0 : indent }
          text.to_s.split("\n", -1).each do |para|
            line = nil
            para.split(/ +/).each do |word|
              limit = width - lead.()
              cand = line ? "#{line} #{word}" : word
              if cand.length <= limit
                line = cand
                next
              end
              if line
                out << (' ' * lead.()) + line
                line = nil
                limit = width - indent
              end
              while word.length > limit
                out << (' ' * lead.()) + word[0, limit - 1] + BREAK
                word = word[(limit - 1)..]
                limit = width - indent
              end
              line = word
            end
            out << (' ' * lead.()) + (line || '')
          end
          out
        end

        # Writes +text+ wrapped (see .wrap) from row +y+ (default: #row),
        # at most +rows+ lines (the last ending in an ellipsis when more
        # were cut).  Returns the rows written, and moves #row past them.
        def wrap(text, y: @row, x: 0, indent: 0, role: nil, rows: @h - y)
          lines = Canvas.wrap(text, @w - x, indent: indent)
          if lines.length > rows && rows > 0
            lines = lines.first(rows)
            last = lines[-1].chomp(BREAK)
            lines[-1] = last.length >= @w - x ? "#{last[0, @w - x - 1]}…" : "#{last}…"
          end
          lines.each_with_index { |l, i| text(x, y + i, l, role) }
          @row = y + lines.length
          lines.length
        end

        # Writes +str+ at (+x+, +y+) in +role+'s color with attributes
        # (+reverse+: the color as the background, +bold+), clipped to the
        # pane.  Returns the column after it.
        def run(x, y, str, role = nil, reverse: false, bold: false, bg: nil)
          str = str.to_s
          return x + str.length if y < 0 || y >= @h || x >= @w || x + str.length <= 0

          if x < 0
            str = str[-x..]
            x = 0
          end
          attr = (reverse ? Plot::Text::Cells::REVERSE : 0) | (bold || Themes.bold?(role) ? Plot::Text::Cells::BOLD : 0)
          @grid.put_run(@x + x, @y + y, Canvas.clip(str, @w - x), Plot::Text::Cells.pack(Theme.rgb(role)), bg && Plot::Text::Cells.pack(Theme.rgb(bg)), attr)
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
          Canvas.new(@grid, @x + x, @y + y, w, h, glyphs: @glyph_set)
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

module MB
  module Sound
    module UI
      # The built-in themes: :default (ui-3's colors), :paper (for light
      # terminal backgrounds), :phosphor (green screen), and :mono (the
      # terminal's own 16 colors, so its palette decides).
      Themes.define(:default, based_on: :default) do
        Theme::ROLES.each { |name, rgb| role name, rgb.dup }
        role :title, Theme::ROLES[:title].dup, bold: true
        GLYPHS[:unicode].each { |k, v| glyphs(:unicode) { public_send(k, v) } if Themes::GLYPH_NAMES.include?(k) }
        GLYPHS[:ascii].each { |k, v| glyphs(:ascii) { public_send(k, v) } if Themes::GLYPH_NAMES.include?(k) }
        glyphs(:unicode) { rule '│'; hrule '─' }
        glyphs(:ascii) { rule '|'; hrule '-' }
      end

      Themes.define(:paper) do
        role :text, [40, 40, 40]
        role :dim, [120, 120, 120]
        role :title, [0, 75, 135], bold: true
        role :name, [110, 80, 0]
        role :key, [0, 95, 175]
        role :ok, [0, 120, 40]
        role :warn, [160, 100, 0]
        role :bad, [190, 0, 0]
        role :low, [0, 135, 60]
        role :mid, [175, 135, 0]
        role :high, [200, 30, 30]
      end

      Themes.define(:phosphor) do
        %i[text name key ok queued low].each { |r| role r, [157, 255, 180] }
        %i[dim].each { |r| role r, [79, 191, 108] }
        role :title, [200, 255, 210], bold: true
        %i[warn armed mid].each { |r| role r, [230, 255, 120] }
        %i[bad rec high].each { |r| role r, [255, 120, 90] }
      end

      Themes.define(:mono) do
        role :text, 7
        role :dim, 8
        role :title, 12, bold: true
        role :name, 3
        role :key, 6
        role :ok, 2
        role :warn, 3
        role :bad, 1
        role :rec, 9
        role :armed, 11
        role :queued, 5
        role :low, 2
        role :mid, 3
        role :high, 1
      end
    end
  end
end
