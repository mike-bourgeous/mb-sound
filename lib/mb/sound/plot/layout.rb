module MB
  module Sound
    module Plot
      # Pixel layout shared by the SVG and image renderers: places each
      # chart's header (title, y axis title, legend), axes with ticks and
      # grid, colorbar, and plot area, drawing through a painter:
      #
      #     painter.rect(x, y, w, h, color, opacity: 1)
      #     painter.line(x1, y1, x2, y2, color, width: 1, dash: nil)
      #     painter.text(x, y, str, color, size:, anchor: :start, bold: false)  # y is the baseline
      #     painter.text_width(str, size) -> Float
      #     painter.plot(x, y, w, h) { |surface| ... }   # a mark surface for the plot area
      #
      # Sizes scale with +scale+ (font size 12 px at 1).
      class PixelLayout
        def initialize(painter, theme, scale: 1.0)
          @p = painter
          @theme = theme
          @s = scale
          @fs = (12 * scale).round
          @title_fs = (14 * scale).round
        end

        # Lays out +figure+ in a +width+ x +height+ pixel area.
        def render(figure, width, height)
          pad = 12 * @s
          top = pad
          if figure.title
            @p.text(width / 2.0, top + @title_fs, figure.title, @theme.ink, size: @title_fs + 2, anchor: :middle, bold: true)
            top += @title_fs + 12 * @s
          end

          rows = figure.rows
          cols = figure.columns
          gap = 18 * @s
          cell_w = (width - 2 * pad - gap * (cols - 1)) / cols.to_f
          cell_h = (height - top - pad - gap * (rows - 1)) / rows.to_f
          figure.charts.each_with_index do |chart, i|
            r, c = i.divmod(cols)
            panel(chart, pad + c * (cell_w + gap), top + r * (cell_h + gap), cell_w, cell_h)
          end
        end

        private

        def panel(chart, x, y, w, h)
          coord = chart.coord
          entries = chart.legend_entries(@theme)
          heat = chart.heatmap
          polar = chart.polar

          header = chart.title || !entries.empty? || (!polar && chart.y.title) ? @title_fs + 10 * @s : 0
          legend_rows = legend_rows(chart, entries, w)
          # Wrapped legend rows go under the title (or start on its row)
          header += (legend_rows.length - (chart.title ? 0 : 1)) * (@fs + 6 * @s) if legend_rows
          notes = !polar && !coord.x.secondary_ticks.empty?
          xtitle = polar ? nil : coord.x.title
          bottom = polar ? 0 : 6 * @s + @fs + 6 * @s
          bottom += @fs + 4 * @s if notes
          bottom += @fs + 4 * @s if xtitle

          plot_h = h - header - bottom
          yticks = polar ? [] : coord.y.ticks((plot_h / (34 * @s)).round.clamp(2, 10))
          label_w = yticks.map { |t| t.label ? @p.text_width(t.label, @fs) : 0 }.max || 0
          left = polar ? 0 : label_w + 10 * @s

          cbar_w = 0
          if heat
            zt = heat.z_scale.ticks((plot_h / (40 * @s)).round.clamp(2, 8))
            zl = zt.map { |t| t.label ? @p.text_width(t.label, @fs) : 0 }.max || 0
            cbar_w = 12 * @s + 12 * @s + 6 * @s + zl
          end

          px = x + left
          py = y + header
          pw = w - left - cbar_w - 4 * @s
          ph = plot_h
          if polar
            side = [pw, ph].min
            px += (pw - side) / 2
            py += (ph - side) / 2
            pw = ph = side
          end
          return if pw < 10 || ph < 10

          # Marks at the domain's ends stay clear of the frame
          inset = polar ? 0 : 4 * @s
          frame = [py, ph]
          py += inset
          ph -= 2 * inset

          draw_header(chart, entries, coord, x, y, w, polar, legend_rows) if header > 0

          xticks = coord.x.ticks((pw / (80 * @s)).round.clamp(2, 12))

          # Grid under the marks
          unless polar
            if chart.grid
              yticks.select(&:major).each do |t|
                v = coord.y.map(t.value)
                next unless v.finite? && v.between?(0, 1)

                yy = py + (1 - v) * ph
                @p.line(px, yy, px + pw, yy, @theme.grid, width: 1 * @s)
              end
              xticks.select(&:major).each do |t|
                u = coord.x.map(t.value)
                next unless u.finite? && u.between?(0, 1)

                xx = px + u * pw
                @p.line(xx, frame[0], xx, frame[0] + frame[1], @theme.grid, width: 1 * @s)
              end
            end
          end

          colors = chart.colors(@theme)
          @p.plot(px, py, pw, ph) do |surface|
            polar_grid(surface) if polar
            chart.marks.zip(colors).each do |m, rgb|
              if m.is_a?(Mark::Heatmap)
                m.draw(surface, coord, @theme)
              else
                surface.label = m.label if surface.respond_to?(:label=)
                m.draw(surface, coord, rgb)
              end
            end
          end

          return if polar

          axes(coord, xticks, yticks, px, py, pw, ph, notes, xtitle, frame)
          colorbar(heat, px + pw + 12 * @s, py, ph) if heat
        end

        # The width of legend entry +label+ (swatch, label, gap).
        def legend_entry_width(label)
          22 * @s + @p.text_width(label, @fs) + 14 * @s
        end

        # nil when the legend fits on the title row, else the entries in
        # rows that fit +w+ (the text renderer wraps the same way; images
        # drew the legend over long titles before).
        def legend_rows(chart, entries, w)
          return nil if entries.empty?

          title_w = chart.title ? @p.text_width(chart.title, @title_fs, bold: true) + 10 * @s : 0
          return nil if title_w + entries.sum { |l, _, _| legend_entry_width(l) } <= w

          rows = [[]]
          used = 0
          entries.each do |e|
            ew = legend_entry_width(e[0])
            if used > 0 && used + ew > w
              rows << []
              used = 0
            end
            rows.last << e
            used += ew
          end
          rows
        end

        def draw_header(chart, entries, coord, x, y, w, polar, legend_rows = nil)
          base = y + @title_fs
          tx = x
          if chart.title
            @p.text(tx, base, chart.title, @theme.ink, size: @title_fs, bold: true)
            tx += @p.text_width(chart.title, @title_fs, bold: true) + 10 * @s
          end

          legend_w = legend_rows ? 0 : entries.sum { |l, _, _| legend_entry_width(l) }
          yt = polar ? nil : coord.y.title
          if yt && tx + @p.text_width(yt, @fs) + legend_w < x + w
            @p.text(tx, base, yt, @theme.muted, size: @fs)
          end

          if legend_rows
            # Rows under the title (from the title row when there is none)
            row_base = chart.title ? base + @fs + 6 * @s : base
            legend_rows.each do |row|
              draw_legend_row(row, x, row_base)
              row_base += @fs + 6 * @s
            end
          else
            draw_legend_row(entries, x + w - legend_w, base)
          end
        end

        def draw_legend_row(entries, lx, base)
          entries.each do |label, rgb, kind|
            sw = 16 * @s
            case kind
            when :line
              @p.line(lx, base - @fs * 0.35, lx + sw, base - @fs * 0.35, rgb, width: 2.5 * @s)
            when :points
              @p.rect(lx + sw / 2 - 3 * @s, base - @fs * 0.35 - 3 * @s, 6 * @s, 6 * @s, rgb)
            else
              @p.rect(lx, base - @fs * 0.75, sw, @fs * 0.75, rgb, opacity: kind == :band ? 0.6 : 0.85)
            end
            @p.text(lx + sw + 6 * @s, base, label, @theme.ink, size: @fs)
            lx += 22 * @s + @p.text_width(label, @fs) + 14 * @s
          end
        end

        def axes(coord, xticks, yticks, px, py, pw, ph, notes, xtitle, frame)
          m = @theme.muted
          fy, fh = frame
          @p.line(px, fy + fh, px + pw, fy + fh, m, width: 1 * @s)
          @p.line(px, fy, px, fy + fh, m, width: 1 * @s)
          ph_x = fy + fh # the x axis

          used = []
          yticks.each do |t|
            v = coord.y.map(t.value)
            next unless v.finite? && v.between?(-1e-9, 1 + 1e-9)

            yy = py + (1 - v) * ph
            @p.line(px - (t.major ? 5 : 3) * @s, yy, px, yy, m, width: 1 * @s)
            next unless t.label
            next if used.any? { |u| (u - yy).abs < @fs }

            used << yy
            @p.text(px - 8 * @s, yy + @fs * 0.35, t.label, m, size: @fs, anchor: :end)
          end

          label_y = ph_x + 6 * @s + @fs
          last = -Float::INFINITY
          xticks.each do |t|
            u = coord.x.map(t.value)
            next unless u.finite? && u.between?(-1e-9, 1 + 1e-9)

            xx = px + u * pw
            @p.line(xx, ph_x, xx, ph_x + (t.major ? 5 : 3) * @s, m, width: 1 * @s)
            next unless t.label

            tw = @p.text_width(t.label, @fs)
            next if xx - tw / 2 < last + 6 * @s

            @p.text(xx, label_y, t.label, m, size: @fs, anchor: :middle)
            last = xx + tw / 2
          end

          row = label_y
          if notes
            row += @fs + 4 * @s
            last = -Float::INFINITY
            coord.x.secondary_ticks.each do |t|
              u = coord.x.map(t.value)
              xx = px + u * pw
              tw = @p.text_width(t.label, @fs)
              next if xx - tw / 2 < last + 4 * @s

              @p.line(xx, ph_x, xx, ph_x + 3 * @s, @theme.series(2), width: 1 * @s)
              @p.text(xx, row, t.label, @theme.series(2), size: @fs, anchor: :middle)
              last = xx + tw / 2
            end
          end

          if xtitle
            row += @fs + 4 * @s
            @p.text(px + pw, row, xtitle, m, size: @fs, anchor: :end)
          end
        end

        def colorbar(heat, x, y, h)
          cmap = heat.colormap_for(@theme)
          bw = 12 * @s
          n = [h.round, 1].max
          if @p.respond_to?(:vgradient)
            stops = Array.new(9) { |i| cmap.at(1 - i / 8.0) }
            @p.vgradient(x, y, bw, h, stops)
          else
            steps = [n, 64].min
            steps.times do |i|
              y0 = y + h * i / steps
              y1 = y + h * (i + 1) / steps
              @p.rect(x, y0, bw, y1 - y0 + 0.5, cmap.at(1 - (i + 0.5) / steps))
            end
          end

          zs = heat.z_scale
          used = []
          zs.ticks((h / (40 * @s)).round.clamp(2, 8)).each do |t|
            v = zs.map(t.value)
            next unless v.between?(-1e-9, 1 + 1e-9) && t.label

            yy = y + (1 - v) * h
            next if used.any? { |u| (u - yy).abs < @fs }

            used << yy
            @p.line(x + bw, yy, x + bw + 4 * @s, yy, @theme.muted, width: 1 * @s)
            @p.text(x + bw + 6 * @s, yy + @fs * 0.35, t.label, @theme.muted, size: @fs)
          end
        end

        def polar_grid(surface)
          t = Numo::DFloat.linspace(0, 2 * Math::PI, 241)
          w = surface.width - 1
          h = surface.height - 1
          [0.25, 0.5, 0.75, 1.0].each do |r|
            surface.polyline((Numo::NMath.cos(t) * r * 0.5 + 0.5) * w, (0.5 - Numo::NMath.sin(t) * r * 0.5) * h, @theme.grid, grid: true)
          end
          4.times do |k|
            a = k * Math::PI / 4
            surface.polyline(Numo::DFloat[0.5 - Math.cos(a) * 0.5, 0.5 + Math.cos(a) * 0.5] * w, Numo::DFloat[0.5 + Math.sin(a) * 0.5, 0.5 - Math.sin(a) * 0.5] * h, @theme.grid, grid: true)
          end
        end
      end
    end
  end
end
