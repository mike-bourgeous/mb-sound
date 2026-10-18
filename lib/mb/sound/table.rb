module MB
  module Sound
    # One table for every table mb-sound prints (ux-1 item 32; maintainer:
    # "table should use new UI code instead of MB::U.table (at least for
    # now); make everything awesome"): the console's `table`, processing
    # matrices, and the bin/ scripts' listings.  Columns are as wide as
    # their widest cell, numbers right-aligned (decimals lined up), text
    # left-aligned; the header bold in the UI theme's title color over a
    # rule, the first column in the key color, rules between columns in the
    # dim color (box drawing, or | - + with UI.glyphs :ascii), every other
    # row shaded on wide tables.  Colors come from the UI theme
    # (UI::Themes) and print only to a terminal without NO_COLOR.
    #
    #     Table.new([[1, 'a'], [2.5, 'b']], header: %w[x name]).print
    #     Table.new({ x: [1, 2], y: [3, 4] })          # a Hash: columns
    #     MB::Sound.table(:sin, range: 0..1, steps: 5)  # the console's table
    class Table
      # Rows shaded from this many on.
      SHADE_FROM = 8

      attr_reader :header, :rows, :title

      # +data+: an Array of rows (Arrays), or a Hash from column name to
      # values (a column each).  +header+: column names (nil: a Hash's keys,
      # else none), +title+ a line above, +separate_rows+ rules between
      # rows, +show_nil+ prints nil values as "nil".
      def initialize(data, header: nil, title: nil, separate_rows: false, show_nil: false)
        if data.is_a?(Hash)
          header = data.keys if header.nil?
          cols = data.values.map { |v| Array(v) }
          n = cols.map(&:length).max || 0
          data = (0...n).map { |i| cols.map { |c| c[i] } }
        end
        @rows = Array(data).map { |r| Array(r) }
        @header = header == false ? nil : header&.map { |h| MB::U.remove_ansi(h.to_s) }
        @title = title
        @separate_rows = separate_rows
        @show_nil = show_nil
      end

      # The table as text: +color+ true for theme colors (default: when
      # $stdout is a terminal and NO_COLOR is unset).
      def to_s(color: Table.color?)
        lines(color: color).join("\n")
      end

      # The table's lines.
      def lines(color: Table.color?)
        cells = @rows.map { |r| r.map { |v| cell(v) } }
        ncol = [cells.map(&:length).max || 0, @header&.length || 0].max
        cells.each { |r| r.fill('', r.length...ncol) }
        numeric = (0...ncol).map { |c| cells.all? { |r| r[c].empty? || r[c].match?(/\A[-+]?[\d.,_]+(e[-+]?\d+)?\z/i) } && cells.any? { |r| !r[c].empty? } }
        cells = cells.map { |r| r.each_with_index.map { |v, c| numeric[c] ? align_decimal(cells.map { |x| x[c] }, v) : v } }
        widths = (0...ncol).map { |c| ([@header&.[](c).to_s.length] + cells.map { |r| r[c].length }).compact.max }

        g = UI.glyphs == :ascii ? { v: '|', h: '-', x: '+' } : { v: '│', h: '─', x: '┼' }
        paint = color ? ->(text, role, bold: false, bg: nil) { sgr(text, role, bold, bg) } : ->(text, *_, **_) { text }
        sep = paint.(" #{g[:v]} ", :dim)
        out = []
        out << paint.(@title.to_s, :title, bold: true) if @title
        if @header
          out << @header.each_with_index.map { |h, c| paint.(numeric[c] ? h.rjust(widths[c]) : h.ljust(widths[c]), :title, bold: true) }.join(sep).rstrip
          out << paint.(widths.map { |w| g[:h] * w }.join("#{g[:h]}#{g[:x]}#{g[:h]}"), :dim)
        end
        rule = paint.(widths.map { |w| g[:h] * w }.join("#{g[:h]}#{g[:x]}#{g[:h]}"), :dim)
        shade = cells.length >= SHADE_FROM
        cells.each_with_index do |r, i|
          bg = shade && i.odd? ? :queued : nil
          out << r.each_with_index.map { |v, c|
            text = numeric[c] ? v.rjust(widths[c]) : v.ljust(widths[c])
            paint.(text, c == 0 ? :key : :text, bg: bg)
          }.join(sep).rstrip
          out << rule if @separate_rows && i < cells.length - 1
        end
        out
      end

      # Prints the table to +io+.  Returns nil.
      def print(io = $stdout)
        io.puts to_s(color: Table.color?(io))
        nil
      end

      def inspect = to_s
      def pretty_print(q) = q.text(to_s)

      # True when +io+ may be colored (see ColorPolicy).
      def self.color?(io = $stdout)
        ColorPolicy.color?(io)
      end

      private

      # A value as table text: nil blank (or "nil"), floats to 6
      # significant figures, everything else its to_s without escapes.
      def cell(v)
        case v
        when nil then @show_nil ? 'nil' : ''
        when Float then v.finite? ? MB::M.sigfigs(v, 6).to_s : v.to_s
        when Rational then v.denominator == 1 ? v.numerator.to_s : "#{v.numerator}/#{v.denominator}"
        else MB::U.remove_ansi(v.to_s)
        end
      end

      # +v+ padded on the right so the decimal points of +column+ line up.
      def align_decimal(column, v)
        return v if v.empty?
        frac = ->(s) { s.include?('.') && !s.match?(/e/i) ? s.length - s.index('.') : 0 }
        most = column.map { |s| frac.(s) }.max
        f = frac.(v)
        v + ' ' * (most - f)
      end

      # +text+ in the UI theme's +role+ color (256 colors), bold, on a dim
      # shade for +bg+.
      def sgr(text, role, bold, bg)
        fg = UI::Themes.rgb(role)
        codes = []
        codes << 1 if bold || UI::Themes.bold?(role)
        codes << Plot::Text::ANSI.color(fg, :ansi256, false) if fg
        codes << "48;5;236" if bg
        return text if codes.empty?
        "\e[#{codes.join(';')}m#{text}\e[0m"
      end
    end
  end
end
