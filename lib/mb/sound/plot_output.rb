require 'forwardable'

module MB
  module Sound
    # A wrapper for any audio output stream that responds to the #write method
    # that plots whatever's being written as fast as the display can keep up.
    class PlotOutput
      extend Forwardable

      def_delegators :@output, :rate, :channels, :buffer_size

      # If true, PlotOutput will try to manage audio/video sync by sleeping.
      # Set this to false if something else applies backpressure to maintain
      # sync (e.g. a synchronous plotting backend).
      attr_accessor :sleep

      # The output stream to which this PlotOutput will forward audio data.
      attr_reader :output

      # Initializes an output plotter for the given +output+.  Up to
      # +:window_size+ samples will be drawn from each call to #write.
      #
      # +:plot+ can be used to customize the Plot instance, or to pass a
      # different compatible plotter.
      def initialize(output, window_size: 960, graphical: false, header_lines: 1, plot: nil, spectrum: false)
        raise "Output streams must respond to #write" unless output.respond_to?(:write)
        raise "Output streams must respond to #buffer_size" unless output.respond_to?(:buffer_size)

        @closed = false

        @header_lines = header_lines + output.channels + 1
        max_header = MB::U.height / 5
        @header_lines = max_header if @header_lines > max_header
        @window_size = window_size || output.buffer_size

        @spectrum = spectrum

        @output = output

        @plot_set = false
        if plot
          @p = plot
          @plot_set = true
        elsif graphical
          @p = MB::M::Plot.new
        else
          @p = MB::M::Plot.terminal(height_fraction: (MB::U.height - header_lines - 2).to_f / MB::U.height)
        end

        @min = -0.1
        @max = 0.1

        @next_time = nil
        @frame = 0

        @sleep = true
      end

      # Writes the data to the output, saves it for the plotting thread, then
      # wakes up the plotting thread.
      def write(data)
        dw = data.map { |c|
          c.respond_to?(:real) ? c.real : c
        }
        @output.write(dw)

        period = data[0].length.to_f / @output.rate
        now = ::MB::U.clock_now

        # Subtract some time to build up a buffer before plotting
        @next_time ||= ::MB::U.clock_now - 0.2

        remaining = @next_time - now
        this_time = @next_time
        @next_time += period

        @frame += 1
        if !@sleep || remaining > 0.5 * period || @frame % 5 == 0
          plot(data)

          # The sleep is necessary to maintain sync
          remaining = this_time - ::MB::U.clock_now
          Kernel.sleep(0.75 * remaining) if @sleep && remaining > 0
        elsif remaining < 0
          # Force a plot eventually for really large lags (e.g. happens when
          # looping input to output)
          @next_time += 0.1 * period
        end
      end

      # Closes the output stream and stops plotting.
      def close
        @closed = true
        STDOUT.write "\e[#{@p.height + @header_lines + 2}H\n" if @p.respond_to?(:height) && @p.respond_to?(:print) && @p.print
        @p.close unless @plot_set
        @output.close
      end

      # Returns true if the plotter or the output stream has been closed.
      def closed?
        out_closed = (@output.respond_to?(:closed?) && @output.closed?)
        close if out_closed && !@closed
        @closed || @p.closed?
      end

      private

      def plot(data)
        puts "\e[#{@header_lines + 1}H\e[36mPress Ctrl-C to stop\e[0m\e[K" if !@p.respond_to?(:print) || @p.print
        Meter.linear_meters(data.map { |v| v.abs.max }, 3)

        samples = [@window_size, data[0].length].min

        if @spectrum
          @p.logscale if @p.respond_to?(:logscale)
          # TODO: Use a window function
          data = data.map { |c| MB::Sound.real_fft(c[-samples..-1]).abs.map(&:to_db).clip(-80, 80) }
          samples = data[0].length
          @p.xrange(1, samples) if @p.respond_to?(:xrange)
        else
          @p.logscale(false) if @p.respond_to?(:logscale)
          @p.xrange(0, samples) if @p.respond_to?(:xrange)
        end

        max = data.map { |c| c.abs.max * 0.999 }.max
        @max = (max * 2).ceil * 0.5 if max > @max

        if @spectrum
          @p.yrange(-80, 0) if @p.respond_to?(:yrange)
        else
          @p.yrange(-@max, @max) if @p.respond_to?(:yrange)
        end

        d = data.map.with_index.map { |c, idx|
          [idx, c[-samples..-1]]
        }.to_h

        @p.plot(d)
      end
    end
  end
end
