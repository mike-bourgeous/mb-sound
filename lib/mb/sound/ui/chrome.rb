module MB
  module Sound
    module UI
      # Pane chrome, drawn by the screen for every pane (ux-1 round 3, item
      # 37): the rules between panes (box-drawing joins, the focused pane's
      # edges in the key color), each pane's title (set into the rule above
      # it when a rule spans the pane, else on a title row of its own when
      # the pane is tall enough), its number, and its focus mark.  Panes
      # draw only inside their inner rectangle, so no pane kind (cell panes,
      # Plot::Live scopes writing their own bytes) can skip or overdraw the
      # chrome, and the chrome is static cells: painted on full redraws
      # only, it costs nothing per frame with changed-cell frames.
      #
      #     plan = Chrome.plan(items, w: 120, h: 40, rules: true)
      #     plan.frames[:scope].inner   # where the scope draws
      #     Chrome.paint(grid, plan, glyphs: :unicode)
      module Chrome
        # A pane to frame: +name+, its +rect+ (MB::Term::Viewports::Rect), +title+
        # (text, or nil), +number+ (NAV's number, or nil), +focused+,
        # +jump+ (its NAV jump letter, shown beside the number in NAV), and
        # +note+ (text after the number, e.g. its rate with NAV f).
        Item = Data.define(:name, :rect, :title, :number, :focused, :jump, :note) do
          def initialize(name:, rect:, title: nil, number: nil, focused: false, jump: nil, note: nil)
            super
          end
        end

        # Where a pane's chrome went: +at+ :rule (the title in the rule
        # above), :inside (a title row at the top of +rect+), or :none (no
        # room, or nothing to show); +inner+ the rectangle the pane draws in.
        Frame = Data.define(:name, :rect, :inner, :title, :at, :number, :focused, :jump, :note)

        # The chrome of one screen: +gaps+ (rows of booleans: rule cells, or
        # nil without rules), the area's +w+ and +h+, and the Frames by name.
        Plan = Data.define(:gaps, :w, :h, :frames) do
          # Frames whose number is drawn over the pane (no rule or title row
          # to hold it): NAV draws these badges every frame.
          def overlays = frames.values.select { |f| f.at == :none && f.number }
        end

        # Rows a pane needs for a title row of its own (smaller panes skip
        # it: their content matters more).
        MIN_INSIDE_ROWS = 3

        # Columns a pane needs for any chrome.
        MIN_COLS = 6

        # Box-drawing glyphs for a rule cell by the rule cells around it
        # (bits: 1 up, 2 down, 4 left, 8 right).
        JOINS = {
          unicode: { 1 => '│', 2 => '│', 3 => '│', 4 => '─', 8 => '─', 12 => '─', 15 => '┼', 11 => '├', 7 => '┤',
                     14 => '┬', 13 => '┴', 10 => '┌', 6 => '┐', 9 => '└', 5 => '┘', 0 => '│' }.freeze,
          ascii: Hash.new { |_, k| [1, 2, 3, 0].include?(k) ? '|' : [4, 8, 12].include?(k) ? '-' : '+' },
        }.freeze

        module_function

        # The chrome for +items+ (Items) in a +w+ x +h+ area: with +rules+,
        # every cell no pane covers is a rule, and titles go into a rule row
        # spanning their pane; +inside+ false never takes a title row from a
        # pane (the band without boxes keeps its panes' natural heights).
        def plan(items, w:, h:, rules: true, inside: true)
          gaps = rules ? gap_cells(items, w, h) : nil
          frames = items.to_h do |it|
            r = it.rect
            at =
              if r.w < MIN_COLS
                :none
              elsif gaps && r.y > 0 && (r.x...(r.x + r.w)).all? { |x| gaps[r.y - 1][x] }
                :rule
              elsif inside && it.title && r.h >= MIN_INSIDE_ROWS
                :inside
              else
                :none
              end
            inner = at == :inside ? MB::Term::Viewports::Rect.new(r.x, r.y + 1, r.w, r.h - 1) : r
            [it.name, Frame.new(name: it.name, rect: r, inner: inner, title: it.title, at: at, number: it.number, focused: it.focused, jump: it.jump, note: it.note)]
          end
          Plan.new(gaps: gaps, w: w, h: h, frames: frames.freeze)
        end

        # The cells no item covers, as rows of booleans.
        def gap_cells(items, w, h)
          covered = Array.new(h) { Array.new(w, false) }
          items.each do |it|
            r = it.rect
            r.h.times { |dy| covered[r.y + dy]&.fill(true, r.x, [r.w, w - r.x].min) if r.y + dy < h }
          end
          covered.map { |row| row.map(&:!) }
        end

        # Paints +plan+ into +grid+ (a Plot::Text cell grid) offset by
        # (+x0+, +y0+): rules, titles, and numbers (+nav+: numbers as
        # reverse badges, the focused pane's with its name, as NAV mode
        # shows them; otherwise dim).  +focus_edges+ colors the rules around
        # the focused pane in the key color.
        def paint(grid, plan, glyphs: :unicode, nav: false, focus_edges: true, x0: 0, y0: 0)
          set = MB::Term::Themes.glyphs(glyphs)
          dim = MB::Term::Cells.pack(Theme.rgb(:dim))
          key = MB::Term::Cells.pack(Theme.rgb(:key))
          focus = focus_edges ? plan.frames.values.find(&:focused)&.rect : nil
          if (gaps = plan.gaps)
            joins = JOINS[glyphs == :ascii ? :ascii : :unicode]
            h = gaps.length
            w = plan.w
            h.times do |y|
              row = gaps[y]
              w.times do |x|
                next unless row[x]
                bits = (y > 0 && gaps[y - 1][x] ? 1 : 0) | (y < h - 1 && gaps[y + 1][x] ? 2 : 0) |
                       (x > 0 && row[x - 1] ? 4 : 0) | (x < w - 1 && row[x + 1] ? 8 : 0)
                glyph = joins[bits]
                glyph = set[:rule] || glyph if [0, 1, 2, 3].include?(bits)
                glyph = set[:hrule] || glyph if [4, 8, 12].include?(bits)
                near = focus && y >= focus.y - 1 && y <= focus.y + focus.h && x >= focus.x - 1 && x <= focus.x + focus.w
                grid.put_run(x0 + x, y0 + y, glyph, near ? key : dim, nil, 0)
              end
            end
          end
          plan.frames.each_value do |f|
            case f.at
            when :rule then title_in_rule(grid, f, nav, x0, y0)
            when :inside then title_row(grid, f, nav, x0, y0)
            end
          end
          grid
        end

        # NAV's badges for frames with nowhere to put their number (over the
        # pane's top right corner): drawn after the panes, every frame.
        def paint_overlays(grid, plan, x0: 0, y0: 0)
          plan.overlays.each do |f|
            r = f.rect
            b = badge(f, nav: true, w: r.w)
            grid.put_run(x0 + r.x + [r.w - b.length, 0].max, y0 + r.y, b[0, r.w], MB::Term::Cells.pack(Theme.rgb(f.focused ? :key : :queued)), nil,
                         MB::Term::Cells::REVERSE | MB::Term::Cells::BOLD)
          end
        end

        # A pane's number as text: " 3 " (in NAV with its jump letter,
        # " 3 t ", and " 3 t name " for the focused pane when it fits in
        # +w+), any note after it (" 3 t 60/s ").
        def badge(f, nav:, w:)
          return '' unless f.number
          short = "#{f.number}#{nav && f.jump ? " #{f.jump}" : ''}#{f.note ? " #{f.note}" : ''}"
          long = " #{short} #{f.name} "
          return long if nav && f.focused && long.length + 2 <= w
          short.length + 4 <= w ? " #{short} " : " #{f.number} "
        end

        # The title set into the rule above the pane (" TRACKS "), and the
        # number at the rule's right end.
        def title_in_rule(grid, f, nav, x0, y0)
          r = f.rect
          y = y0 + r.y - 1
          right = r.w
          if f.number
            b = badge(f, nav: nav, w: r.w)
            if b.length + 2 <= r.w
              right = r.w - b.length - 1
              put_badge(grid, x0 + r.x + right, y, b, f, nav)
            end
          end
          return unless f.title
          t = " #{f.title.to_s.upcase} "
          if t.length + 2 > right # (cut with an ellipsis, as title rows are, rather than dropped)
            room = right - 4
            return if room < 3
            t = " #{f.title.to_s.upcase[0, room - 1]}… "
          end
          grid.put_run(x0 + r.x + 1, y, t, MB::Term::Cells.pack(Theme.rgb(f.focused ? :key : :title)), nil, MB::Term::Cells::BOLD)
        end

        # The title row inside the pane ("TRACKS" at the left, as panes drew
        # it themselves before), and the number at its right.
        def title_row(grid, f, nav, x0, y0)
          r = f.rect
          y = y0 + r.y
          grid.put_run(x0 + r.x, y, ' ' * r.w, nil, nil, 0)
          right = r.w
          if f.number
            b = badge(f, nav: nav, w: r.w)
            if b.length + 1 <= r.w
              right = r.w - b.length
              put_badge(grid, x0 + r.x + right, y, b, f, nav)
            end
          end
          t = f.title.to_s.upcase
          t = right >= 3 ? "#{t[0, right - 2]}…" : '' if t.length + 1 > right
          grid.put_run(x0 + r.x, y, t, MB::Term::Cells.pack(Theme.rgb(f.focused ? :key : :title)), nil, MB::Term::Cells::BOLD) unless t.empty?
        end

        def put_badge(grid, x, y, b, f, nav)
          if nav
            grid.put_run(x, y, b, MB::Term::Cells.pack(Theme.rgb(f.focused ? :key : :queued)), nil, MB::Term::Cells::REVERSE | MB::Term::Cells::BOLD)
          else
            grid.put_run(x, y, b, MB::Term::Cells.pack(Theme.rgb(f.focused ? :key : :dim)), nil, 0)
          end
        end

        # A full-width rule (a band's rule toward the console, item 3) on row
        # +y+ of +grid+, +w+ cells from +x+.
        def hrule(grid, y, w, glyphs: :unicode, x: 0)
          g = MB::Term::Themes.glyphs(glyphs)[:hrule] || (glyphs == :ascii ? '-' : '─')
          grid.put_run(x, y, g * w, MB::Term::Cells.pack(Theme.rgb(:dim)), nil, 0)
        end
      end
    end
  end
end
