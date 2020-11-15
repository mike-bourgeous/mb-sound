require 'forwardable'

module MB
  module Sound
    # A wrapper for any audio output stream that responds to the #write method
    # that plots whatever's being written as fast as the display can keep up.
    class PlotOutput
      extend Forwardable

      def_delegators :@output, :rate, :channels

      # Initializes an output plotter for the given +output+.
      #
      # +:plot+ can be used to customize the Plot instance, or to pass a
      # different compatible plotter.
      def initialize(output, window_size: 960, graphical: false, header_lines: 1, plot: nil)
        raise "Output streams must respond to #write" unless output.respond_to?(:write)

        @header_lines = header_lines
        @window_size = 960

        @output = output

        @plot_set = false
        if plot
          @p = plot
          @plot_set = true
        elsif graphical
          @p = MB::Sound::Plot.new
        else
          @p = MB::Sound::Plot.terminal(height_fraction: (U.height - header_lines - 2).to_f / U.height)
        end

        @min = -0.1
        @max = 0.1

        @next_time = nil
        @frame = 0
      end

      # Writes the data to the output, saves it for the plotting thread, then
      # wakes up the plotting thread.
      def write(data)
        @output.write(data)

        period = data[0].length.to_f / @output.rate
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # Subtract some time to build up a buffer before plotting
        @next_time ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) - 0.2

        remaining = @next_time - now
        this_time = @next_time
        @next_time += period

        @frame += 1
        if remaining > 0.5 * period || @frame % 5 == 0
          plot(data)

          # The sleep is necessary to maintain sync
          remaining = this_time - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          sleep 0.75 * remaining if remaining > 0
        elsif remaining < 0
          # Force a plot eventually for really large lags (e.g. happens when
          # looping input to output)
          @next_time += 0.1 * period
        end
      end

      # Closes the output stream and stops plotting.
      def close
        puts "\e[#{@p.height + @header_lines + 2}H" if @p.respond_to?(:height)
        @p.close unless @plot_set
        @output.close
      end

      private

      def plot(data)
        puts "\e[#{@header_lines + 1}H\e[36mPress Ctrl-C to stop\e[0m\e[K"

        samples = [@window_size, data[0].length].min

        max = data.map { |c| c.abs.max * 0.999 }.max
        @max = (max * 2).ceil * 0.5 if max > @max

        @p.xrange(0, samples) if @p.respond_to?(:xrange)
        @p.yrange(-@max, @max) if @p.respond_to?(:yrange)

        d = data.map.with_index.map { |c, idx|
          [idx, c[-samples..-1]]
        }.to_h

        @p.plot(d)
      end
    end
  end
end