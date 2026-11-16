module MB
  module Sound
    module Plot
      # A bare waveform drawn straight into a screen's cell grid as a
      # Braille line: no chart, scales, axes, or layout (ui-wave-perf-1,
      # the plug-in way of drawing a display every frame).  The C kernel is
      # FastUI.wave; #draw_ruby is its exact mirror, registered beside it
      # as the :plot_wave kernel (MB::Sound::Kernels).
      #
      #     Plot::Wave.draw(grid, cycle, x: 2, y: 1, w: 40, h: 8, lo: -1.0, hi: 1.0, fg: 0x5fafff)
      #
      # Each of the 2 * w dot columns shows the min and max of the samples
      # it covers (as many samples as columns or more), or the value
      # linearly interpolated at its position (fewer), joined to the
      # previous column's last value so the line has no gaps; values
      # outside lo..hi stick to the edge rows.  +mark+ is a dot column for
      # a dotted vertical marker (a playhead; -1 for none) in +mark_fg+
      # where its cells hold no line.  Colors are packed as
      # MB::Term::Cells.pack gives them (-1 for none).  The rectangle is
      # cleared first.
      module Wave
        # Braille dot bits by dot row in a cell (0..3) and dot column (0..1).
        BITS = [[0x01, 0x08], [0x02, 0x10], [0x04, 0x20], [0x40, 0x80]].freeze

        module_function

        # Draws +data+ (a 1D Numo::SFloat) into +grid+ (NativeCells, or the
        # Ruby mirror MB::Term::Cells) through the :plot_wave kernel.
        # Returns +grid+.
        def draw(grid, data, x:, y:, w:, h:, lo:, hi:, fg:, mark: -1, mark_fg: -1)
          if grid.is_a?(MB::Term::Cells)
            draw_ruby(grid, data, x, y, w, h, lo.to_f, hi.to_f, fg, mark, mark_fg)
          else
            Kernels.plot_wave(grid, data, x, y, w, h, lo.to_f, hi.to_f, fg, mark, mark_fg)
          end
          grid
        end

        # The Ruby mirror of FastUI.wave (same arguments, same cells).
        def draw_ruby(grid, data, x0, y0, w, h, lo, hi, fg, mark, mark_fg)
          raise ArgumentError, 'The data must be a contiguous 1D Numo::SFloat' unless data.is_a?(Numo::SFloat) && data.ndim == 1
          return nil if w <= 0 || h <= 0

          gw = grid.width
          gh = grid.height
          h.times do |cy|
            gy = y0 + cy
            next if gy < 0 || gy >= gh
            w.times do |cx|
              gx = x0 + cx
              next if gx < 0 || gx >= gw
              store(grid, gx, gy, 0x20, -1)
            end
          end
          n = data.size
          return nil if n <= 0 || !(hi > lo)

          cols = 2 * w
          rows = 4 * h
          prev = -1
          w.times do |cx|
            bits = Array.new(h, 0)
            marks = Array.new(h, 0)
            2.times do |dx|
              c = 2 * cx + dx
              if n >= cols
                i0 = c * n / cols
                i1 = (c + 1) * n / cols
                i1 = i0 + 1 if i1 <= i0
                mn = mx = nil
                (i0...i1).each do |i|
                  v = data[i]
                  next if v.nan?
                  if mn.nil?
                    mn = mx = v
                  elsif v < mn
                    mn = v
                  elsif v > mx
                    mx = v
                  end
                end
                if mn.nil?
                  prev = -1
                  next
                end
                lv = data[i1 - 1]
                top = row(mx, lo, hi, rows)
                bot = row(mn, lo, hi, rows)
                last = lv.nan? ? -1 : row(lv, lo, hi, rows)
              else
                pos = cols > 1 ? c.to_f * (n - 1).to_f / (cols - 1).to_f : 0.0
                j = pos.floor
                j = n - 1 if j > n - 1
                j1 = j + 1 < n ? j + 1 : n - 1
                a = data[j]
                b = data[j1]
                v = a + (b - a) * (pos - j.to_f)
                if v.nan?
                  prev = -1
                  next
                end
                top = bot = last = row(v, lo, hi, rows)
              end
              if prev >= 0
                top = prev if prev < top
                bot = prev if prev > bot
              end
              (top..bot).each { |r| bits[r / 4] |= BITS[r % 4][dx] }
              prev = last
            end
            if mark >= 0 && mark / 2 == cx
              dx = mark % 2
              (0...rows).step(2) { |r| marks[r / 4] |= BITS[r % 4][dx] }
            end
            gx = x0 + cx
            next if gx < 0 || gx >= gw
            h.times do |cy|
              gy = y0 + cy
              b = bits[cy] | marks[cy]
              next if b == 0 || gy < 0 || gy >= gh
              store(grid, gx, gy, 0x2800 + b, bits[cy] != 0 ? fg : mark_fg)
            end
          end
          nil
        end

        # The dot row (0 top .. rows - 1 bottom) of +v+ between +lo+ and +hi+.
        def row(v, lo, hi, rows)
          q = (hi - v) / (hi - lo) * (rows - 1).to_f
          return 0 if q.nan? || q == -Float::INFINITY
          return rows - 1 if q == Float::INFINITY
          r = q.round.to_f
          return 0 unless r > 0.0
          return rows - 1 if r > (rows - 1).to_f
          r.to_i
        end

        # One cell: codepoint +cp+ in packed color +fg+ (no background or
        # attributes), in either kind of grid.
        def store(grid, x, y, cp, fg)
          if grid.is_a?(MB::Term::Cells)
            i = y * grid.width + x
            grid.instance_variable_get(:@ch)[i] = cp.chr(Encoding::UTF_8)
            grid.instance_variable_get(:@fg)[i] = fg < 0 ? nil : fg
            grid.instance_variable_get(:@bg)[i] = nil
            grid.instance_variable_get(:@attr)[i] = 0
          else
            grid.set_cell(x, y, cp.chr(Encoding::UTF_8), fg < 0 ? nil : fg, nil, 0)
          end
        end
      end

      Kernels.register :plot_wave, c: FastUI.method(:wave), ruby: Wave.method(:draw_ruby), group: :fast_ui,
        check: 'draws into a grid (no pair of grids to compare); plot/wave_spec.rb compares C and Ruby cell for cell'
    end
  end
end
