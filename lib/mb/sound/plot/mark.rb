module MB
  module Sound
    module Plot
      # Marks draw data on a renderer's surface.  Each mark keeps its data as
      # Numo::DFloats, reports its extent for fitting scales, and draws
      # through the surface protocol every renderer implements (device
      # units, origin at the top left of the plot area):
      #
      #     surface.width, surface.height
      #     surface.polyline(xs, ys, color, dash: nil)  # NaN breaks the line
      #     surface.points(xs, ys, color)
      #     surface.area(xs, ys, base_y, color)          # filled under a line
      #     surface.band(xs, lo_ys, hi_ys, color)        # filled between lines
      #     surface.image_grid -> [w, h]                 # heatmap pixel grid
      #     surface.image(ids, colormap)                 # h x w colormap indexes (-1 clear)
      #
      # +color+ is [r, g, b]; renderers choose fill opacity and line width.
      module Mark
        # Converts data to a Numo::DFloat (complex data by magnitude).
        def self.array(data)
          return nil if data.nil?

          data = data.to_a if data.is_a?(Range)
          a = data.is_a?(Numo::NArray) ? data : Numo::NArray.cast(data)
          a = a.abs if a.is_a?(Numo::SComplex) || a.is_a?(Numo::DComplex)
          Numo::DFloat.cast(a)
        end

        # True if +surface+ draws smooth vector lines (SVG, images) rather
        # than text cells.
        def self.vector?(surface)
          surface.respond_to?(:vector?) && surface.vector?
        end

        # Shared behavior of every mark.
        class Base
          # The legend label (nil leaves the mark out of the legend).
          attr_reader :label

          # The mark's color: nil (next palette slot), an Integer slot,
          # '#rrggbb', or [r, g, b].
          attr_reader :color

          # Optional dash pattern [on, off] (in dots or pixels).
          attr_reader :dash

          def initialize(label: nil, color: nil, dash: nil)
            @label = label&.to_s
            @color = color
            @dash = dash
          end

          # True if the mark takes a palette slot when it has no color.
          def series?
            true
          end

          # The legend glyph kind: :line, :area, :points, :band, :image.
          def kind
            :line
          end

          # [xlo, xhi, ylo, yhi] of the data valid for the scales (nils if
          # none).
          def extent(xscale, yscale)
            [nil, nil, nil, nil]
          end

          # Draws on +surface+ through +coord+ in color +rgb+.
          def draw(surface, coord, rgb)
            raise NotImplementedError
          end

          private

          def range_of(v, mask)
            v = v[mask]
            return [nil, nil] if v.length == 0

            [v.min, v.max]
          end

          # Device coordinates of data points.
          def device(surface, coord, xs, ys)
            u, v = coord.project(xs, ys)
            [u * (surface.width - 1), (1 - v) * (surface.height - 1)]
          end
        end

        # A series of y values over x values (x defaults to the index; a
        # Range spreads the points evenly over it).
        class XY < Base
          attr_reader :x, :y

          def initialize(y, x: nil, **kwargs)
            super(**kwargs)
            @y = Mark.array(y)
            @regular = x.nil? || x.is_a?(Range)
            @x =
              case x
              when nil then Numo::DFloat.new(@y.length).seq
              when Range then Numo::DFloat.linspace(x.begin.to_f, x.end.to_f, @y.length)
              else Mark.array(x)
              end
            raise ArgumentError, "x has #{@x.length} values and y has #{@y.length}" if @x.length != @y.length
          end

          def extent(xscale, yscale)
            ok = xscale.valid(@x) & yscale.valid(@y)
            range_of(@x, ok) + range_of(@y, ok)
          end

          private

          # Device points, decimated to min/max per column when long and
          # monotonic in x.
          def device_points(surface, coord)
            dx, dy = device(surface, coord, @x, @y)
            if dx.length > surface.width * 2 && !coord.polar? && Geometry.monotonic?(@x)
              regular = @regular && coord.x.linear?
              dx, dy = Geometry.decimate(dx, dy, surface.width, regular: regular, ends: Mark.vector?(surface))
            end
            [dx, dy]
          end

          # Device row of data value +y+ (clamped to the plot area).
          def baseline(surface, coord, base)
            b = base.nil? ? coord.y.invert(0) : base
            _, v = coord.project(Numo::DFloat[coord.x.invert(0)], Numo::DFloat[b])
            v = v[0]
            v = 0 if v.nan?
            ((1 - v.clamp(0, 1)) * (surface.height - 1))
          end
        end

        # A connected line (+step+ draws a staircase: each value holds until
        # the next x).
        class Line < XY
          def initialize(y, step: false, **kwargs)
            super(y, **kwargs)
            @step = step
          end

          def draw(surface, coord, rgb)
            xs, ys = @x, @y
            if @step && xs.length > 1 && xs.length <= surface.width * 2
              xs = Numo::DFloat.cast([xs.to_a, xs.to_a].transpose.flatten[1..] + [xs[-1]])
              ys = Numo::DFloat.cast([ys.to_a, ys.to_a].transpose.flatten)
              dx, dy = device(surface, coord, xs, ys)
            else
              dx, dy = device_points(surface, coord)
            end
            surface.polyline(dx, dy, rgb, dash: @dash)
          end
        end

        # A line filled down (or up) to a +base+ value (default the bottom
        # of the y domain).
        class Area < XY
          def initialize(y, base: nil, **kwargs)
            super(y, **kwargs)
            @base = base
          end

          def kind
            :area
          end

          def draw(surface, coord, rgb)
            dx, dy = device_points(surface, coord)
            surface.area(dx, dy, baseline(surface, coord, @base), rgb)
          end
        end

        # Unconnected points.
        class Points < XY
          def kind
            :points
          end

          def draw(surface, coord, rgb)
            dx, dy = device(surface, coord, @x, @y)
            surface.points(dx, dy, rgb)
          end
        end

        # Vertical lines from a +base+ value (default 0, or the bottom of
        # the domain) to each point: impulse responses, line spectra,
        # histograms.
        class Stems < XY
          def initialize(y, base: 0.0, **kwargs)
            super(y, **kwargs)
            @base = base
          end

          def kind
            :area
          end

          def draw(surface, coord, rgb)
            dx, dy = device(surface, coord, @x, @y)
            base = @base && coord.y.lo <= @base && @base <= coord.y.hi ? @base : nil
            b = baseline(surface, coord, base)
            n = dx.length
            xs = Numo::DFloat.zeros(n, 3)
            ys = Numo::DFloat.zeros(n, 3)
            xs[true, 0] = dx
            xs[true, 1] = dx
            xs[true, 2] = Float::NAN
            ys[true, 0] = b
            ys[true, 1] = dy
            ys[true, 2] = Float::NAN
            surface.polyline(xs.flatten, ys.flatten, rgb)
          end
        end

        # The filled region between +lo+ and +hi+ values (min/max envelopes
        # of decimated waveforms, error bands).
        class Band < Base
          attr_reader :x, :lo, :hi

          def initialize(lo, hi, x: nil, **kwargs)
            super(**kwargs)
            @lo = Mark.array(lo)
            @hi = Mark.array(hi)
            @x = x.nil? ? Numo::DFloat.new(@lo.length).seq : (x.is_a?(Range) ? Numo::DFloat.linspace(x.begin.to_f, x.end.to_f, @lo.length) : Mark.array(x))
          end

          def kind
            :band
          end

          def extent(xscale, yscale)
            ok = xscale.valid(@x) & yscale.valid(@lo) & yscale.valid(@hi)
            xr = range_of(@x, ok)
            lo = range_of(@lo, ok)
            hi = range_of(@hi, ok)
            [xr[0], xr[1], [lo[0], hi[0]].compact.min, [lo[1], hi[1]].compact.max]
          end

          def draw(surface, coord, rgb)
            dx, dlo = device(surface, coord, @x, @lo)
            _, dhi = device(surface, coord, @x, @hi)
            if dx.length > surface.width * 2
              dx2, dlo = Geometry.decimate(dx, dlo, surface.width, ends: Mark.vector?(surface))
              _, dhi = Geometry.decimate(dx, dhi, surface.width, ends: Mark.vector?(surface))
              dx = dx2
            end
            surface.band(dx, dlo, dhi, rgb)
          end
        end

        # A horizontal (+y+) or vertical (+x+) reference line across the
        # plot, in the muted axis color unless given one.
        class Rule < Base
          attr_reader :at, :axis

          def initialize(x: nil, y: nil, **kwargs)
            super(**kwargs)
            raise ArgumentError, 'Pass x: or y: to a rule' if x.nil? == y.nil?

            @axis = x.nil? ? :y : :x
            @at = (x || y).to_f
          end

          def series?
            false
          end

          def draw(surface, coord, rgb)
            if @axis == :y
              v = coord.y.map(@at)
              return unless v.between?(0, 1)

              dy = (1 - v) * (surface.height - 1)
              surface.polyline(Numo::DFloat[0, surface.width - 1], Numo::DFloat[dy, dy], rgb, dash: @dash)
            else
              u = coord.x.map(@at)
              return unless u.between?(0, 1)

              dx = u * (surface.width - 1)
              surface.polyline(Numo::DFloat[dx, dx], Numo::DFloat[0, surface.height - 1], rgb, dash: @dash)
            end
          end
        end

        # A color-mapped grid of values: +z+ is rows (y, the first row at
        # the bottom) by columns (x), spread over +x+ and +y+ (Ranges of
        # data values; default the index ranges).  +z_scale+ maps values
        # to colors (a Scale, default linear over the data; Scale::DB for
        # levels), +colormap+ names the colors (default the theme's).
        class Heatmap < Base
          attr_reader :z, :x_range, :y_range, :z_scale, :colormap

          def initialize(z, x: nil, y: nil, z_scale: nil, colormap: nil, **kwargs)
            super(**kwargs)
            z = Mark.array(z) unless z.is_a?(Numo::DFloat)
            raise ArgumentError, 'Heatmap data must have two dimensions (rows, columns)' unless z.ndim == 2

            @z = z
            rows, cols = z.shape
            @x_range = x ? [x.begin.to_f, x.end.to_f] : [0.0, cols.to_f]
            @y_range = y ? [y.begin.to_f, y.end.to_f] : [0.0, rows.to_f]
            finite = z[z.isfinite]
            zs = Scale.build(z_scale)
            zs = zs.fit(finite.length > 0 ? finite.min : 0.0, finite.length > 0 ? finite.max : 1.0) unless zs.ready?
            @z_scale = zs
            @colormap = colormap
          end

          def series?
            false
          end

          def kind
            :image
          end

          def extent(xscale, yscale)
            xs = Numo::DFloat[*@x_range]
            ys = Numo::DFloat[*@y_range]
            xs = xs[xscale.valid(xs)]
            ys = ys[yscale.valid(ys)]
            [xs.min, xs.max, ys.min, ys.max]
          end

          # The colormap for +theme+.
          def colormap_for(theme)
            Colormap[@colormap || theme.colormap]
          end

          def draw(surface, coord, theme)
            cmap = colormap_for(theme)
            w, h = surface.image_grid
            rows, cols = @z.shape

            u = (Numo::DFloat.new(w).seq + 0.5) / w
            v = 1 - (Numo::DFloat.new(h).seq + 0.5) / h
            xs = coord.x.invert(u)
            ys = coord.y.invert(v)
            ci = ((xs - @x_range[0]) / (@x_range[1] - @x_range[0]) * cols).floor
            ri = ((ys - @y_range[0]) / (@y_range[1] - @y_range[0]) * rows).floor
            ci[~ci.isfinite] = -1
            ri[~ri.isfinite] = -1
            cok = (ci >= 0) & (ci < cols)
            rok = (ri >= 0) & (ri < rows)
            ci = Numo::Int32.cast(ci.clip(0, cols - 1))
            ri = Numo::Int32.cast(ri.clip(0, rows - 1))

            vals = @z[ri, ci] # h x w
            ids = cmap.indexes(@z_scale.map(vals))
            clear = ~(rok.reshape(h, 1) & cok.reshape(1, w))
            ids[clear] = -1
            ids[~vals.isfinite] = -1
            surface.image(ids, cmap)
          end
        end
      end
    end
  end
end
