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
        # (faster).  Returns [xs, ys].
        def decimate(xs, ys, columns, regular: false)
          n = xs.length
          return [xs, ys] if n <= columns * 2 || columns < 1

          return decimate_regular(xs, ys, columns) if regular

          col = xs.floor
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
            xm = (xs[a] + xs[b - 1]) * 0.5
            ox << xm << xm
            if seg[-1] >= seg[0]
              oy << lo << hi
            else
              oy << hi << lo
            end
          end
          [Numo::DFloat.cast(ox), Numo::DFloat.cast(oy)]
        end

        # Evenly spaced decimation (see #decimate).
        def decimate_regular(xs, ys, columns)
          n = xs.length
          g = (n.to_f / columns).ceil
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
          xc = xg.mean(axis: 1)
          rising = (yg[true, -1] - yg[true, 0]) >= 0

          first = ymax.dup
          second = ymin.dup
          first[rising] = ymin[rising]
          second[rising] = ymax[rising]

          out_x = Numo::DFloat.zeros(groups, 2)
          out_y = Numo::DFloat.zeros(groups, 2)
          out_x[true, 0] = xc
          out_x[true, 1] = xc
          out_y[true, 0] = first
          out_y[true, 1] = second
          [out_x.flatten, out_y.flatten]
        end

        # True if +xs+ never decreases (NaNs aside).
        def monotonic?(xs)
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
          lone = (finite & ~(finite.concatenate(Numo::Bit[0])[1..]) & ~(Numo::Bit[0].concatenate(finite)[0...-1])).where
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
            marks = starts[1..]
            seg[marks] = 1 if marks.length > 0
            seg = seg.cumsum
            t = (Numo::DFloat.new(total).seq - starts[seg]) / steps[seg]

            sx = x0[seg] + dx[seg] * t
            sy = y0[seg] + dy[seg] * t
            # The last point of the whole line
            px = px.concatenate(sx.round).concatenate(Numo::DFloat[x0[-1] + dx[-1]].round)
            py = py.concatenate(sy.round).concatenate(Numo::DFloat[y0[-1] + dy[-1]].round)
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
        # dash.sum dots along the line.
        def polyline(xs, ys, c, dash: nil)
          ix, iy = Geometry.line_points(xs, ys)
          if dash
            keep = (Numo::Int32.new(ix.length).seq % dash.sum) < dash[0]
            ix = ix[keep]
            iy = iy[keep]
          end
          set(ix, iy, c)
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
    end
  end
end
