module MB
  module Sound
    # Command-line interface methods related to plotting sounds.  MB::Sound
    # extends itself with this module.
    module PlotMethods
      # Sets up SIGWINCH (window-size change) handler when MB::Sound extends
      # itself with this module.
      def self.extended(within)
        # Make sure that plotters are resized when the terminal window changes
        # size.
        old_handler = trap :WINCH do
          Thread.new do
            within.reset_plotter
          end

          old_handler.call if old_handler.respond_to?(:call)
        end
      end

      # Called by the SIGWINCH signal handler to resize plots when the terminal
      # window is resized.  Closes any existing plotters and recreates any that
      # previously existed (necessary if SIGWINCH arrives in the middle of a
      # function that is using a plotter through instance variables).
      def reset_plotter
        @pt ||= nil
        @pg ||= nil
        old_pt = @pt
        old_pg = @pg

        @plot_outputs ||= {}
        @plot_outputs.clear

        close_plotter

        plotter(graphical: false) if old_pt
        plotter(graphical: true) if old_pg
      end

      # Closes existing MB::M::Plot plotters without creating new ones.  Useful
      # for cleaning up between tests.
      def close_plotter
        @pt ||= nil
        @pg ||= nil
        @pt&.close
        @pg&.close
        @pt = nil
        @pg = nil
      end

      # Returns either a terminal-based plotting object if +graphical+ is false,
      # or a graphical window-based plotting object if +graphical+ is true.
      #
      # Overriding this method to return some other compatible object allows
      # other plotting systems to be used by the CLI DSL.
      def plotter(graphical: false, **kwargs)
        @pt ||= MB::M::Plot.terminal(height_fraction: 0.8, **kwargs)
        @pg ||= MB::M::Plot.new(**kwargs) if graphical
        graphical ? @pg : @pt
      end

      # Plots the spectrum of the given data (split into chunks).  This method
      # is for convenience and just calls #plot(..., spectrum: true).
      def spectrum(data, **kwargs)
        plot(data, **kwargs, spectrum: true)
      end

      # Plots time-domain and frequency-domain magnitudes of the given data.
      # Supports plotting filter responses.
      def time_freq(data, graphical: false, time_samples: 800, freq_samples: 2000, time_yrange: nil, freq_yrange: nil, logarithmic: true)
        data = any_sound_to_hash(data)

        time = data.map { |label, c|
          c = c.is_a?(Filter) ? c.impulse_response(time_samples) : c

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
            c = c.frequency_response(freq_samples)

          else
            c = real_fft(c[0...([c.length, freq_samples * 2].min)])
            c /= c.abs.max
          end

          c = c.abs.map { |v| (v != 0 && v.finite?) ? v.to_db : -100 }

          [
            "#{label} freq",
            {
              data: c,
              logscale: logarithmic,
              x_label: 'f',
            }
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

        plotter(graphical: graphical).plot(plotinfo)
      end

      # Plots frequency-domain magnitude and phase of the given data.  Supports
      # plotting filter responses.
      def mag_phase(data, graphical: false, freq_samples: 2000, freq_yrange: nil, logarithmic: true)
        data = any_sound_to_hash(data)

        freq = data.map { |k, c|
          [
            k,
            c.is_a?(Filter) ? c.frequency_response(freq_samples) : real_fft(c[0...[c.length, freq_samples * 2].min])
          ]
        }.to_h

        mag = freq.map { |label, c|
          [
            "#{label} mag",
            {
              data: c.abs.map { |v| v != 0 ? v.to_db : -100 },
              logscale: logarithmic,
              x_label: 'f',
              yrange: freq_yrange || [-30, 30],
            }
          ]
        }

        phase = freq.map { |label, c|
          [
            "#{label} phase",
            {
              data: c.arg,
              yrange: [-Math::PI, Math::PI],
              logscale: logarithmic,
              x_label: 'f',
            }
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
      def hist(data, bins: 800, log: false, graphical: false)
        data = any_sound_to_hash(data)

        dmax = data.values.map { |d| d.abs.max }.max

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
              yrange: [0, histogram.max]
            }
          ]
        }.to_h

        plotter(graphical: graphical).plot(histograms)
      end

      # Plots a subset of the given audio file, test tone, or data, starting at
      # +offset+, and plotting the following +samples+ samples.  If +all+ is true
      # then the entirety of the file, tone, or data will be plotted in slices of
      # +samples+ samples.
      def plot(file_tone_data, samples: 960, offset: 0, all: false, graphical: false, spectrum: false)
        # FIXME: This function is hard to read
        STDOUT.write("\e[H\e[2J") if all == true

        if all == true || all == false
          header = "\e[36mPlotting #{MB::U.highlight(file_tone_data)}\e[0m"
          header_lines = header.lines.count
          puts header
        end

        case file_tone_data
        when Array, Numo::NArray
          data = file_tone_data.map { |d|
            if d.respond_to?(:call)
              # TODO: could this be moved into any_sound_to_array?
              Numo::SFloat.linspace(-10, 10, samples).map { |v| d.call(v) }
            else
              d
            end
          }
          data = any_sound_to_array(data)

        when String
          # TODO: Read speaker names
          data = read(file_tone_data, max_frames: all ? nil : samples + offset)

        when Tone
          data = [file_tone_data.generate(all ? nil : samples + offset)]

        when Filter
          data = [file_tone_data.impulse_response, file_tone_data.frequency_response.abs]

        when GraphNode
          data = [file_tone_data.sample(samples)]

        when Proc, Method
          data = [Numo::SFloat.linspace(-10, 10, samples).map { |v| file_tone_data.call(v) }]

        else
          raise "Cannot plot type #{file_tone_data.class.name}"
        end

        p = plotter(graphical: graphical)

        if all == true
          t = MB::U.clock_now

          result = nil

          until offset >= data[0].length
            STDOUT.write("\e[#{header_lines}H\e[36mPress Ctrl-C to stop  \e[1;35m#{offset} / #{data[0].length}\e[0m\e[K\n")

            if spectrum
              p.yrange(-80, 0) if p.respond_to?(:yrange)
            else
              p.yrange(data.map(&:min).min, data.map(&:max).max) if p.respond_to?(:yrange)
            end

            result = plot(data, samples: samples, offset: offset, all: nil, graphical: graphical, spectrum: spectrum)

            now = MB::U.clock_now
            elapsed = [now - t, 0.1].min
            t = now

            offset += elapsed * 48000

            STDOUT.flush
            sleep 0.02
          end

          result if p.respond_to?(:print) && !p.print
        else
          data = data.map { |c| c[offset...([offset + samples, c.length].min)] || [] }

          if spectrum
            p.logscale if p.respond_to?(:logscale)
            data = data.map { |c| MB::Sound.real_fft(c).abs.map(&:to_db).clip(-80, 80) }
          else
            p.logscale(false) if p.respond_to?(:logscale)
          end

          p.yrange(data.map(&:min).min, data.map(&:max).max) if p.respond_to?(:yrange) && !all.nil?

          @lines = p.plot(data.map.with_index { |c, idx| [idx.to_s, c] }.to_h, print: false)
          puts @lines if p.respond_to?(:print) && p.print

          @lines if p.respond_to?(:print) && !p.print
        end
      ensure
        if all == true
          if graphical
            @pg.close
            @pg = nil
          elsif @pt.respond_to?(:height)
            puts "\e[#{@pt.height + (header_lines || 2) + 2}H"
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
        data = Numo::NArray.cast(data) if is_numeric_array?(data)
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

        MB::U.table(results, header: ['#'] + data.keys)
      end

      private

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
          evaluate(convert_sound_to_narray(data), range: range, steps: steps, try_convert: false)
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
    end
  end
end
