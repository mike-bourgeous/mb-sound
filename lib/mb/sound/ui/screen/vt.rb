require 'reline'

module MB
  module Sound
    module UI
      # A terminal model for a pane: what a program (Pry and Reline on the
      # REPL pane's pty) writes becomes rows of cells with colors, plus a
      # scrollback of lines scrolled off the top, the cursor, and the
      # replies a terminal sends back (cursor reports, device attributes,
      # mode reports).  Enough of a VT100/xterm for line editors and shells:
      # cursor moves, erases, insert/delete, scroll regions, the alternate
      # screen, SGR (16/256/truecolor, bold, dim, italic, underline,
      # reverse), wrapping with a pending wrap, tabs, and wide characters
      # (two cells, the right half "\0", the same widths Reline uses).
      # Not handled: left/right margins, insert mode, character sets,
      # double-width lines, combining characters (dropped).
      #
      # Generic (no MB::Sound types): a pane draws it into any grid with
      # #put_run (FastUI::Grid, or the Ruby mirror).
      #
      #     vt = UI::VT.new(24, 80)
      #     vt.feed("\e[31mhello\e[0m\r\n")
      #     vt.text           # => "hello\n\n..."
      #     vt.take_replies   # bytes to write back to the program
      class VT
        # Packed colors with this bit are palette indexes (the same bit as
        # Plot::Text::Cells::INDEXED; a spec checks).
        INDEXED = 0x1000000

        BOLD = 1
        REVERSE = 2
        UNDERLINE = 4
        ITALIC = 8
        DIM = 16

        # Lines kept above the screen by default.
        SCROLLBACK = 10_000

        # One row of cells: a String with one character per cell ("\0" for
        # the right half of a wide character), and colors and attributes
        # per cell, allocated only once a cell is styled (most rows are
        # plain text, and the scrollback keeps thousands of them), plus
        # whether the row continued onto the next one (an automatic wrap;
        # joined when copying or searching).
        class Row
          # The cells' characters (one per cell).
          attr_reader :text

          attr_accessor :wrapped

          def initialize(cols)
            @text = ' ' * cols
            @fg = @bg = @attr = nil
            @wrapped = false
          end

          # True when no cell has a color or attribute (drawn in one run).
          def plain?
            @fg.nil?
          end

          def length
            @text.length
          end

          # The character at cell +c+.
          def char(c) = @text[c]

          # Colors and attributes at cell +c+.
          def fg_at(c) = @fg && @fg[c]
          def bg_at(c) = @bg && @bg[c]
          def attr_at(c) = @attr ? @attr[c] : 0

          # Per-cell style Arrays (allocated on first use).
          def styles
            unless @fg
              n = @text.length
              @fg = Array.new(n)
              @bg = Array.new(n)
              @attr = Array.new(n, 0)
            end
            [@fg, @bg, @attr]
          end

          # Writes +str+ (one character per cell) from cell +c+ in one style.
          def write(c, str, fg, bg, attr)
            n = str.length
            @text[c, n] = str
            if @fg || fg || bg || attr != 0
              f, b, a = styles
              f.fill(fg, c, n)
              b.fill(bg, c, n)
              a.fill(attr, c, n)
            end
          end

          # Blanks cells +from+...+to+ with background +bg+.
          def blank(from, to, bg = nil)
            return if to <= from
            n = to - from
            @text[from, n] = ' ' * n
            return unless @fg || bg
            f, b, a = styles
            f.fill(nil, from, n)
            b.fill(bg, from, n)
            a.fill(0, from, n)
          end

          # Deletes +n+ cells at +c+, shifting the rest left (blank cells
          # with background +bg+ come in at the end).
          def delete(c, n, bg)
            cols = @text.length
            @text.slice!(c, n)
            @text << ' ' * n
            if @fg || bg
              styles.each_with_index do |arr, k|
                arr.slice!(c, n)
                arr.concat(Array.new(n, k == 1 ? bg : k == 2 ? 0 : nil))
              end
            end
            @text.slice!(cols..)
          end

          # Inserts +n+ blank cells at +c+, shifting the rest right (cut at
          # the row's end).
          def insert(c, n, bg)
            cols = @text.length
            @text.insert(c, ' ' * n)
            @text.slice!(cols..)
            if @fg || bg
              styles.each_with_index do |arr, k|
                arr.insert(c, *Array.new(n, k == 1 ? bg : k == 2 ? 0 : nil))
                arr.slice!(cols..)
              end
            end
          end

          def resize(cols)
            n = @text.length
            if cols < n
              half = @text[cols] == "\0"
              @text.slice!(cols..)
              @text[-1] = ' ' if half # a wide character whose right half was cut
              [@fg, @bg, @attr].each { |arr| arr&.slice!(cols..) }
            else
              @text << ' ' * (cols - n)
              if @fg
                @fg.concat(Array.new(cols - n))
                @bg.concat(Array.new(cols - n))
                @attr.concat(Array.new(cols - n, 0))
              end
            end
          end

          # The row's characters (wide characters once), without trailing
          # spaces when +strip+.
          def to_s(strip: true)
            t = @text.delete("\0")
            strip ? t.rstrip : t
          end
        end

        attr_reader :rows, :cols, :row, :col, :scrollback, :title

        # The scrollback's maximum length.
        attr_reader :max_scrollback

        # East Asian ambiguous characters' width (1 or 2): match the outer
        # terminal (and Reline.ambiguous_width).
        attr_accessor :ambiguous_width

        # Lines dropped from the front of the scrollback so far (absolute
        # line numbers stay stable: see #line_at).
        attr_reader :dropped

        # Counters: bytes fed, lines scrolled.
        attr_reader :bytes_fed, :scrolled

        def initialize(rows, cols, scrollback: SCROLLBACK, ambiguous_width: 1)
          raise ArgumentError, "A VT needs at least 1x1 cells (got #{rows}x#{cols})" unless rows.is_a?(Integer) && cols.is_a?(Integer) && rows > 0 && cols > 0

          @rows = rows
          @cols = cols
          @max_scrollback = scrollback
          @ambiguous_width = ambiguous_width
          @scrollback = []
          @dropped = 0
          @main = Array.new(rows) { Row.new(cols) }
          @alt = nil
          @replies = +''
          @pending = +''.b
          @bytes_fed = 0
          @scrolled = 0
          @title = nil
          @dirty = Array.new(rows, true)
          @all_dirty = true
          reset_state
        end

        # Rows on screen (the alternate screen while a program uses it).
        def screen
          @alt || @main
        end

        # True while the alternate screen is shown.
        def alt?
          !@alt.nil?
        end

        # True when the program turned on bracketed paste (?2004).
        def bracketed_paste?
          @bracketed_paste
        end

        # True when the program turned on application cursor keys (?1):
        # arrows are then sent as ESC O A.
        def app_cursor?
          @app_cursor
        end

        # True when the cursor should be shown (?25).
        def cursor_visible?
          @cursor_visible
        end

        # Bytes to send back to the program (cursor and mode reports);
        # cleared on read.
        def take_replies
          return '' if @replies.empty?
          r = @replies
          @replies = +''
          r
        end

        # The screen's lines as text (trailing spaces kept).
        def lines
          screen.map { |r| r.text.delete("\0") }
        end

        # The screen as text, lines joined by newlines.
        def text
          lines.join("\n")
        end

        # True if anything changed since #clean!.
        def dirty?
          @all_dirty || @dirty.any?
        end

        # Marks everything drawn.
        def clean!
          @all_dirty = false
          @dirty.fill(false)
        end

        # Marks everything to be redrawn.
        def invalidate
          @all_dirty = true
        end

        # Lines in the scrollback plus the screen (absolute numbers run
        # from #dropped to #dropped + #total_lines - 1).
        def total_lines
          @scrollback.length + @rows
        end

        # The Row at absolute line +n+ (scrollback, then screen), or nil.
        def line_at(n)
          i = n - @dropped
          return nil if i < 0
          return @scrollback[i] if i < @scrollback.length
          screen[i - @scrollback.length]
        end

        # Changes the size.  Rows keep their cells (cut or padded; no
        # reflow); when the screen gets shorter, rows above the cursor go to
        # the scrollback, as xterm does.
        def resize(rows, cols)
          return self if rows == @rows && cols == @cols
          raise ArgumentError, "A VT needs at least 1x1 cells (got #{rows}x#{cols})" unless rows > 0 && cols > 0

          [@main, @alt].compact.each do |scr|
            scr.each { |r| r.resize(cols) }
          end
          @scrollback.each { |r| r.resize(cols) if r.length < cols }
          if rows < @rows
            drop = @rows - rows
            # Rows below the cursor go first, then lines from the top
            below = [@rows - 1 - @row, 0].max
            cut = [drop, below].min
            [@main, @alt].compact.each { |scr| scr.pop(cut) }
            top = drop - cut
            if top > 0
              @main.shift(top).each { |r| push_scrollback(r) } if @alt.nil?
              @alt&.shift(top)
              @main.shift(top) if @alt
              @row -= top
            end
          else
            add = rows - @rows
            [@main, @alt].compact.each { |scr| add.times { scr << Row.new(cols) } }
          end
          @rows = rows
          @cols = cols
          @top = 0
          @bottom = rows - 1
          @row = @row.clamp(0, rows - 1)
          @col = @col.clamp(0, cols - 1)
          @wrap_pending = false
          @tabs = default_tabs
          @dirty = Array.new(rows, true)
          @all_dirty = true
          self
        end

        # Feeds bytes the program wrote.  Sequences and UTF-8 characters
        # split across calls are completed by the next call.  Returns self.
        def feed(bytes)
          return self if bytes.nil? || bytes.empty?
          @bytes_fed += bytes.bytesize
          data = @pending.empty? ? bytes.b : (@pending << bytes.b)
          @pending = +''.b

          # Hold back an incomplete UTF-8 character at the end
          tail = incomplete_utf8_tail(data)
          if tail > 0
            @pending = data.byteslice(-tail, tail)
            data = data.byteslice(0, data.bytesize - tail)
          end

          s = data.force_encoding(Encoding::UTF_8)
          s = s.scrub('?') unless s.valid_encoding?
          i = 0
          len = s.length
          while i < len
            ch = s[i]
            o = ch.ord
            if o >= 0x20 && o != 0x7F
              j = s.index(CONTROL, i) || len
              put_text(s[i...j])
              i = j
            elsif o == 0x1B
              n = escape(s, i)
              if n.nil?
                # Incomplete sequence: keep it for the next feed
                @pending = s[i..].b
                break
              end
              i = n
            else
              control(o)
              i += 1
            end
          end
          self
        end
        alias << feed

        # Draws rows into +grid+ (anything with #put_run) at (+x+, +y+),
        # +h+ rows of +w+ cells: the screen, or with +offset+ > 0 the view
        # scrolled back by that many lines.  Only rows changed since the
        # last draw unless +all+.  +marks+ highlights cells: [[absolute
        # line, from column, to column (exclusive), attribute bits], ...]
        # (search matches, a selection).  Returns the rows drawn.
        def draw(grid, x, y, w, h, offset: 0, all: false, marks: nil)
          all ||= @all_dirty || offset > 0 || !marks.nil?
          first = @dropped + @scrollback.length - offset # absolute line at the pane's top
          drawn = 0
          blank = nil
          h.times do |r|
            next unless all || (offset == 0 && @dirty[r])
            row = line_at(first + r)
            if row.nil?
              blank ||= ' ' * w
              grid.put_run(x, y + r, blank, nil, nil, 0)
            else
              draw_row(grid, x, y + r, w, row, marks && marks.select { |m| m[0] == first + r })
            end
            drawn += 1
          end
          clean!
          drawn
        end

        # Searches lines for +pattern+ (a Regexp or String, case-insensitive
        # for a lowercase String) from absolute line +from+ (exclusive),
        # backward (up) by default.  Returns [line, from column, to column]
        # or nil.
        def search(pattern, from: nil, backward: true)
          re = pattern.is_a?(Regexp) ? pattern : Regexp.new(Regexp.escape(pattern.to_s), pattern.to_s == pattern.to_s.downcase ? Regexp::IGNORECASE : nil)
          last = @dropped + total_lines - 1
          from ||= backward ? last + 1 : @dropped - 1
          range = backward ? (from - 1).downto(@dropped) : (from + 1).upto(last)
          range.each do |n|
            row = line_at(n) or next
            text, cols = row_text_columns(row)
            m = re.match(text) or next
            next if m[0].empty?
            return [n, cols[m.begin(0)], cols[m.end(0) - 1] + (row.char(cols[m.end(0) - 1] + 1) == "\0" ? 2 : 1)]
          end
          nil
        end

        # The text of absolute lines +from+..+to+ (wrapped rows joined),
        # columns +from_col+ on the first and up to +to_col+ (exclusive) on
        # the last.
        def text_between(from, to, from_col: 0, to_col: nil)
          out = +''
          from.upto(to) do |n|
            row = line_at(n) or next
            a = n == from ? from_col : 0
            b = n == to && to_col ? to_col : row.length
            seg = (row.text[a...b] || '').delete("\0")
            seg = seg.rstrip unless row.wrapped && n != to
            out << seg
            out << "\n" unless n == to || row.wrapped
          end
          out
        end

        def inspect
          "#<UI::VT #{@rows}x#{@cols} cursor #{@row + 1};#{@col + 1}#{alt? ? ' alt' : ''}, #{@scrollback.length} scrollback lines>"
        end

        private

        # C0 controls and DEL (where printable runs end).
        CONTROL = /[\x00-\x1f\x7f]/

        SGR_BASIC = { 1 => BOLD, 2 => DIM, 3 => ITALIC, 4 => UNDERLINE, 7 => REVERSE }.freeze
        SGR_OFF = { 21 => BOLD, 22 => BOLD | DIM, 23 => ITALIC, 24 => UNDERLINE, 27 => REVERSE }.freeze

        def reset_state
          @row = @col = 0
          @top = 0
          @bottom = @rows - 1
          @wrap_pending = false
          @fg = @bg = nil
          @attr = 0
          @saved = nil
          @origin = false
          @autowrap = true
          @cursor_visible = true
          @bracketed_paste = false
          @app_cursor = false
          @tabs = default_tabs
        end

        def default_tabs
          (0...@cols).select { |c| c % 8 == 0 && c > 0 }
        end

        def incomplete_utf8_tail(b)
          n = b.bytesize
          k = 1
          while k <= 3 && k <= n
            byte = b.getbyte(n - k)
            if byte & 0xC0 == 0x80
              k += 1
              next
            end
            need = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return need > k ? k : 0
          end
          0
        end

        def mark(r)
          @dirty[r] = true if r >= 0 && r < @rows
        end

        def width_of(ch)
          o = ch.ord
          return 1 if o < 0x7F
          w = (@widths ||= {})[o] ||= begin
            t = ::Reline::Unicode::EastAsianWidth
            k = t::CHUNK_LAST.bsearch_index { |last| o <= last }
            size = k ? t::CHUNK_WIDTH[k] : 1
            size == -1 ? @ambiguous_width : size
          end
          w
        end

        # Printable text at the cursor, wrapping at the right edge.
        def put_text(str)
          scr = screen
          if str.ascii_only?
            pos = 0
            len = str.length
            while pos < len
              wrap_now if @wrap_pending
              room = @cols - @col
              n = [room, len - pos].min
              row = scr[@row]
              # Overwriting half of a wide character blanks the other half
              blank_cell(@row, @col - 1) if @col > 0 && row.char(@col) == "\0"
              blank_cell(@row, @col + n) if @col + n < @cols && row.char(@col + n) == "\0"
              row.write(@col, pos == 0 && n == len ? str : str[pos, n], @fg, @bg, @attr)
              mark(@row)
              pos += n
              if @col + n >= @cols
                @col = @cols - 1
                @wrap_pending = @autowrap
              else
                @col += n
              end
            end
          else
            str.each_char { |ch| put_char(ch) }
          end
        end

        def put_char(ch)
          w = width_of(ch)
          return if w == 0 # combining marks and zero-width characters are dropped
          w = 1 if w > 2 || w < 0

          wrap_now if @wrap_pending
          if w == 2 && @col == @cols - 1
            # No room for both halves: wrap first (as xterm does)
            if @autowrap
              blank_cell(@row, @col)
              screen[@row].wrapped = true
              @col = 0
              index_down
            else
              return
            end
          end
          row = screen[@row]
          # Overwriting half of a wide character blanks the other half
          blank_cell(@row, @col - 1) if row.char(@col) == "\0" && @col > 0
          blank_cell(@row, @col + w) if @col + w < @cols && row.char(@col + w) == "\0"
          set_cell(row, @col, ch)
          set_cell(row, @col + 1, "\0") if w == 2
          mark(@row)
          if @col + w >= @cols
            @col = @cols - 1
            @wrap_pending = @autowrap
          else
            @col += w
          end
        end

        def set_cell(row, c, ch)
          row.write(c, ch, @fg, @bg, @attr)
        end

        def blank_cell(r, c)
          screen[r].blank(c, c + 1)
        end

        def wrap_now
          @wrap_pending = false
          screen[@row].wrapped = true
          @col = 0
          index_down
        end

        # Line feed: down one row, scrolling the region at its bottom.
        def index_down
          if @row == @bottom
            scroll_up(1)
          elsif @row < @rows - 1
            @row += 1
          end
        end

        def control(o)
          case o
          when 0x0A, 0x0B, 0x0C
            @wrap_pending = false
            screen[@row].wrapped = false
            index_down
          when 0x0D
            @wrap_pending = false
            @col = 0
          when 0x08
            @wrap_pending = false
            @col -= 1 if @col > 0
          when 0x09
            @col = (@tabs.find { |t| t > @col } || @cols - 1).clamp(0, @cols - 1)
          end
          # BEL, NUL, SO, SI, and the rest: ignored
        end

        # Scrolls the region up by +n+ lines; lines leaving the top of the
        # main screen go to the scrollback.
        def scroll_up(n)
          scr = screen
          n = [n, @bottom - @top + 1].min
          n.times do
            gone = scr.delete_at(@top)
            if @top == 0 && @alt.nil?
              push_scrollback(gone)
              @scrolled += 1
            end
            scr.insert(@bottom, Row.new(@cols))
          end
          @all_dirty = true
        end

        def scroll_down(n)
          scr = screen
          n = [n, @bottom - @top + 1].min
          n.times do
            scr.delete_at(@bottom)
            scr.insert(@top, Row.new(@cols))
          end
          @all_dirty = true
        end

        def push_scrollback(row)
          return if @max_scrollback <= 0
          @scrollback << row
          if @scrollback.length > @max_scrollback
            @scrollback.shift
            @dropped += 1
          end
        end

        # Parses the escape sequence at +i+ (an ESC); returns the index
        # after it, or nil if the sequence is incomplete.
        def escape(s, i)
          c = s[i + 1]
          return nil if c.nil?

          case c
          when '['
            j = i + 2
            j += 1 while j < s.length && !s[j].between?("\x40", "\x7e")
            return nil if j >= s.length
            csi(s[(i + 2)...j], s[j])
            j + 1
          when ']', 'P', '_', '^', 'X'
            # OSC (titles), DCS, APC, PM, SOS: to BEL or ST
            j = s.index(/\a|\e\\/, i + 2)
            return nil if j.nil?
            osc(s[(i + 2)...j]) if c == ']'
            j + (s[j] == "\a" ? 1 : 2)
          when '7'
            @saved = [@row, @col, @fg, @bg, @attr, @origin, @wrap_pending]
            i + 2
          when '8'
            restore_cursor
            i + 2
          when 'D'
            index_down
            i + 2
          when 'E'
            @col = 0
            index_down
            i + 2
          when 'M'
            @wrap_pending = false
            if @row == @top
              scroll_down(1)
            elsif @row > 0
              @row -= 1
            end
            i + 2
          when 'c'
            @main = Array.new(@rows) { Row.new(@cols) }
            @alt = nil
            reset_state
            @all_dirty = true
            i + 2
          when '(', ')', '*', '+', '#', '%', ' '
            return nil if s[i + 2].nil?
            i + 3
          else
            i + 2 # ESC = > N O H and others: ignored
          end
        end

        def osc(body)
          num, text = body.split(';', 2)
          @title = text if %w[0 2].include?(num)
        end

        def restore_cursor
          if @saved
            @row, @col, @fg, @bg, @attr, @origin, @wrap_pending = @saved
            @row = @row.clamp(0, @rows - 1)
            @col = @col.clamp(0, @cols - 1)
          else
            @row = @col = 0
          end
        end

        def csi(params, final)
          lead = params[0]
          if lead == '?' || lead == '>' || lead == '<' || lead == '='
            private_csi(lead, params[1..], final)
            return
          end
          if params.end_with?(' ', '$', '"', "'")
            return # DECSCUSR, DECSCA, ...: ignored
          end

          nums = params.split(';', -1).map { |p| p.empty? ? nil : p.to_i }
          n = (nums[0] || 1)
          n = 1 if n < 1
          case final
          when 'A' then @row = [@row - n, @row >= @top ? @top : 0].max; @wrap_pending = false
          when 'B', 'e' then @row = [@row + n, @row <= @bottom ? @bottom : @rows - 1].min; @wrap_pending = false
          when 'C', 'a' then @col = [@col + n, @cols - 1].min; @wrap_pending = false
          when 'D' then @col = [@col - n, 0].max; @wrap_pending = false
          when 'E' then @row = [@row + n, @bottom].min; @col = 0; @wrap_pending = false
          when 'F' then @row = [@row - n, @top].max; @col = 0; @wrap_pending = false
          when 'G', '`' then @col = (n - 1).clamp(0, @cols - 1); @wrap_pending = false
          when 'd' then set_row(n)
          when 'H', 'f' then set_row(nums[0] || 1); @col = ((nums[1] || 1) - 1).clamp(0, @cols - 1)
          when 'J' then erase_display(nums[0] || 0)
          when 'K' then erase_line(nums[0] || 0)
          when 'X'
            k = [n, @cols - @col].min
            screen[@row].blank(@col, @col + k, @bg)
            mark(@row)
          when 'P' then delete_chars(n)
          when '@' then insert_chars(n)
          when 'L' then insert_lines(n)
          when 'M' then delete_lines(n)
          when 'S' then scroll_up(n)
          when 'T' then scroll_down(n)
          when 'r'
            t = (nums[0] || 1) - 1
            b = (nums[1] || @rows) - 1
            b = @rows - 1 if b >= @rows
            if t < b
              @top = t
              @bottom = b
              @row = @origin ? @top : 0
              @col = 0
              @wrap_pending = false
            end
          when 'm' then sgr(nums.empty? ? [0] : nums)
          when 'n'
            case nums[0]
            when 5 then @replies << "\e[0n"
            when 6
              r = @origin ? @row - @top + 1 : @row + 1
              @replies << "\e[#{r};#{@col + 1}R"
            end
          when 'c' then @replies << "\e[?62;22c" if nums[0].to_i == 0
          when 's' then @saved = [@row, @col, @fg, @bg, @attr, @origin, @wrap_pending]
          when 'u' then restore_cursor
          when 'g'
            case nums[0] || 0
            when 0 then @tabs.delete(@col)
            when 3 then @tabs.clear
            end
          when 'h', 'l', 't', 'q'
            nil # ANSI modes (insert mode), window ops, LEDs: ignored
          end
        end

        def private_csi(lead, params, final)
          if lead == '?' && final == 'p' && params.end_with?('$')
            m = params.delete('$').to_i
            v = case m
                when 1 then @app_cursor ? 1 : 2
                when 6 then @origin ? 1 : 2
                when 7 then @autowrap ? 1 : 2
                when 25 then @cursor_visible ? 1 : 2
                when 1049, 47, 1047 then alt? ? 1 : 2
                when 2004 then @bracketed_paste ? 1 : 2
                else 0
                end
            @replies << "\e[?#{m};#{v}$y"
            return
          end
          if lead == '>' && final == 'c'
            @replies << "\e[>0;0;0c"
            return
          end
          return unless lead == '?' && (final == 'h' || final == 'l')

          on = final == 'h'
          params.split(';').each do |p|
            case p.to_i
            when 1 then @app_cursor = on
            when 6
              @origin = on
              @row = on ? @top : 0
              @col = 0
            when 7 then @autowrap = on
            when 25 then @cursor_visible = on
            when 2004 then @bracketed_paste = on
            when 47, 1047, 1049 then alt_screen(on, p.to_i == 1049)
            end
          end
        end

        def alt_screen(on, save)
          if on && @alt.nil?
            @saved_main = [@row, @col, @fg, @bg, @attr, @origin, @wrap_pending] if save
            @alt = Array.new(@rows) { Row.new(@cols) }
          elsif !on && @alt
            @alt = nil
            if save && @saved_main
              @row, @col, @fg, @bg, @attr, @origin, @wrap_pending = @saved_main
              @row = @row.clamp(0, @rows - 1)
              @col = @col.clamp(0, @cols - 1)
            end
          end
          @all_dirty = true
        end

        def set_row(r)
          @wrap_pending = false
          @row = @origin ? (@top + r - 1).clamp(@top, @bottom) : (r - 1).clamp(0, @rows - 1)
        end

        def erase_line(mode)
          row = screen[@row]
          case mode
          when 0 then row.blank(@col, @cols, @bg)
          when 1 then row.blank(0, @col + 1, @bg)
          else row.blank(0, @cols, @bg)
          end
          row.wrapped = false if mode != 1
          @wrap_pending = false
          mark(@row)
        end

        def erase_display(mode)
          scr = screen
          case mode
          when 0
            erase_line(0)
            ((@row + 1)...@rows).each { |r| scr[r].blank(0, @cols, @bg); scr[r].wrapped = false }
          when 1
            erase_line(1)
            (0...@row).each { |r| scr[r].blank(0, @cols, @bg); scr[r].wrapped = false }
          when 2
            scr.each { |r| r.blank(0, @cols, @bg); r.wrapped = false }
          when 3
            @dropped += @scrollback.length
            @scrollback.clear
          end
          @all_dirty = true
        end

        def delete_chars(n)
          row = screen[@row]
          n = [n, @cols - @col].min
          row.delete(@col, n, @bg)
          @wrap_pending = false
          mark(@row)
        end

        def insert_chars(n)
          row = screen[@row]
          n = [n, @cols - @col].min
          row.insert(@col, n, @bg)
          @wrap_pending = false
          mark(@row)
        end

        def insert_lines(n)
          return if @row < @top || @row > @bottom
          scr = screen
          n = [n, @bottom - @row + 1].min
          n.times do
            scr.delete_at(@bottom)
            scr.insert(@row, Row.new(@cols))
          end
          @col = 0
          @all_dirty = true
        end

        def delete_lines(n)
          return if @row < @top || @row > @bottom
          scr = screen
          n = [n, @bottom - @row + 1].min
          n.times do
            scr.delete_at(@row)
            scr.insert(@bottom, Row.new(@cols))
          end
          @col = 0
          @all_dirty = true
        end

        def sgr(codes)
          k = 0
          while k < codes.length
            c = codes[k] || 0
            case c
            when 0 then @fg = @bg = nil; @attr = 0
            when 1, 2, 3, 4, 7 then @attr |= SGR_BASIC[c]
            when 21, 22, 23, 24, 27 then @attr &= ~SGR_OFF[c]
            when 30..37 then @fg = INDEXED | (c - 30)
            when 39 then @fg = nil
            when 40..47 then @bg = INDEXED | (c - 40)
            when 49 then @bg = nil
            when 90..97 then @fg = INDEXED | (c - 90 + 8)
            when 100..107 then @bg = INDEXED | (c - 100 + 8)
            when 38, 48
              color, used = extended(codes, k + 1)
              c == 38 ? @fg = color : @bg = color
              k += used
            end
            k += 1
          end
        end

        # [packed color, codes used] for 38/48's arguments at +k+.
        def extended(codes, k)
          case codes[k]
          when 5 then [INDEXED | (codes[k + 1].to_i & 255), 2]
          when 2 then [(codes[k + 1].to_i.clamp(0, 255) << 16) | (codes[k + 2].to_i.clamp(0, 255) << 8) | codes[k + 3].to_i.clamp(0, 255), 4]
          else [nil, 0]
          end
        end

        # The row's text with each character's starting column.
        def row_text_columns(row)
          text = +''
          cols = []
          row.text.each_char.with_index do |ch, c|
            next if ch == "\0"
            text << ch
            cols << c
          end
          [text, cols]
        end

        def draw_row(grid, x, y, w, row, marks)
          text = row.text
          n = [w, text.length].min
          if row.plain? && (marks.nil? || marks.empty?)
            grid.put_run(x, y, n == text.length ? text : text[0, n], nil, nil, 0)
          else
            fg, bg, at = row.styles
            extra = Array.new(n, 0)
            marks&.each { |_, a, b, bits| (a...[b, n].min).each { |c| extra[c] |= bits if c >= 0 } }
            c = 0
            while c < n
              f = fg[c]
              b = bg[c]
              a = at[c] | extra[c]
              e = c + 1
              e += 1 while e < n && fg[e] == f && bg[e] == b && (at[e] | extra[e]) == a
              grid.put_run(x + c, y, text[c...e], f, b, a)
              c = e
            end
          end
          grid.put_run(x + n, y, ' ' * (w - n), nil, nil, 0) if w > n
        end
      end
    end
  end
end
