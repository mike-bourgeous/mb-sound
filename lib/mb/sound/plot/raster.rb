module MB
  module Sound
    module Plot
      # Geometry helpers shared by the renderers: min/max decimation of
      # long polylines and vectorized line rasterization.
      module Geometry
        module_function

        # Decimates a polyline (+xs+, +ys+ Numo::DFloats in device units,
        # x nondecreasing) with more than two points per device column to
        # the minimum and maximum of each column's points, in the order the
        # signal crossed them (so connected lines stay continuous).  With
        # +regular+ (evenly spaced x), groups equal counts of points
        # (faster).  With +ends+, each group's two points sit at its first
        # and last x (smooth slopes for vector output); otherwise both sit
        # at its center (whole spans per column for text rasters).
        # Returns [xs, ys].  The :plot_decimate kernel: FastUI.decimate
        # (#decimate_c) or exactly the same points from #decimate_ruby.
        def decimate_c(xs, ys, columns, regular: false, ends: false)
          return [xs, ys] if xs.length <= columns * 2 || columns < 1

          r = FastUI.decimate(xs, ys, columns, regular, ends)
          return r if r

          decimate_ruby(xs, ys, columns, regular: regular, ends: ends)
        end

        # The Ruby mirror of FastUI.decimate (see #decimate).  For irregular
        # x, every group of three or more points keeps its first and last x
        # (also for text rasters; kept as built in plot-1).
        def decimate_ruby(xs, ys, columns, regular: false, ends: false)
          n = xs.length
          return [xs, ys] if n <= columns * 2 || columns < 1

          return decimate_regular(xs, ys, columns, ends) if regular

          col = ends ? xs.floor : xs.round
          change = (col[1..] - col[0...-1]).ne(0).where + 1
          starts = [0] + change.to_a
          ends = change.to_a + [n]
          ox = []
          oy = []
          starts.zip(ends).each do |a, b|
            if b - a <= 2
              ox.concat(xs[a...b].to_a)
              oy.concat(ys[a...b].to_a)
              next
            end

            seg = ys[a...b]
            lo = seg.min
            hi = seg.max
            if ends
              ox << xs[a] << xs[b - 1]
            else
              ox << col[a] << col[a]
            end
            if seg[-1] >= seg[0]
              oy << lo << hi
            else
              oy << hi << lo
            end
          end
          [Numo::DFloat.cast(ox), Numo::DFloat.cast(oy)]
        end

        # Evenly spaced decimation (see #decimate).
        def decimate_regular(xs, ys, columns, ends)
          n = xs.length
          # Text rasters: groups a little under one column apart, so
          # rounding never skips a column
          g = ends ? (n.to_f / columns).ceil : [(n.to_f / columns).floor, 1].max
          groups = (n.to_f / g).ceil
          pad = groups * g - n
          if pad > 0
            xs = xs.concatenate(Numo::DFloat.new(pad).fill(xs[-1]))
            ys = ys.concatenate(Numo::DFloat.new(pad).fill(ys[-1]))
          end

          yg = ys.reshape(groups, g)
          xg = xs.reshape(groups, g)
          ymin = yg.min(axis: 1)
          ymax = yg.max(axis: 1)
          rising = (yg[true, -1] - yg[true, 0]) >= 0

          first = ymax.dup
          second = ymin.dup
          first[rising] = ymin[rising]
          second[rising] = ymax[rising]

          out_x = Numo::DFloat.zeros(groups, 2)
          out_y = Numo::DFloat.zeros(groups, 2)
          if ends
            out_x[true, 0] = xg[true, 0]
            out_x[true, 1] = xg[true, -1]
          else
            xc = (xg[true, 0] + xg[true, -1]) * 0.5
            out_x[true, 0] = xc
            out_x[true, 1] = xc
          end
          out_y[true, 0] = first
          out_y[true, 1] = second
          [out_x.flatten, out_y.flatten]
        end

        # True if +xs+ never decreases (NaNs aside).  The :plot_monotonic
        # kernel: FastUI.monotonic (#monotonic_c) or #monotonic_ruby.
        def monotonic_c(xs)
          r = FastUI.monotonic(xs)
          return r unless r.nil?

          monotonic_ruby(xs)
        end

        # The Ruby mirror of FastUI.monotonic (see #monotonic?).
        def monotonic_ruby(xs)
          return true if xs.length < 2

          d = xs[1..] - xs[0...-1]
          d = d[d.isfinite]
          d.length == 0 || d.min >= 0
        end

        # Integer points along every segment of a polyline (+xs+, +ys+ in
        # device units), one per device unit along the longer direction:
        # [ix, iy] Numo::Int32s.  Segments with a non-finite end are
        # skipped (gaps); a single finite point is drawn as a point.
        def line_points(xs, ys, limit: 4_000_000)
          xs = Numo::DFloat.cast(xs)
          ys = Numo::DFloat.cast(ys)
          return [Numo::Int32[], Numo::Int32[]] if xs.length == 0

          finite = xs.isfinite & ys.isfinite
          if xs.length == 1
            return finite[0] == 1 ? [Numo::Int32[xs[0].round], Numo::Int32[ys[0].round]] : [Numo::Int32[], Numo::Int32[]]
          end

          x0 = xs[0...-1]
          y0 = ys[0...-1]
          dx = xs[1..] - x0
          dy = ys[1..] - y0
          ok = finite[0...-1] & finite[1..]
          idx = ok.where
          # Finite points with no finite neighbor are drawn as points
          f = Numo::Int32.cast(finite)
          nb = Numo::Int32.zeros(f.length)
          nb[1..] += f[0...-1]
          nb[0...-1] += f[1..]
          lone = (f.eq(1) & nb.eq(0)).where
          px = xs[lone].round
          py = ys[lone].round

          if idx.length > 0
            x0 = x0[idx]
            y0 = y0[idx]
            dx = dx[idx]
            dy = dy[idx]

            steps = Numo::Int32.cast(Numo::DFloat.maximum(dx.abs, dy.abs).ceil).clip(1, nil)
            total = steps.sum
            if total > limit
              # Too many dots: subsample each segment's steps
              scale = limit.to_f / total
              steps = Numo::Int32.cast((Numo::DFloat.cast(steps) * scale).ceil).clip(1, nil)
              total = steps.sum
            end

            starts = steps.cumsum - steps
            seg = Numo::Int32.zeros(total)
            seg[starts[1..]] = 1 if starts.length > 1
            seg = seg.cumsum
            t = (Numo::DFloat.new(total).seq - starts[seg]) / steps[seg]

            sx = x0[seg] + dx[seg] * t
            sy = y0[seg] + dy[seg] * t
            # Each segment's end point (the next segment starts there, but
            # not after a gap or at the end)
            px = px.concatenate(sx.round).concatenate((x0 + dx).round)
            py = py.concatenate(sy.round).concatenate((y0 + dy).round)
          end

          [Numo::Int32.cast(px), Numo::Int32.cast(py)]
        end
      end

      # A grid of dots (terminal sub-cell dots or image pixels) holding
      # color indexes (0 = empty) into its color table; later drawing
      # covers earlier drawing.  Text canvases turn the dots into
      # characters; the image renderer uses the colors directly.
      class Raster
        attr_reader :width, :height, :dots, :colors

        def initialize(width, height)
          @width = width
          @height = height
          @dots = Numo::UInt16.zeros(height, width)
          @colors = [nil]
          @color_ids = {}
        end

        # The index for color +rgb+ ([r, g, b]), adding it to the table.
        def color(rgb)
          @color_ids[rgb] ||= (@colors << rgb.freeze).length - 1
        end

        # Sets the dots at Integer coordinates (+ix+, +iy+; y down) inside
        # the raster to color index +c+.
        def set(ix, iy, c)
          return if ix.length == 0

          inside = (ix >= 0) & (ix < @width) & (iy >= 0) & (iy < @height)
          k = inside.where
          return if k.length == 0

          @dots[iy[k] * @width + ix[k]] = c
        end

        # Draws a polyline (device units, y down) in color index +c+.
        # With +dash+ (e.g. [3, 2]), draws only the first dash[0] of every
        # dash.sum dots along the line.  The :plot_polyline kernel:
        # FastUI.polyline (#polyline_c) or the same dots from
        # #polyline_ruby.
        def polyline_c(xs, ys, c, dash: nil)
          if dash.nil? || (dash.all?(Integer) && dash.sum > 0)
            return if FastUI.polyline(@dots, xs, ys, c, dash ? dash[0] : 0, dash ? dash.sum : 0)
          end
          polyline_ruby(xs, ys, c, dash: dash)
        end

        # A copy of the raster for a kernel check (MB::Sound::Kernels).
        def kernel_copy
          c = dup
          c.kernel_restore(self)
          c
        end

        # What a kernel check compares.
        def kernel_state
          [@dots, @colors]
        end

        # Takes the dots and colors of +other+ (a #kernel_copy).
        def kernel_restore(other)
          @dots = other.dots.dup
          @colors = other.colors.dup
          @color_ids = other.instance_variable_get(:@color_ids).dup
        end

        # The Ruby mirror of FastUI.polyline (see #polyline).
        def polyline_ruby(xs, ys, c, dash: nil)
          ix, iy = Geometry.line_points(xs, ys)
          if dash && ix.length > 0
            keep = (Numo::Int32.new(ix.length).seq % dash.sum) < dash[0]
            ix = ix[keep]
            iy = iy[keep]
          end
          set(ix, iy, c)
          nil
        end

        # Draws isolated points.
        def points(xs, ys, c)
          xs = Numo::DFloat.cast(xs)
          ys = Numo::DFloat.cast(ys)
          ok = (xs.isfinite & ys.isfinite).where
          set(Numo::Int32.cast(xs[ok].round), Numo::Int32.cast(ys[ok].round), c)
        end

        # A Numo::UInt8 mask (height x width) of a polyline's dots.
        def line_mask(xs, ys)
          ix, iy = Geometry.line_points(xs, ys)
          mask = Numo::UInt8.zeros(@height, @width)
          inside = ((ix >= 0) & (ix < @width) & (iy >= 0) & (iy < @height)).where
          mask[iy[inside] * @width + ix[inside]] = 1 if inside.length > 0
          mask
        end

        # Fills each column between the dots of +mask_a+ and those of
        # +mask_b+ (or the device row +base+, a Float) in color index +c+:
        # areas under lines (base) and bands between two lines (mask_b).
        def fill_between(mask_a, c, mask_b: nil, base: nil)
          top_a, bot_a, has_a = extents(mask_a)
          if mask_b
            top_b, bot_b, has_b = extents(mask_b)
            has = has_a & has_b
            top = Numo::Int32.minimum(top_a, top_b)
            bot = Numo::Int32.maximum(bot_a, bot_b)
          else
            b = base.round.clamp(0, @height - 1)
            has = has_a
            top = top_a.clip(nil, b)
            bot = bot_a.clip(b, nil)
          end

          rows = Numo::Int32.new(@height, 1).seq
          fill = (rows >= top.reshape(1, @width)) & (rows <= bot.reshape(1, @width)) & has.reshape(1, @width)
          @dots[fill] = c
        end

        # The dots and color table, for #restore.
        def snapshot
          [@dots.dup, @colors.dup, @color_ids.dup]
        end

        # Returns the raster to a #snapshot.
        def restore(snap)
          @dots[true, true] = snap[0]
          @colors.replace(snap[1])
          @color_ids.replace(snap[2])
        end

        # Paints a block of color indexes +ids+ (Numo::Integer, rows x cols)
        # at the dot rectangle starting at (+x+, +y+).
        def paint(x, y, ids)
          h, w = ids.shape
          x1 = [x + w, @width].min
          y1 = [y + h, @height].min
          return if x1 <= x || y1 <= y

          @dots[y...y1, x...x1] = ids[0...(y1 - y), 0...(x1 - x)]
        end

        private

        # [first row, last row, any] per column of a mask
        def extents(mask)
          has = mask.max(axis: 0).gt(0)
          top = Numo::Int32.cast(mask.argmax(axis: 0))
          bot = (@height - 1) - Numo::Int32.cast(mask.reverse(0).argmax(axis: 0))
          [top, bot, has]
        end
      end

      Kernels.register :plot_decimate, on: Geometry.singleton_class, as: :decimate, c: :decimate_c, ruby: :decimate_ruby, covers: %w[FastUI.decimate]
      Kernels.register :plot_monotonic, on: Geometry.singleton_class, as: :monotonic?, c: :monotonic_c, ruby: :monotonic_ruby, covers: %w[FastUI.monotonic]
      Kernels.register :plot_polyline, on: Raster, as: :polyline, c: :polyline_c, ruby: :polyline_ruby, state: %i[@dots], covers: %w[FastUI.polyline]
    end
  end
end
