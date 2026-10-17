module MB
  module Sound
    # Command-line interface methods related to plotting sounds.  MB::Sound
    # extends itself with this module.  Plots are drawn by MB::Sound::Plot
    # (pure Ruby: terminal text, SVG, PNG, inline terminal images); no
    # gnuplot process is involved.
    module PlotMethods
      # Returns a terminal text plotter (MB::Sound::Plot::Plotter, sized to
      # 80% of the terminal's height) if +graphical+ is false, or an image
      # plotter (inline terminal images where supported, else text) if
      # +graphical+ is true.  +kwargs+ go to the plotter's constructor the
      # first time (e.g. +width+, +height+, +look+, +theme+).
      #
      # Overriding this method to return some other object with the same
      # #plot interface as MB::M::Plot allows other plotting systems to be
      # used by the CLI DSL (methods that build charts call #draw when the
      # plotter has it).
      def plotter(graphical: false, **kwargs)
        Internal.plotter(graphical: graphical, **kwargs)
      end

      # Builds a chart from a block (see MB::Sound::Plot.chart and
      # Plot::ChartBuilder): returns a Plot::Chart, which shows itself when
      # the console prints it, and has #show, #to_s, #to_svg, #save.
      #
      #     chart { x :time, sample_rate: 48000; line 110.hz.ramp.sample(4800), label: 'saw' }
      #     chart(title: 'Saw') { |c| c.line wave }.save('saw.svg')
      def chart(**kwargs, &block)
        Plot.chart(**kwargs, &block)
      end

      # Lays out charts in a grid (see MB::Sound::Plot.figure).
      #
      #     figure(columns: 2) { chart { line a }; chart { line b } }
      def figure(*charts, **kwargs, &block)
        Plot.figure(*charts, **kwargs, &block)
      end

      # Plots a spectrogram of a sound file, tone, graph node, or data
      # (log frequency with note names, levels in dB through a colormap,
      # with a colorbar).  Tones and graph nodes are sampled for +seconds+.
      # Other keywords go to MB::Sound::Plot.spectrogram (+fft:+, +hop:+,
      # +floor:+, +log:+, +colormap:+).  Prints the plot (or returns its
      # lines if the plotter's #print is off).
      def spectrogram(sound, seconds: 2, sample_rate: 48000, graphical: false, title: nil, **kwargs)
        data =
          case sound
          when String then read(sound)
          when Tone, Pitch, GraphNode then sound.sample((seconds * sample_rate).round)
          else Internal.any_sound_to_array(sound)
          end
        data = data.map { |c| c.respond_to?(:imag) ? c.real : c } if data.is_a?(Array)
        title ||= sound.is_a?(String) ? File.basename(sound) : 'spectrogram'
        plot_chart(Plot.spectrogram(data, sample_rate: sample_rate, title: title, **kwargs), graphical: graphical)
      end

      # Plots the spectrum of the given data (split into chunks).  This method
      # is for convenience and just calls #plot(..., spectrum: true).
      def spectrum(data, **kwargs)
        plot(data, **kwargs, spectrum: true)
      end

      # Plots time-domain and frequency-domain magnitudes of the given data.
      # Supports plotting filter responses.
      #
      # Frequencies are in Hz (log with note names with +logarithmic+, the
      # default; DC left out) at the filter's sample rate, else
      # +sample_rate+.
      def time_freq(data, graphical: false, time_samples: 800, freq_samples: 2000, time_yrange: nil, freq_yrange: nil, logarithmic: true, columns: nil, sample_rate: 48000)
        data = Internal.any_sound_to_hash(data)

        time = data.map { |label, c|
          c = c.is_a?(Filter) ? c.impulse_response(time_samples) : c
          c = c.abs if c.respond_to?(:imag) # For complex-output filters

          time_samples = c.length if c.length < time_samples
          c = c[0...time_samples] if time_samples < c.length

          [
            "#{label} time",
            {
              data: c,
              yrange: time_yrange || [c.min, c.max],
            }
          ]
        }

        freq = data.map { |label, c|
          case c
          when Filter
            f, scale = spectrum_x(freq_samples, filter_rate(c, sample_rate), log: logarithmic)
            c = c.frequency_response(freq_samples)

          else
            n = [c.length, freq_samples * 2].min
            c = real_fft(c[0...n])
            c /= c.abs.max
            f, scale = spectrum_x(c.length, sample_rate, n: n, log: logarithmic)
          end

          c = c.abs.map { |v| (v != 0 && v.finite?) ? v.to_db : -100 }

          [
            "#{label} freq",
            freq_panel(c, f, scale),
          ]
        }

        freq_min = freq.map { |v| v[1][:data].min }.min
        freq_min = -80 if freq_min < -80
        freq_max = freq.map { |v| v[1][:data].max }.max
        freq_max = 80 if freq_max > 80
        freq_yrange ||= [freq_min, freq_max]
        freq.each do |v|
          v[1][:yrange] = freq_yrange
        end

        # flat_map just removes one level of arrays, namely the ones added by zip
        plotinfo = time.zip(freq).flat_map { |el| el }.to_h

        plotter(graphical: graphical).plot(plotinfo, columns: columns)
      end

      # Plots frequency-domain magnitude and phase of the given data.  Supports
      # plotting filter responses.
      #
      # Frequencies are in Hz (log with note names with +logarithmic+, the
      # default; DC left out) at the filter's sample rate, else
      # +sample_rate+.
      def mag_phase(data, graphical: false, freq_samples: 2000, freq_yrange: nil, logarithmic: true, sample_rate: 48000)
        data = Internal.any_sound_to_hash(data)

        axes = {}
        freq = data.map { |k, c|
          if c.is_a?(Filter)
            axes[k] = spectrum_x(freq_samples, filter_rate(c, sample_rate), log: logarithmic)
            [k, c.frequency_response(freq_samples)]
          else
            n = [c.length, freq_samples * 2].min
            r = real_fft(c[0...n])
            axes[k] = spectrum_x(r.length, sample_rate, n: n, log: logarithmic)
            [k, r]
          end
        }.to_h

        mag = freq.map { |label, c|
          [
            "#{label} mag",
            freq_panel(c.abs.map { |v| v != 0 ? v.to_db : -100 }, *axes[label]).merge(yrange: freq_yrange || [-30, 30]),
          ]
        }

        phase = freq.map { |label, c|
          [
            "#{label} phase",
            freq_panel(c.arg, *axes[label]).merge(yrange: [-Math::PI, Math::PI]),
          ]
        }

        # flat_map just removes one level of arrays, namely the ones added by zip
        plotinfo = mag.zip(phase).flat_map { |v| v }.to_h

        plotter(graphical: graphical).plot(plotinfo)
      end

      # Plots a histogram of the given data, centered on 0 and scaled so that
      # the largest dataset's largest values reaches the final histogram bin.
      # If +log+ is true, then a logarithmic histogram is plotted (log(n+1);
      # TODO: not sure if this is how it's supposed to be calculated).
      #
      # With +density+ or +pdf+, plots each dataset's estimated probability
      # density instead (counts / (samples * bin width), over its values on
      # the X axis), across +range+ (a Range of values, default from minus to
      # plus the largest magnitude; values outside are left out), with a
      # theoretical density drawn over it: +pdf+ is a callable taking a
      # value and returning the density, or a Hash of dataset names to
      # callables (or nil), or a Hash of dataset names to Hashes of curve
      # labels to callables for several curves (see #overlay).  E.g. the
      # arcsine distribution of a sine at random phases:
      #
      #     arcsine = ->(x) { x.abs < 1 ? 1 / (Math::PI * Math.sqrt(1 - x * x)) : 0 }
      #     MB::Sound.hist(1.hz.sine.noise.sample(100000), bins: 100, pdf: arcsine)
      def hist(data, bins: 800, log: false, graphical: false, range: nil, density: false, pdf: nil)
        data = Internal.any_sound_to_hash(data)

        dmax = data.values.map { |d| d.abs.max }.max

        return density_plot(data, bins: bins, range: range || (-dmax..dmax), pdf: pdf, graphical: graphical) if density || pdf

        histograms = data.map { |k, d|
          # TODO: Extract this histogram generation into mb-math maybe
          histogram = Numo::DFloat.zeros(bins)

          d.each do |v|
            idx = MB::M.scale(v, -dmax..dmax, 0..(bins - 1)).round
            histogram[idx] += 1
          end

          histogram.inplace.map { |v| Math.log(v + 1) } if log

          [
            k,
            {
              data: histogram,
              x: Numo::DFloat.linspace(-dmax, dmax, bins),
              yrange: [0, histogram.max],
              type: 'steps',
            }
          ]
        }.to_h

        plotter(graphical: graphical).plot(histograms)
      end

      # Estimated probability density of +data+ (an NArray) in +bins+ equal
      # bins across +range+: [bin centers, densities] (DFloats).  Values
      # outside the range (and NaN) are left out of the counts but not of
      # the total, so the densities integrate to the fraction inside.
      def density(data, bins: 100, range: nil)
        data = Numo::DFloat.cast(data)
        data = data.real if data.respond_to?(:real) && !data.is_a?(Numo::DFloat)
        range ||= -data.abs.max..data.abs.max
        lo = range.begin.to_f
        hi = range.end.to_f
        hi = lo + 1 if hi <= lo
        width = (hi - lo) / bins

        idx = ((data - lo) / width).floor
        inside = (data >= lo) & (data <= hi)
        idx = Numo::Int64.cast(idx[inside]).clip(0, bins - 1)
        counts = Numo::DFloat.zeros(bins)
        idx.each { |i| counts[i] += 1 }

        centers = Numo::DFloat.new(bins).seq * width + (lo + width / 2)
        [centers, counts / (data.length * width)]
      end

      # Plots curves on the same axes (ux-1 item 31; maintainer: "`overlay`
      # is a pain to build hash of title to hash to etc"): positional
      # curves, labeled from what they are (a graph's name, else "1",
      # "2", ...), and named ones, labeled by their names.  Each curve is
      # an NArray or Array of numbers (x = 0, 1, ...), [xs, ys], an Array
      # of [x, y] pairs, or a graph or tone (+samples+ of it).  The title
      # is the labels joined with "vs" unless given.  Charts (from
      # #overlay_chart) put side by side make a figure.  +styles+: one
      # style or one per curve ('lines' default, 'steps', 'points',
      # 'impulses', 'filledcurves'); +xrange+ and +yrange+: [lo, hi]
      # (default: the data's, y from 0 when it is never negative).
      #
      #     overlay a, b, c
      #     overlay saw: 220.hz.saw, square: 220.hz.square, samples: 400
      #     overlay overlay_chart(est, theory: t, title: 'sine'), overlay_chart(est2, title: 'noise')
      def overlay(*curves, title: nil, styles: nil, xrange: nil, yrange: nil, samples: 960, graphical: false, columns: nil, **named)
        if !curves.empty? && curves.all? { |c| c.is_a?(Plot::Chart) }
          raise ArgumentError, 'Charts to overlay side by side take no other curves' unless named.empty?
          return plot_chart(Plot.figure(*curves, columns: columns), graphical: graphical)
        end
        plot_chart(overlay_chart(*curves, title: title, styles: styles, xrange: xrange, yrange: yrange, samples: samples, **named), graphical: graphical)
      end

      # The chart #overlay draws (for figures of several: pass them to
      # #overlay together).
      def overlay_chart(*curves, title: nil, styles: nil, xrange: nil, yrange: nil, samples: 960, **named)
        entries = curves.each_with_index.map { |c, i| [overlay_label(c, i), c] } + named.map { |k, v| [k.to_s, v] }
        raise ArgumentError, 'overlay takes curves: overlay a, b or overlay saw: a, square: b' if entries.empty?

        ymin = 0
        ymax = 0
        xs_all = []
        series = entries.each_with_index.map { |(label, data), i|
          xs, ys = overlay_arrays(data, samples)
          finite = ys[ys.isfinite]
          if finite.length > 0
            ymax = [ymax, finite.max].max
            ymin = [ymin, finite.min].min
          end
          xs_all << xs.min << xs.max if xs.length > 0
          style = styles.is_a?(Array) ? styles[i] : styles
          [label, xs, ys, (style || 'lines').to_s]
        }

        xr = xrange || [xs_all.min || 0, xs_all.max || 1]
        pad = (ymax - ymin) * 0.05
        yr = yrange || [ymin < 0 ? ymin - pad : 0, ymax > 0 ? ymax + pad : (ymin < 0 ? 0 : 1)]
        Plot.chart(title: (title || entries.map(&:first).join(' vs ')).to_s, x: Plot::Scale::Linear.new(xr, nice: false), y: Plot::Scale::Linear.new(yr), legend: entries.length > 1 || !named.empty?) { |c|
          series.each do |label, xs, ys, style|
            case style
            when /steps/ then c.step(ys, x: xs, label: label)
            when 'points', 'dots' then c.points(ys, x: xs, label: label)
            when 'impulses', 'boxes' then c.stems(ys, x: xs, label: label)
            when /filled/ then c.area(ys, x: xs, label: label)
            else c.line(ys, x: xs, label: label)
            end
          end
        }
      end

      # A label for positional curve +c+ (number +i+ from 0).
      private def overlay_label(c, i)
        if c.is_a?(GraphNode) && c.respond_to?(:graph_node_name) && c.graph_node_name
          c.graph_node_name.to_s
        elsif c.is_a?(Tone) || c.is_a?(Pitch)
          c.to_s
        else
          (i + 1).to_s
        end
      end

      # Plots estimated densities of +data+ (a Hash of names to NArrays) with
      # theoretical densities from +pdf+ (see #hist).
      private def density_plot(data, bins:, range:, pdf:, graphical:)
        width = (range.end.to_f - range.begin.to_f) / bins
        fine = Numo::DFloat.new(bins * 4 + 1).seq * (width / 4) + range.begin.to_f

        charts = data.map { |name, d|
          centers, dens = density(d, bins: bins, range: range)
          curves = { 'estimate' => [centers, dens] }

          theory = pdf.is_a?(Hash) ? pdf[name] : pdf
          theory = { 'theory' => theory } if theory.respond_to?(:call)
          theory&.each do |label, f|
            next unless f

            ys = fine.to_a.map { |x| f.call(x).to_f }
            # Clip spikes (e.g. the arcsine's poles) to keep the estimate visible
            cap = dens.max * 1.5
            ys = Numo::DFloat.cast(ys)
            ys = ys.clip(0, cap) if cap > 0
            curves[label] = [fine, ys]
          end

          overlay_chart(title: name.to_s, xrange: [range.begin, range.end], styles: ['steps'], **curves.transform_keys(&:to_sym))
        }

        overlay(*charts, graphical: graphical)
      end

      # [xs, ys] (Numo::DFloats) for #overlay: from ys (x = 0, 1, ...),
      # [xs, ys], [x, y] pairs, or +samples+ of a graph or tone; non-finite
      # y values are drawn as 0.
      private def overlay_arrays(data, samples = 960)
        data = data.sample(samples).dup if data.is_a?(GraphNode) && !data.is_a?(Tone)
        data = data.sample(samples).dup if data.is_a?(Tone) || data.is_a?(Pitch)
        if data.is_a?(Array) && data.length == 2 && data.all? { |d| d.is_a?(Numo::NArray) || (d.is_a?(Array) && !d[0].is_a?(Array)) } && data[0].length == data[1].length && data[0].length != 2
          xs, ys = data
        elsif data.is_a?(Numo::NArray) || (data.is_a?(Array) && data.all?(Numeric))
          ys = data
          xs = Numo::DFloat.new(ys.length).seq
        else
          pairs = data.to_a
          xs = pairs.map(&:first)
          ys = pairs.map(&:last)
        end
        xs = Numo::DFloat.cast(xs)
        ys = Numo::DFloat.cast(ys)
        ys[~ys.isfinite] = 0
        [xs, ys]
      end

      # Shows a Plot chart or figure through the plotter (or returns its
      # lines when the plotter's print is off).
      private def plot_chart(chart, graphical: false)
        p = plotter(graphical: graphical)
        if p.respond_to?(:draw)
          p.draw(chart)
        else
          chart.show
        end
      end

      # Plots a subset of the given audio file, test tone, or data, starting at
      # +offset+, and plotting the following +samples+ samples.  If +all+ is true
      # then the entirety of the file, tone, or data will be plotted in slices of
      # +samples+ samples.
      #
      # With +spectrum+, plots each slice's spectrum in dB over frequency in
      # Hz (log, with note names, like Plot.spectrum; DC left out) at
      # +sample_rate+ (the tone's or node's rate, else 48 kHz).
      def plot(file_tone_data, samples: 960, offset: 0, all: false, graphical: false, spectrum: false, sample_rate: nil)
        # FIXME: This function is hard to read
        sample_rate ||= file_tone_data.respond_to?(:sample_rate) && !file_tone_data.is_a?(Filter) ? file_tone_data.sample_rate : 48000
        STDOUT.write("\e[H\e[2J") if all == true

        if all == true || all == false
          if file_tone_data.is_a?(GraphNode)
            header = "\e[36mPlotting #{file_tone_data}\e[0m"
          else
            header = "\e[36mPlotting #{MB::U.highlight(file_tone_data)}\e[0m"
          end
          header_lines = header.lines.count
          puts header
        end

        case file_tone_data
        when Array, Numo::NArray
          if file_tone_data.is_a?(Array)
            data = file_tone_data.map { |d|
              if d.respond_to?(:call)
                # TODO: could this be moved into any_sound_to_array?
                Numo::SFloat.linspace(-10, 10, samples).map { |v| d.call(v) }
              else
                d
              end
            }
          else
            data = file_tone_data
          end

          data = Internal.any_sound_to_array(data)

        when String
          # TODO: Read speaker names
          data = read(file_tone_data, max_frames: all ? nil : samples + offset)

        when Tone, Pitch
          data = [file_tone_data.sample(all ? file_tone_data.sample_rate.round : samples + offset)]

        when Filter
          impulse = file_tone_data.impulse_response(samples)
          freq = file_tone_data.frequency_response(samples)
          data = [impulse, freq.abs, unwrap_phase(freq)].flatten

        when GraphNode
          data = [file_tone_data.sample(samples)]

        when Proc, Method
          data = [Numo::SFloat.linspace(-10, 10, samples).map { |v| file_tone_data.call(v) }]

        else
          raise "Cannot plot type #{file_tone_data.class.name}"
        end

        data = data.flat_map { |d|
          # TODO: better ways of plotting complex-valued data and choosing between real/imag or abs/arg
          if d.is_a?(Numo::SComplex) || d.is_a?(Numo::DComplex)
            [d.real, d.imag]
          else
            [d]
          end
        }

        p = plotter(graphical: graphical)

        if all == true
          t = MB::U.clock_now

          result = nil

          d0len = offset_length(data[0])
          until offset >= d0len
            STDOUT.write("\e[#{header_lines}H\e[36mPress Ctrl-C to stop  \e[1;35m#{offset} / #{d0len}\e[0m\e[K\n")

            if spectrum
              p.yrange(-80, 0) if p.respond_to?(:yrange)
            else
              p.yrange(data.map(&:min).min, data.map(&:max).max) if p.respond_to?(:yrange)
            end

            result = plot(data, samples: samples, offset: offset, all: nil, graphical: graphical, spectrum: spectrum, sample_rate: sample_rate)

            now = MB::U.clock_now
            elapsed = [now - t, 0.1].min
            t = now

            # Files and arrays are read at 48 kHz; graph nodes have their own rate
            offset += elapsed * (file_tone_data.respond_to?(:sample_rate) ? file_tone_data.sample_rate : 48000)

            STDOUT.flush
            sleep 0.02
          end

          result if p.respond_to?(:print) && !p.print

        else
          data = data.map { |c|
            range = offset...([offset + samples, offset_length(c)].min)

            if c.is_a?(Numo::NArray) && c.ndim == 2
              c = c[nil, range]
            else
              c = c[range]
            end

            c || []
          }

          p.logscale(false) if p.respond_to?(:logscale)
          axes = nil
          if spectrum
            # Hz on a log axis with note names (DC left out), like Plot.spectrum
            axes = data.map { |c| spectrum_x(c.length / 2 + 1, sample_rate, n: c.length) }
            data = data.map.with_index { |c, idx|
              d = MB::Sound.real_fft(c).abs.map(&:to_db).clip(-80, 80)
              axes[idx][1] ? d[1..] : d
            }
          end

          ymin = data.map(&:min).min
          ymax = data.map(&:max).max
          ymax = ymin + 1 if ymax == ymin
          p.yrange(ymin, ymax) if p.respond_to?(:yrange) && !all.nil?

          @lines = p.plot(
            data.map.with_index { |c, idx|
              yrange = [0, c.shape[0]] if c.is_a?(Numo::NArray) && c.ndim == 2
              yrange = [0, 1] if yrange == [0, 0]
              info = { data: c, yrange: yrange }
              info.merge!(x: axes[idx][0][1..], x_scale: axes[idx][1]) if axes && axes[idx][1]
              [idx.to_s, info]
            }.to_h,
            print: false
          )
          puts @lines if p.respond_to?(:print) && p.print

          @lines if p.respond_to?(:print) && !p.print
        end

      ensure
        if all == true
          if graphical
            Internal.close_plotter(text: false)

          elsif (pt = Internal.text_plotter).respond_to?(:height)
            puts "\e[#{pt.height + (header_lines || 2) + 2}H"
          end
        end
      end

      # Prints a table of values for the given +data+ source, which may be a
      # Numo::NArray, a callable Proc or Method, an Array thereof, or a Hash
      # with labels pointing to Numo::NArrays or Procs.
      #
      # For a Numo::NArray, +:steps+ elements (or steps.length elements if
      # +:steps+ is an Array) are taken from the array and associated with a
      # linearly mapped value from the +:range+ for display.
      #
      # For a callable Method or Proc, the +:range+ is divided into +:steps+
      # equally spaced steps (or +:steps+ is used directly if it is an Array),
      # and each step is passed to the callable.
      #
      # TODO: Maybe this should be in mb-math.
      #
      # Example:
      #
      #     table([Math.method(:acos), Math.method(:asin)], range: -1..1, steps: 21)
      #
      #          #     |  0: acos  |  1: asin
      #     -----------+-----------+-----------
      #     -1.0       | 3.14159   |-1.5708
      #     -0.9       | 2.69057   |-1.11977
      #     -0.8       | 2.49809   |-0.927295
      #     -0.7       | 2.34619   |-0.775397
      #     -0.6       | 2.2143    |-0.643501
      #     -0.5       | 2.0944    |-0.523599
      #     -0.4       | 1.98231   |-0.411517
      #     -0.3       | 1.87549   |-0.304693
      #     -0.2       | 1.77215   |-0.201358
      #     -0.1       | 1.67096   |-0.100167
      #      0.0       | 1.5708    | 0.0
      #      0.1       | 1.47063   | 0.100167
      #      0.2       | 1.36944   | 0.201358
      #      0.3       | 1.2661    | 0.304693
      #      0.4       | 1.15928   | 0.411517
      #      0.5       | 1.0472    | 0.523599
      #      0.6       | 0.927295  | 0.643501
      #      0.7       | 0.795399  | 0.775397
      #      0.8       | 0.643501  | 0.927295
      #      0.9       | 0.451027  | 1.11977
      #      1.0       | 0.0       | 1.5708
      def table(data, range: -1..1, steps: 21)
        # Gradually coerce any incoming data type into a Hash of callable or NArray
        data = Numo::NArray.cast(data) if Internal.is_numeric_array?(data)
        data = [data] unless data.is_a?(Array) || data.is_a?(Hash)
        data = data.map.with_index { |v, idx| [table_key(v, idx), v] }.to_h if data.is_a?(Array)

        steps = Numo::DFloat.linspace(range.begin, range.end, steps) unless steps.respond_to?(:map)
        steps = steps.to_a

        results = [steps.to_a] + data.map { |k, v|
          evaluate(v, range: range, steps: steps)
        }
        results = results.transpose.map { |a|
          a.map { |v|
            v.is_a?(Numeric) ? MB::M.sigfigs(v, 6) : v
          }
        }

        Table.new(results, header: ['#'] + data.keys).print
      end

      private

      # The frequencies in Hz of +count+ spectrum points from 0 Hz (an FFT
      # of +n+ samples, spaced +rate+ / +n+; without +n+, a filter
      # response's points from 0 to Nyquist) and the x Scale to plot them
      # on: log with note names like Plot.spectrum's (from the first
      # nonzero frequency), or linear Hz with +log: false+.  The Scale is
      # nil for fewer than two points.
      def spectrum_x(count, rate, n: nil, log: true)
        rate = rate.to_f
        step = n ? rate / n : (count > 1 ? rate / 2 / (count - 1) : 0)
        f = Numo::DFloat.new(count).seq * step
        return [f, nil] if count < 2 || f[-1] <= 0

        scale = log ? Plot::Scale::Frequency.new([f[1], f[-1]], notes: true) : Plot::Scale::Linear.new([0.0, f[-1]], label: 'frequency', unit: 'Hz', nice: false)
        [f, scale]
      end

      # The sample rate of filter +f+, else +default+.
      def filter_rate(f, default)
        f.respond_to?(:sample_rate) && f.sample_rate ? f.sample_rate : default
      end

      # A Plotter panel of +data+ over frequencies +f+ on +scale+ (see
      # #spectrum_x; the 0 Hz point is left out of log scales).
      def freq_panel(data, f, scale)
        return { data: data, x_label: 'f' } unless scale
        skip = scale.is_a?(Plot::Scale::Log) ? 1 : 0
        { data: data[skip..], x: f[skip...data.length], x_scale: scale }
      end

      # Used by #table to generate table entries for the given +data+.
      def evaluate(data, range:, steps:, try_convert: true)
        if data.respond_to?(:call)
          steps.map { |s| data.call(s) }
        elsif data.respond_to?(:[]) && !data.is_a?(Numeric)
          steps.map { |s|
            idx = MB::M.scale(s.real, range, 0..(data.length - 1))
            idx = 0 if idx < 0
            idx = data.length - 1 if idx > data.length - 1
            data[idx]
          }
        elsif try_convert
          evaluate(Internal.convert_sound_to_narray(data), range: range, steps: steps, try_convert: false)
        else
          raise "Don't know how to evaluate #{data.class} data"
        end
      end

      def table_key(value, index)
        case value
        when Method, Class
          "#{index}: #{value.name}"

        when Proc
          "#{index}: Proc"

        else
          index.to_s
        end
      end

      # Used for calculating the length of data for subset/offset in #plot.
      def offset_length(data)
        case
        when data.is_a?(Numo::NArray) && data.ndim == 2
          data.shape[1]

        else
          data.length
        end
      end
    end
  end
end
