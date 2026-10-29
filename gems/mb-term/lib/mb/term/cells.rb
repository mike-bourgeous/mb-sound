module MB
  module Term
    # A grid of character cells with colors (packed as 0xRRGGBB
    # Integers, nil for none) and attributes: the Ruby mirror of
    # native grids (MB::Term::Grid.native), which give the same text.
    class Cells
      BOLD = 1
      REVERSE = 2
      UNDERLINE = 4
      ITALIC = 8
      DIM = 16

      # SGR attribute codes by bit, in the order SGR sequences list them.
      ATTR_CODES = [[BOLD, '1'], [DIM, '2'], [ITALIC, '3'], [UNDERLINE, '4'], [REVERSE, '7']].freeze

      # Packed colors with this bit are palette indexes (0..255), written
      # as SGR indexes (30-37, 90-97, 38;5;n) so the terminal's own
      # palette shows them (terminal panes keep a program's colors).
      INDEXED = 0x1000000

      # Color modes by number, for native grids' #lines and #text.
      MODES = { none: 0, truecolor: 1, ansi256: 2, ansi16: 3 }.freeze

      # 0xRRGGBB for [r, g, b], INDEXED | n for a palette index n
      # (0..255), nil for nil.
      def self.pack(rgb)
        return INDEXED | rgb if rgb.is_a?(Integer)
        rgb && ((rgb[0] << 16) | (rgb[1] << 8) | rgb[2])
      end

      # [r, g, b] for 0xRRGGBB.
      def self.unpack(c)
        [(c >> 16) & 255, (c >> 8) & 255, c & 255]
      end

      # [r, g, b], or an Integer palette index, for a packed color.
      def self.color_of(c)
        c & INDEXED != 0 ? c & 255 : unpack(c)
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

      # Sets one cell.  +ch+ '' (or "\0") is the right half of a wide
      # character, written as nothing.
      def set(x, y, ch, fg: nil, bg: nil, bold: false, reverse: false)
        return if x < 0 || y < 0 || x >= @width || y >= @height

        i = y * @width + x
        @ch[i] = ch == "\0" ? '' : ch
        @fg[i] = Cells.pack(fg)
        @bg[i] = Cells.pack(bg)
        @attr[i] = (bold ? BOLD : 0) | (reverse ? REVERSE : 0)
      end

      # Sets the cell at index +i+ (no bounds checks; for canvases).
      def put(i, ch, fg, bg, attr)
        @ch[i] = ch == "\0" ? '' : ch
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

      # Writes +str+ from (+x+, +y+) in one style: packed colors (see
      # .pack; nil for none) and attribute bits, keeping the background.
      # "\0" is the right half of a wide character.  Clipped.
      def put_run(x, y, str, fg, bg, attr)
        return if y < 0 || y >= @height

        str.each_char.with_index do |c, k|
          cx = x + k
          next if cx < 0
          break if cx >= @width

          i = y * @width + cx
          @ch[i] = c == "\0" ? '' : c
          @fg[i] = fg
          @bg[i] = bg
          @attr[i] = attr
        end
        nil
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

      # Copies every cell of +other+ (Cells of any size) into these
      # with its top left corner at 0-based (+x+, +y+), clipped.  The
      # Ruby mirror of a native grid's #blit.
      def blit(other, x, y)
        raise ArgumentError, "Can't blit #{other.class} into Cells" unless other.is_a?(Cells)

        sx = x < 0 ? -x : 0
        sy = y < 0 ? -y : 0
        w = [other.width - sx, @width - (x + sx)].min
        h = [other.height - sy, @height - (y + sy)].min
        return self if w <= 0 || h <= 0

        och, ofg, obg, oattr = %i[@ch @fg @bg @attr].map { |v| other.instance_variable_get(v) }
        h.times do |r|
          si = (sy + r) * other.width + sx
          di = (y + sy + r) * @width + x + sx
          @ch[di, w] = och[si, w]
          @fg[di, w] = ofg[si, w]
          @bg[di, w] = obg[si, w]
          @attr[di, w] = oattr[si, w]
        end
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

      # Unchanged cells this short between changed ones are rewritten
      # rather than skipped with a cursor move (#frame).
      FRAME_GAP = 4

      # The terminal bytes that draw these cells at 1-based screen
      # (+row+, +col+): every cell (+prev+ nil) or only those that
      # differ from +prev+ (Cells of the same size holding what the
      # screen shows), as runs placed with cursor moves, styles as SGR
      # codes like #lines, inside DEC 2026 synchronized output with
      # +sync+.  The Ruby mirror of a native grid's #frame.
      def frame(prev, mode, row: 1, col: 1, sync: true)
        raise ArgumentError, "The previous frame's size differs" if prev && (prev.width != @width || prev.height != @height)

        pch, pfg, pbg, pat = prev && %i[@ch @fg @bg @attr].map { |v| prev.instance_variable_get(v) }
        changed = ->(i) { prev.nil? || @ch[i] != pch[i] || @fg[i] != pfg[i] || @bg[i] != pbg[i] || @attr[i] != pat[i] }

        @sgr ||= {}
        out = +''
        out << "\e[?2026h" if sync
        out << "\e[0m" if mode != :none
        styled = false
        pf = pb = nil
        pa = 0
        @height.times do |y|
          base = y * @width
          cx = -1
          x = 0
          while x < @width
            unless changed.(base + x)
              x += 1
              next
            end

            stop = x + 1
            last = x
            while stop < @width
              if changed.(base + stop)
                last = stop
                stop += 1
              elsif stop - last <= FRAME_GAP
                stop += 1
              else
                break
              end
            end
            stop = last + 1
            out << "\e[#{row + y};#{col + x}H" if cx != x
            (base + x).upto(base + stop - 1) do |i|
              if mode != :none
                f = @fg[i]
                b = @bg[i]
                a = @attr[i]
                unless f == pf && b == pb && a == pa
                  out << "\e[0m" if styled
                  styled = !(f.nil? && b.nil? && a == 0)
                  out << (@sgr[[f, b, a, mode]] ||= sgr([f, b, a], mode)) if styled
                  pf = f
                  pb = b
                  pa = a
                end
              end
              out << @ch[i]
            end
            cx = stop
            x = stop
          end
        end
        out << "\e[0m" if styled
        out << "\e[?2026l" if sync
        out
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
        ATTR_CODES.each { |bit, code| codes << code if attr & bit != 0 }
        codes << ANSI.color(Cells.color_of(fg), mode, false) if fg
        codes << ANSI.color(Cells.color_of(bg), mode, true) if bg
        "\e[#{codes.join(';')}m"
      end
    end

    # SGR color codes in each color mode.
    module ANSI
      BASIC = [
        [0, 0, 0], [205, 49, 49], [13, 188, 121], [229, 229, 16], [36, 114, 200], [188, 63, 188], [17, 168, 205], [229, 229, 229],
        [102, 102, 102], [241, 76, 76], [35, 209, 139], [245, 245, 67], [59, 142, 234], [214, 112, 214], [41, 184, 219], [255, 255, 255],
      ].freeze

      module_function

      # The SGR parameter for +rgb+ (or an Integer palette index, written
      # as an index in every mode, mapped to the nearest of 16 in
      # :ansi16) as a foreground (or background with +bg+) color in
      # +mode+.
      def color(rgb, mode, bg)
        if rgb.is_a?(Integer)
          k = rgb
          k = nearest(xterm(k), BASIC) if k >= 16 && mode == :ansi16
          return ((bg ? 40 : 30) + k).to_s if k < 8
          return ((bg ? 100 : 90) + k - 8).to_s if k < 16
          return "#{bg ? 48 : 38};5;#{k}"
        end

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

      # The [r, g, b] of xterm-256 color +n+ (BASIC for 0..15).
      def xterm(n)
        return BASIC[n] if n < 16
        if n < 232
          n -= 16
          levels = [0, 95, 135, 175, 215, 255]
          return [levels[n / 36], levels[(n / 6) % 6], levels[n % 6]]
        end
        g = 8 + 10 * (n - 232)
        [g, g, g]
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
  end
end
