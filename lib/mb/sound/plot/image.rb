require 'zlib'
require_relative 'font'

module MB
  module Sound
    module Plot
      # Raster image output in pure Ruby: the pixel layout (PixelLayout)
      # drawn into an RGB pixel buffer with antialiased lines and a bitmap
      # font (Plot::Image::Font), encoded as PNG (Zlib from Ruby's standard
      # library), or shown inline in terminals as sixel, kitty, or iTerm2
      # images (see Terminal.image_escape).
      #
      # PNG is encoded here rather than by ffmpeg so that images need no
      # external process, render the same everywhere, and feed the inline
      # terminal protocols (which need pixels, not SVG).
      module Image
        module_function

        # Renders +figure+ into a Canvas of +width+ x +height+ pixels.
        def render(figure, width: 960, height: 540, theme: :studio)
          theme = Theme[theme]
          canvas = Canvas.new(width, height, theme.background || [0, 0, 0])
          PixelLayout.new(Painter.new(canvas, theme), theme).render(figure.figure, width, height)
          canvas
        end

        # PNG bytes for +rgb+ (Numo::UInt8, height x width x 3).
        def encode_png(rgb)
          h, w, = rgb.shape
          raw = Numo::UInt8.zeros(h, w * 3 + 1)
          raw[true, 1..] = rgb.reshape(h, w * 3)
          chunk = ->(type, data) {
            [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N')
          }
          "\x89PNG\r\n\x1a\n".b +
            chunk.('IHDR', [w, h, 8, 2, 0, 0, 0].pack('NNCCCCC')) +
            chunk.('IDAT', Zlib::Deflate.deflate(raw.to_binary, 6)) +
            chunk.('IEND', ''.b)
        end

        # RGB pixels (Numo::UInt8, h x w x 3) for colormap indexes +ids+
        # (-1 shows +background+).
        def colorize(ids, colors, background)
          h, w = ids.shape
          table = Numo::UInt8.cast(colors + [background])
          idx = ids.dup
          idx[idx < 0] = colors.length
          table[idx.flatten, true].reshape(h, w, 3)
        end

        # An RGB pixel buffer (Floats 0..255) with blending primitives.
        class Canvas
          attr_reader :width, :height

          def initialize(width, height, background)
            @width = width
            @height = height
            @px = Numo::DFloat.zeros(height, width, 3)
            3.times { |k| @px[true, true, k] = background[k] }
          end

          # The pixels as Numo::UInt8 (height x width x 3).
          def rgb
            Numo::UInt8.cast(@px.round.clip(0, 255))
          end

          # PNG bytes.
          def to_png
            Image.encode_png(rgb)
          end

          # Writes a PNG file.
          def save(path)
            File.binwrite(path, to_png)
            path
          end

          # Blends +color+ over the region at (+x+, +y+) by +alpha+
          # (Numo::DFloat, rows x cols, 0..1), clipped to the canvas.
          def blend(x, y, alpha, color)
            h, w = alpha.shape
            x0 = [x, 0].max
            y0 = [y, 0].max
            x1 = [x + w, @width].min
            y1 = [y + h, @height].min
            return if x1 <= x0 || y1 <= y0

            a = alpha[(y0 - y)...(y1 - y), (x0 - x)...(x1 - x)]
            3.times do |k|
              region = @px[y0...y1, x0...x1, k]
              @px[y0...y1, x0...x1, k] = region + (color[k] - region) * a
            end
          end

          # Copies +rgb+ pixels (h x w x 3) where +mask+ (Numo::Bit) is set
          # to the region at (+x+, +y+).
          def paint(x, y, rgb, mask)
            h, w = mask.shape
            a = Numo::DFloat.cast(mask).reshape(h, w, 1)
            region = @px[y...(y + h), x...(x + w), true]
            @px[y...(y + h), x...(x + w), true] = Numo::DFloat.cast(rgb) * a + region * (1 - a)
          end

          # Fills a rectangle (fractional edges are antialiased).
          def rect(x, y, w, h, color, opacity = 1.0)
            x0 = x.floor
            y0 = y.floor
            x1 = (x + w).ceil
            y1 = (y + h).ceil
            return if x1 <= x0 || y1 <= y0

            cols = Numo::DFloat.new(x1 - x0).seq + x0
            rows = Numo::DFloat.new(y1 - y0).seq + y0
            cx = (Numo::DFloat.minimum(cols + 1, x + w) - Numo::DFloat.maximum(cols, x)).clip(0, 1)
            cy = (Numo::DFloat.minimum(rows + 1, y + h) - Numo::DFloat.maximum(rows, y)).clip(0, 1)
            blend(x0, y0, cy.reshape(y1 - y0, 1) * cx.reshape(1, x1 - x0) * opacity, color)
          end

          # Coverage (Numo::DFloat, height x width) of a polyline +width+
          # pixels wide, antialiased by splatting samples every 0.25 px.
          def line_coverage(xs, ys, width: 1.5)
            sx, sy = samples(xs, ys, 0.25)
            cov = Numo::DFloat.zeros(@height * @width)
            return cov.reshape(@height, @width) if sx.length == 0

            r = width / 2.0
            offsets = r <= 0.75 ? [[0, 0]] : [[0, 0], [r - 0.5, 0], [0.5 - r, 0], [0, r - 0.5], [0, 0.5 - r]]
            offsets.each do |ox, oy|
              splat(cov, sx + ox, sy + oy, 1.0 / offsets.length * 0.5)
            end
            cov.reshape(@height, @width).clip(0, 1)
          end

          # Draws a polyline.
          def polyline(xs, ys, color, width: 1.5, opacity: 1.0, dash: nil, glow: false)
            if dash
              # Draw the dashes as separate pieces along the line
              sx, sy = samples(xs, ys, 1.0)
              keep = (Numo::Int32.new(sx.length).seq % dash.sum) < dash[0]
              sx[~keep] = Float::NAN
              xs, ys = sx, sy
            end
            if glow
              blend(0, 0, blur(line_coverage(xs, ys, width: width * 3)) * 0.5 * opacity, color)
            end
            blend(0, 0, line_coverage(xs, ys, width: width) * opacity, color)
          end

          # Filled discs of +radius+.
          def discs(xs, ys, color, radius: 2.0)
            cov = Numo::DFloat.zeros(@height * @width)
            r = radius.ceil
            ((-r)..r).each do |dy|
              ((-r)..r).each do |dx|
                d = Math.sqrt(dx * dx + dy * dy)
                wgt = (radius + 0.5 - d).clamp(0, 1)
                next if wgt <= 0

                splat(cov, xs + dx, ys + dy, wgt, bilinear: false)
              end
            end
            blend(0, 0, cov.reshape(@height, @width).clip(0, 1), color)
          end

          # Text with the bitmap font at (+x+, +y+ baseline), +scale+ times
          # its 12 px size (whole multiples).
          def text(x, y, str, color, bold: false)
            fw = Font::WIDTH
            fh = Font::HEIGHT
            top = (y - 12).round
            x = x.round
            str.to_s.each_char.with_index do |c, i|
              g = Font.alpha(c)
              blend(x + i * fw, top, g, color)
              blend(x + i * fw + 1, top, g * 0.6, color) if bold
            end
          end

          private

          # Points along a polyline every +step+ pixels (NaN gaps kept)
          def samples(xs, ys, step)
            xs = Numo::DFloat.cast(xs) / step
            ys = Numo::DFloat.cast(ys) / step
            ix, iy = Geometry.line_points_f(xs, ys)
            [ix * step, iy * step]
          end

          # Adds +weight+ at each point (bilinear between pixels)
          def splat(cov, xs, ys, weight, bilinear: true)
            ok = xs.isfinite & ys.isfinite & (xs > -1) & (xs < @width) & (ys > -1) & (ys < @height)
            xs = xs[ok]
            ys = ys[ok]
            return if xs.length == 0

            if bilinear
              # Pixel centers are at integer + 0.5
              fx = xs - 0.5
              fy = ys - 0.5
              x0 = fx.floor
              y0 = fy.floor
              tx = fx - x0
              ty = fy - y0
              [[0, 0, (1 - tx) * (1 - ty)], [1, 0, tx * (1 - ty)], [0, 1, (1 - tx) * ty], [1, 1, tx * ty]].each do |ox, oy, w|
                add(cov, x0 + ox, y0 + oy, w * weight)
              end
            else
              add(cov, xs.floor, ys.floor, Numo::DFloat.new(xs.length).fill(weight))
            end
          end

          def add(cov, xs, ys, w)
            ok = (xs >= 0) & (xs < @width) & (ys >= 0) & (ys < @height)
            idx = Numo::Int32.cast(ys[ok] * @width + xs[ok])
            return if idx.length == 0

            sums = idx.bincount(w[ok], minlength: @width * @height)
            cov.inplace + sums
          end

          # A 5x5 box blur
          def blur(a)
            out = a.dup
            2.times do
              b = out.dup
              (1..2).each do |s|
                b[true, s..] += out[true, 0...-s]
                b[true, 0...-s] += out[true, s..]
              end
              out = b / 5
              b = out.dup
              (1..2).each do |s|
                b[s.., true] += out[0...-s, true]
                b[0...-s, true] += out[s.., true]
              end
              out = b / 5
            end
            out
          end
        end

        # The PixelLayout painter for a Canvas.
        class Painter
          def initialize(canvas, theme)
            @c = canvas
            @theme = theme
          end

          def rect(x, y, w, h, color, opacity: 1)
            @c.rect(x, y, w, h, color, opacity)
          end

          def line(x1, y1, x2, y2, color, width: 1, dash: nil)
            if width <= 1 && (x1 == x2 || y1 == y2)
              # Crisp axis-aligned lines
              if x1 == x2
                @c.rect(x1.floor, [y1, y2].min, 1, (y2 - y1).abs.clamp(1, nil), color)
              else
                @c.rect([x1, x2].min, y1.floor, (x2 - x1).abs.clamp(1, nil), 1, color)
              end
            else
              @c.polyline(Numo::DFloat[x1, x2], Numo::DFloat[y1, y2], color, width: width, dash: dash)
            end
          end

          def text(x, y, str, color, size:, anchor: :start, bold: false)
            w = text_width(str, size)
            x -= w if anchor == :end
            x -= w / 2 if anchor == :middle
            @c.text(x, y, str, color, bold: bold)
          end

          def text_width(str, _size)
            str.to_s.length * Font::WIDTH
          end

          def plot(x, y, w, h)
            sub = Surface.new(@c, x.round, y.round, w.round, h.round, @theme)
            yield sub
          end
        end

        # The mark surface for one plot area of a Canvas.
        class Surface
          attr_reader :width, :height

          def initialize(canvas, x, y, w, h, theme)
            @c = canvas
            @x = x
            @y = y
            @width = w
            @height = h
            @theme = theme
          end

          def polyline(xs, ys, rgb, dash: nil, grid: false)
            xs, ys = clip(xs, ys)
            @c.polyline(xs, ys, rgb, width: grid ? 1.0 : 1.6, dash: dash, glow: @theme.glow && !grid)
          end

          def points(xs, ys, rgb)
            xs, ys = clip(xs, ys)
            @c.discs(xs, ys, rgb, radius: xs.length > 2000 ? 0.8 : 2.2)
          end

          def area(xs, ys, base, rgb)
            fill(xs, ys, rgb, 0.25, base: base)
            polyline(xs, ys, rgb)
          end

          def band(xs, lo, hi, rgb)
            fill(xs, lo, rgb, 0.75, hi: hi)
            polyline(xs, lo, rgb)
            polyline(xs, hi, rgb)
          end

          def image_grid
            [@width, @height]
          end

          def image(ids, colormap)
            rgb = Image.colorize(ids, colormap.colors, @theme.background || [0, 0, 0])
            @c.paint(@x, @y, rgb, ids.ge(0))
          end

          private

          def clip(xs, ys)
            [Numo::DFloat.cast(xs) + @x, Numo::DFloat.cast(ys) + @y]
          end

          # Fills under a line (or between it and +hi+) at 1 px resolution
          def fill(xs, ys, rgb, opacity, base: nil, hi: nil)
            r = Raster.new(@width, @height)
            a = r.line_mask(xs, ys)
            if hi
              r.fill_between(a, 1, mask_b: r.line_mask(xs, hi))
            else
              r.fill_between(a, 1, base: base)
            end
            @c.blend(@x, @y, Numo::DFloat.cast(r.dots.gt(0)) * opacity, rgb)
          end
        end

        # Sixel encoding (DEC terminals, xterm -ti vt340, Konsole, foot,
        # WezTerm, mlterm; iTerm2 also reads it).
        module Sixel
          module_function

          # The sixel escape sequence for +rgb+ (Numo::UInt8, h x w x 3),
          # quantized to 6 x 7 x 6 levels (252 colors).
          def encode(rgb)
            h, w, = rgb.shape
            r = Numo::Int32.cast(rgb[true, true, 0]) * 5 / 255
            g = Numo::Int32.cast(rgb[true, true, 1]) * 6 / 255
            b = Numo::Int32.cast(rgb[true, true, 2]) * 5 / 255
            idx = (r * 42 + g * 6 + b).reshape(h, w)

            used = idx.to_a.flatten.uniq.sort
            out = +"\eP0;1;0q\"1;1;#{w};#{h}"
            used.each do |c|
              cr, rest = c.divmod(42)
              cg, cb = rest.divmod(6)
              out << "##{c};2;#{(cr * 100 / 5.0).round};#{(cg * 100 / 6.0).round};#{(cb * 100 / 5.0).round}"
            end

            (0...h).step(6) do |y0|
              band = idx[y0...[y0 + 6, h].min, true]
              rows = band.shape[0]
              colors = band.to_a.flatten.uniq
              colors.each_with_index do |c, ci|
                bits = Numo::Int32.zeros(w)
                rows.times { |k| bits += Numo::Int32.cast(band[k, true].eq(c)) << k }
                out << "##{c}" << rle(bits.to_a)
                out << (ci == colors.length - 1 ? '-' : '$')
              end
            end
            out << "\e\\"
          end

          def rle(bits)
            out = +''
            run = 0
            prev = nil
            bits.each do |v|
              if v == prev
                run += 1
              else
                out << chunk(prev, run) if prev
                prev = v
                run = 1
              end
            end
            out << chunk(prev, run) if prev
            out
          end

          def chunk(v, run)
            c = (63 + v).chr
            run > 3 ? "!#{run}#{c}" : c * run
          end
        end
      end

      module Image
        module Font
          # Glyph alpha (Numo::DFloat HEIGHT x WIDTH, 0..1) for +char+
          # (unknown characters as '?').
          def self.alpha(char)
            @alpha ||= {}
            @alpha[char] ||= begin
              hex = GLYPHS[char] || GLYPHS['?']
              Numo::DFloat.cast(hex.each_char.map { |c| c.hex / 15.0 }).reshape(HEIGHT, WIDTH)
            end
          end
        end
      end

      module Geometry
        module_function

        # Like line_points, but with Float positions (for antialiasing).
        def line_points_f(xs, ys)
          xs = Numo::DFloat.cast(xs)
          ys = Numo::DFloat.cast(ys)
          return [Numo::DFloat[], Numo::DFloat[]] if xs.length < 2

          x0 = xs[0...-1]
          y0 = ys[0...-1]
          dx = xs[1..] - x0
          dy = ys[1..] - y0
          ok = (x0.isfinite & y0.isfinite & dx.isfinite & dy.isfinite).where
          return [Numo::DFloat[], Numo::DFloat[]] if ok.length == 0

          x0 = x0[ok]
          y0 = y0[ok]
          dx = dx[ok]
          dy = dy[ok]
          steps = Numo::Int32.cast(Numo::DFloat.maximum(dx.abs, dy.abs).ceil).clip(1, nil)
          total = steps.sum
          starts = steps.cumsum - steps
          seg = Numo::Int32.zeros(total)
          seg[starts[1..]] = 1 if starts.length > 1
          seg = seg.cumsum
          t = (Numo::DFloat.new(total).seq - starts[seg]) / steps[seg]
          sx = (x0[seg] + dx[seg] * t).concatenate(Numo::DFloat[x0[-1] + dx[-1]])
          sy = (y0[seg] + dy[seg] * t).concatenate(Numo::DFloat[y0[-1] + dy[-1]])
          [sx, sy]
        end
      end
    end
  end
end
