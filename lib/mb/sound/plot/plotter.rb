module MB
  module Sound
    module Plot
      # A drop-in replacement for mb-math's MB::M::Plot (the gnuplot pipe)
      # built on Plot charts, with no external process: the same #plot
      # Hash interface, #xrange, #yrange, #logscale, #print, #width,
      # #height, #close, plus #draw for any Chart or Figure.
      #
      #     p = Plot::Plotter.terminal
      #     p.plot({ 'sine' => 100.hz.sample(480), 'pairs' => [[1, 2], [2, 4]] })
      #     p.plot({ 'surface' => Numo::SFloat.new(20, 40).rand })  # 2D data as a heatmap
      #
      # Text plots are printed (or returned as lines when #print is false
      # or +print: false+ is given).  A graphical plotter shows inline
      # images when the terminal supports them (Terminal.image_protocol),
      # else text.
      class Plotter
        # The default plot type of each dataset: 'lines', 'points',
        # 'steps', 'impulses' (stems), 'boxes', 'filledcurves' (area).
        attr_accessor :type

        # If false, #plot returns lines instead of printing them.
        attr_accessor :print

        # Ignored (gnuplot debugging in MB::M::Plot).
        attr_accessor :debug

        # Text look, color mode, and theme (see Plot::Text.render).
        attr_accessor :look, :color, :theme

        # The output IO.
        attr_accessor :io

        # The lines of the last text plot.
        attr_reader :lines

        # A text plotter sized to fractions of the terminal (resized with the
        # terminal unless +width+ or +height+ fixes it; PLOT_WIDTH and
        # PLOT_HEIGHT override).
        def self.terminal(width_fraction: 1.0, height_fraction: 0.5, width: nil, height: nil, **kwargs)
          new(width_fraction: width_fraction, height_fraction: height_fraction, width: width, height: height, **kwargs)
        end

        # An image plotter (+width+ x +height+ pixels).
        def self.graphical(width: nil, height: nil, **kwargs)
          new(graphical: true, width: width, height: height, **kwargs)
        end

        def initialize(graphical: false, width: nil, height: nil, width_fraction: 1.0, height_fraction: 0.5, look: nil, color: nil, theme: nil, io: $stdout, terminal: nil, title: nil, timeout: nil)
          @graphical = graphical || (terminal && terminal != 'dumb')
          @width = width
          @height = height
          @width_fraction = width_fraction
          @height_fraction = height_fraction
          @look = look
          @color = color
          @theme = theme
          @io = io
          @type = nil
          @print = true
          @xrange = nil
          @yrange = nil
          @logscale = false
          @closed = false
          @save = nil
          @lines = nil
        end

        # True for image plots.
        def graphical?
          @graphical
        end

        # Text width in columns (or image width in pixels).
        def width
          return @width || Terminal.pixel_size[0] if @graphical

          env = Terminal.env_int('PLOT_WIDTH')
          return env if env

          ((@width || (MB::U.width - 1)) * (@width ? 1 : @width_fraction)).round.clamp(20, nil)
        end

        # Text height in lines (or image height in pixels).
        def height
          return @height || Terminal.pixel_size[1] if @graphical

          env = Terminal.env_int('PLOT_HEIGHT')
          return env if env

          ((@height || (MB::U.height - 1)) * (@height ? 1 : @height_fraction)).round.clamp(5, nil)
        end

        # Sets the x range of following plots (nil, nil to fit the data).
        def xrange(min, max, keep = true)
          @xrange = min.nil? || max.nil? ? nil : [min, max] if keep
        end

        # Sets the y range of following plots (nil, nil to fit the data).
        def yrange(min, max, keep = true)
          @yrange = min.nil? || max.nil? ? nil : [min, max] if keep
        end

        # Turns a logarithmic x axis on or off for following plots.
        def logscale(enabled = true)
          @logscale = enabled
        end

        # Saves the next plot to +filename+ (.svg, .png, .txt, .ans, .html)
        # instead of showing it.
        def save_image(filename, width: 1080, height: 1080)
          @save = [filename, width, height]
        end

        # Not supported: there is no gnuplot here.  Use #plot, #draw, or the
        # Plot chart API.
        def command(cmd)
          raise PlotError, "gnuplot commands aren't supported by MB::Sound::Plot (got #{cmd.inspect}); build a chart with MB::Sound::Plot.chart instead"
        end

        def close
          @closed = true
        end

        def closed?
          @closed
        end

        # Plots a Hash of titles to data (or Hashes with :data and the
        # options of MB::M::Plot#plot: :xrange, :yrange, :logscale, :type,
        # :x_label, :y_label) as a grid of charts, +columns+ wide.  Prints
        # text plots and returns nil, or returns the lines with +print:
        # false+ (or #print false).
        def plot(data, rows: nil, columns: nil, print: true)
          raise PlotError, 'Plotter is closed' if @closed
          raise ArgumentError, 'Data must be a hash mapping graph titles to data.' unless data.is_a?(Hash)

          charts = data.compact.map { |name, info| chart_for(name, info) }
          draw(Figure.new(charts, rows: rows, columns: columns), print: print)
        end

        # Shows +figure+ (a Chart or Figure): saves it if #save_image was
        # called, shows an image if graphical and supported, else prints
        # its text (or returns the lines; see #plot).
        def draw(figure, print: true)
          figure = figure.figure
          if @save
            path, w, h = @save
            @save = nil
            figure.save(path, **(File.extname(path) =~ /\.(svg|png)\z/i ? { width: w, height: h } : { width: width, height: height }))
            return nil
          end

          if @graphical && (proto = Terminal.image_protocol)
            img = Image.render(figure, width: width, height: height, theme: @theme || :studio)
            @io.write(Terminal.image_escape(img, proto, columns: Terminal.width))
            @io.write("\n")
            return nil
          end

          w = @graphical ? Terminal.width : width
          h = @graphical ? [Terminal.height - 2, 10].max : height
          @lines = Text.render(figure, width: w, height: h, look: @look, color: @color, theme: @theme)
          if @print && print
            @io.write(@lines.join("\n") << "\n")
            nil
          else
            @lines
          end
        end

        private

        def chart_for(name, info)
          info = { data: info } unless info.is_a?(Hash)
          data = info[:data]
          type = (info[:type] || @type || 'lines').to_s
          xr = info[:xrange] || @xrange
          yr = info[:yrange] || @yrange
          log = info.key?(:logscale) ? info[:logscale] : @logscale
          log = @logscale if info[:logscale].nil?

          if data.is_a?(Numo::NArray) && data.ndim == 2
            z = data.respond_to?(:imag) ? data.abs : data
            return Plot.chart(title: name) { |c|
              c.heatmap z, z_scale: info[:zrange] ? Scale::Linear.new(info[:zrange]) : nil
            }
          end

          xs = nil
          ys = data
          if data.is_a?(Array) && !data.empty? && data.all?(Array)
            xs = data.map { |v| v[0].is_a?(Complex) ? v[0].abs : v[0] }
            ys = data.map { |v| v[1].is_a?(Complex) ? v[1].abs : v[1] }
          end
          ys = Mark.array(ys)
          xs = xs && Mark.array(xs)

          xscale =
            if log
              Scale::Log.new(xr && [[xr[0].to_f, 1e-9].max, xr[1]], label: info[:x_label])
            else
              Scale::Linear.new(xr, label: info[:x_label], nice: false)
            end
          yscale = Scale::Linear.new(yr && (yr[0] == yr[1] ? [yr[0] - 1, yr[1] + 1] : yr), label: info[:y_label])

          Plot.chart(title: name, x: xscale, y: yscale) { |c|
            opts = { x: xs }
            case type
            when 'points', 'dots' then c.points(ys, **opts)
            when /steps/ then c.step(ys, **opts)
            when 'impulses', 'boxes' then c.stems(ys, **opts)
            when /filled/ then c.area(ys, **opts)
            else c.line(ys, **opts)
            end
          }
        end
      end
    end
  end
end
