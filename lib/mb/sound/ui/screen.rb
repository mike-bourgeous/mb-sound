module MB
  module Sound
    module UI
      # A small terminal emulator for the bytes the band writes: cursor
      # moves (CUP), save and restore (DECSC/DECRC), scroll regions
      # (DECSTBM), line and screen erases, line feeds, and SGR colors, into
      # a Plot::Text::Cells grid.  Specs replay band frames through it (the
      # diffed frames must rebuild exactly what a full redraw shows), and
      # captures (bin/ui_demo.rb --capture) render the band with its scope
      # panes as text, ANSI, or HTML.  Not a general VT100: enough for the
      # band and plain text below it.
      class Screen
        attr_reader :rows, :cols, :cells, :row, :col

        def initialize(rows, cols)
          @rows = rows
          @cols = cols
          @cells = Plot::Text::Cells.new(cols, rows)
          @row = 0
          @col = 0
          @top = 0
          @bottom = rows - 1
          @fg = @bg = nil
          @bold = @reverse = false
          @saved = nil
        end

        # Feeds terminal bytes.  Returns self.
        def feed(bytes)
          s = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
          i = 0
          while i < s.length
            ch = s[i]
            if ch == "\e"
              i = escape(s, i + 1)
            elsif ch == "\n"
              line_feed
              i += 1
            elsif ch == "\r"
              @col = 0
              i += 1
            else
              put(ch)
              i += 1
            end
          end
          self
        end
        alias << feed

        # The screen's lines in a color mode (see Plot::Text::Cells#lines).
        def lines(mode = :none)
          @cells.lines(mode)
        end

        # The screen as text (lines joined by newlines).
        def to_text(mode = :none)
          lines(mode).join("\n")
        end

        # The [first, last] rows of the scroll region (1-based).
        def region
          [@top + 1, @bottom + 1]
        end

        private

        def put(ch)
          return if @col >= @cols
          @cells.set(@col, @row, ch, fg: @fg, bg: @bg, bold: @bold, reverse: @reverse)
          @col += 1
        end

        def line_feed
          if @row == @bottom
            scroll_up
          elsif @row < @rows - 1
            @row += 1
          end
        end

        # Scrolls the region up one line.
        def scroll_up
          (@top...@bottom).each do |r|
            @cols.times { |c| copy_cell(c, r + 1, c, r) }
          end
          @cols.times { |c| @cells.set(c, @bottom, ' ') }
        end

        def copy_cell(fx, fy, tx, ty)
          i = fy * @cols + fx
          ch = @cells.char(fx, fy)
          fg = @cells.instance_variable_get(:@fg)[i]
          bg = @cells.instance_variable_get(:@bg)[i]
          attr = @cells.instance_variable_get(:@attr)[i]
          @cells.set(tx, ty, ch, fg: fg && Plot::Text::Cells.unpack(fg), bg: bg && Plot::Text::Cells.unpack(bg),
            bold: attr & Plot::Text::Cells::BOLD != 0, reverse: attr & Plot::Text::Cells::REVERSE != 0)
        end

        # Parses an escape sequence after ESC at +i+; returns the index after it.
        def escape(s, i)
          case s[i]
          when '7'
            @saved = [@row, @col, @fg, @bg, @bold, @reverse]
            return i + 1
          when '8'
            @row, @col, @fg, @bg, @bold, @reverse = @saved if @saved
            return i + 1
          when '['
            j = i + 1
            j += 1 while j < s.length && !s[j].match?(/[A-Za-z@`~]/)
            params = s[(i + 1)...j]
            csi(params, s[j])
            return j + 1
          end
          i + 1
        end

        def csi(params, final)
          return if params.start_with?('?') # modes (2026 synchronized output, cursor)

          nums = params.split(';').map { |p| p.empty? ? nil : p.to_i }
          case final
          when 'H', 'f'
            @row = ((nums[0] || 1) - 1).clamp(0, @rows - 1)
            @col = ((nums[1] || 1) - 1).clamp(0, @cols - 1)
          when 'r'
            @top = ((nums[0] || 1) - 1).clamp(0, @rows - 1)
            @bottom = ((nums[1] || @rows) - 1).clamp(@top, @rows - 1)
            @row = @col = 0
          when 'K'
            range = case nums[0] || 0
                    when 0 then @col...@cols
                    when 1 then 0..@col
                    else 0...@cols
                    end
            range.each { |c| @cells.set(c, @row, ' ') }
          when 'J'
            case nums[0] || 0
            when 2, 3 then @rows.times { |r| @cols.times { |c| @cells.set(c, r, ' ') } }
            when 0
              (@col...@cols).each { |c| @cells.set(c, @row, ' ') }
              ((@row + 1)...@rows).each { |r| @cols.times { |c| @cells.set(c, r, ' ') } }
            end
          when 'm'
            sgr(nums.empty? ? [0] : nums.map { |n| n || 0 })
          when 'A' then @row = [@row - (nums[0] || 1), 0].max
          when 'B' then @row = [@row + (nums[0] || 1), @rows - 1].min
          when 'C' then @col = [@col + (nums[0] || 1), @cols - 1].min
          when 'D' then @col = [@col - (nums[0] || 1), 0].max
          when 'G' then @col = ((nums[0] || 1) - 1).clamp(0, @cols - 1)
          end
        end

        def sgr(codes)
          k = 0
          while k < codes.length
            c = codes[k]
            case c
            when 0 then @fg = @bg = nil; @bold = @reverse = false
            when 1 then @bold = true
            when 7 then @reverse = true
            when 22 then @bold = false
            when 27 then @reverse = false
            when 39 then @fg = nil
            when 49 then @bg = nil
            when 30..37 then @fg = Plot::Text::ANSI::BASIC[c - 30]
            when 90..97 then @fg = Plot::Text::ANSI::BASIC[c - 90 + 8]
            when 40..47 then @bg = Plot::Text::ANSI::BASIC[c - 40]
            when 100..107 then @bg = Plot::Text::ANSI::BASIC[c - 100 + 8]
            when 38, 48
              color, used = extended(codes, k + 1)
              c == 38 ? @fg = color : @bg = color
              k += used
            end
            k += 1
          end
        end

        # [rgb, codes used] for 38/48's arguments at +k+.
        def extended(codes, k)
          case codes[k]
          when 2 then [[codes[k + 1].to_i, codes[k + 2].to_i, codes[k + 3].to_i], 4]
          when 5 then [Screen.xterm(codes[k + 1].to_i), 2]
          else [nil, 0]
          end
        end

        # The [r, g, b] of xterm-256 color +n+.
        def self.xterm(n)
          return Plot::Text::ANSI::BASIC[n] if n < 16
          if n < 232
            n -= 16
            levels = [0, 95, 135, 175, 215, 255]
            return [levels[n / 36], levels[(n / 6) % 6], levels[n % 6]]
          end
          g = 8 + 10 * (n - 232)
          [g, g, g]
        end
      end
    end
  end
end
