module MB
  module Sound
    module Plot
      # SVG output (pure Ruby): the pixel layout (PixelLayout) drawn as SVG
      # elements, heatmaps embedded as PNG images, each series with a
      # <title> tooltip naming it.
      module SVG
        # Renders +figure+ as an SVG document String +width+ x +height+
        # pixels in +theme+ (:paper, :studio, :phosphor, or a Theme).
        def self.render(figure, width: 960, height: 540, theme: :paper)
          theme = Theme[theme]
          painter = Painter.new(width, height, theme)
          PixelLayout.new(painter, theme).render(figure.figure, width, height)
          painter.document
        end

        # Escapes text for XML.
        def self.escape(s)
          s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
        end

        # Formats a coordinate.
        def self.n(v)
          r = v.round(1)
          r == r.to_i ? r.to_i.to_s : r.to_s
        end

        # Collects SVG elements (see PixelLayout for the painter protocol).
        class Painter
          def initialize(width, height, theme)
            @width = width
            @height = height
            @theme = theme
            @out = []
            @defs = []
            @clip = 0
          end

          def rect(x, y, w, h, color, opacity: 1)
            @out << %(<rect x="#{SVG.n(x)}" y="#{SVG.n(y)}" width="#{SVG.n(w)}" height="#{SVG.n(h)}" fill="#{Color.hex(color)}"#{%( fill-opacity="#{opacity}") if opacity != 1}/>)
          end

          def line(x1, y1, x2, y2, color, width: 1, dash: nil)
            # Crisp 1-pixel lines on pixel centers
            if width <= 1
              x1 = x2 = x1.floor + 0.5 if x1 == x2
              y1 = y2 = y1.floor + 0.5 if y1 == y2
            end
            @out << %(<line x1="#{SVG.n(x1)}" y1="#{SVG.n(y1)}" x2="#{SVG.n(x2)}" y2="#{SVG.n(y2)}" stroke="#{Color.hex(color)}" stroke-width="#{SVG.n(width)}"#{%( stroke-dasharray="#{dash.join(' ')}") if dash}/>)
          end

          def text(x, y, str, color, size:, anchor: :start, bold: false)
            a = { start: 'start', middle: 'middle', end: 'end' }.fetch(anchor)
            @out << %(<text x="#{SVG.n(x)}" y="#{SVG.n(y)}" font-size="#{size}"#{%( text-anchor="#{a}") if a != 'start'}#{' font-weight="600"' if bold} fill="#{Color.hex(color)}">#{SVG.escape(str)}</text>)
          end

          # An estimate (SVG text isn't measured): 0.6 em per character.
          def text_width(str, size)
            str.to_s.length * size * 0.6
          end

          def plot(x, y, w, h)
            @clip += 1
            id = "plot#{@clip}"
            @defs << %(<clipPath id="#{id}"><rect x="-2" y="-2" width="#{SVG.n(w + 4)}" height="#{SVG.n(h + 4)}"/></clipPath>)
            @out << %(<g transform="translate(#{SVG.n(x)} #{SVG.n(y)})" clip-path="url(##{id})">)
            yield Surface.new(w, h, @theme, @out)
            @out << '</g>'
          end

          def document
            bg = @theme.background ? %(<rect width="100%" height="100%" fill="#{Color.hex(@theme.background)}"/>) : ''
            glow = @theme.glow ? '<filter id="glow" x="-5%" y="-5%" width="110%" height="110%"><feGaussianBlur stdDeviation="2.2" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>' : ''
            font = SVG.escape(@theme.font)
            <<~SVG
              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@width} #{@height}" width="#{@width}" height="#{@height}" font-family="#{font}">
              <defs>#{glow}#{@defs.join}</defs>
              #{bg}
              #{@out.join("\n")}
              </svg>
            SVG
          end
        end

        # The mark surface for one plot area (device units are pixels).
        class Surface
          attr_reader :width, :height
          attr_writer :label

          def initialize(width, height, theme, out)
            @width = width
            @height = height
            @theme = theme
            @out = out
            @label = nil
          end

          def polyline(xs, ys, rgb, dash: nil, grid: false)
            d = path(xs, ys)
            return if d.empty?

            w = grid ? 1 : 1.6
            filter = @theme.glow && !grid ? ' filter="url(#glow)"' : ''
            @out << %(<path d="#{d}" fill="none" stroke="#{Color.hex(rgb)}" stroke-width="#{w}" stroke-linejoin="round" stroke-linecap="round"#{%( stroke-dasharray="#{dash.join(' ')}") if dash}#{filter}>#{title}</path>)
          end

          def points(xs, ys, rgb)
            xs = xs.to_a
            ys = ys.to_a
            r = xs.length > 2000 ? 1 : 2.4
            dots = xs.zip(ys).select { |x, y| x.finite? && y.finite? }.map { |x, y| "M#{SVG.n(x - r)} #{SVG.n(y)}a#{r} #{r} 0 1 0 #{SVG.n(2 * r)} 0a#{r} #{r} 0 1 0 #{SVG.n(-2 * r)} 0" }
            @out << %(<path d="#{dots.join}" fill="#{Color.hex(rgb)}">#{title}</path>)
          end

          def area(xs, ys, base, rgb)
            pts = finite_pairs(xs, ys)
            return if pts.empty?

            fill = "M#{SVG.n(pts[0][0])} #{SVG.n(base)}" + pts.map { |x, y| "L#{SVG.n(x)} #{SVG.n(y)}" }.join + "L#{SVG.n(pts[-1][0])} #{SVG.n(base)}Z"
            @out << %(<path d="#{fill}" fill="#{Color.hex(rgb)}" fill-opacity="0.22" stroke="none"/>)
            polyline(xs, ys, rgb)
          end

          def band(xs, lo, hi, rgb)
            a = finite_pairs(xs, lo)
            b = finite_pairs(xs, hi)
            return if a.empty? || b.empty?

            d = 'M' + a.map { |x, y| "#{SVG.n(x)} #{SVG.n(y)}" }.join('L') + 'L' + b.reverse.map { |x, y| "#{SVG.n(x)} #{SVG.n(y)}" }.join('L') + 'Z'
            @out << %(<path d="#{d}" fill="#{Color.hex(rgb)}" fill-opacity="0.75" stroke="#{Color.hex(rgb)}" stroke-width="0.8" stroke-linejoin="round">#{title}</path>)
          end

          # Heatmaps are sampled at up to 600 x 300 and scaled by the viewer
          def image_grid
            [[@width.round, 600].min, [@height.round, 300].min]
          end

          def image(ids, colormap)
            h, w = ids.shape
            rgb = Image.colorize(ids, colormap.colors, @theme.background || [0, 0, 0])
            png = Image.encode_png(rgb)
            @out << %(<image x="0" y="0" width="#{SVG.n(@width)}" height="#{SVG.n(@height)}" preserveAspectRatio="none" image-rendering="optimizeQuality" href="data:image/png;base64,#{[png].pack('m0')}"/>)
          end

          private

          def title
            @label ? "<title>#{SVG.escape(@label)}</title>" : ''
          end

          def finite_pairs(xs, ys)
            xs.to_a.zip(ys.to_a).select { |x, y| x.finite? && y.finite? }
          end

          # Path data with NaN gaps
          def path(xs, ys)
            out = +''
            pen = false
            xs.to_a.zip(ys.to_a).each do |x, y|
              if x.finite? && y.finite?
                out << (pen ? 'L' : 'M') << SVG.n(x) << ' ' << SVG.n(y)
                pen = true
              else
                pen = false
              end
            end
            out
          end
        end
      end
    end
  end
end
