require 'forwardable'

module MB
  module Sound
    # A wrapper for any audio output stream that responds to the #write method
    # that plots whatever's being written as fast as the display can keep up.
    class PlotOutput
      extend Forwardable

      def_delegators :@output, :rate, :channels

      # Initializes an output plotter for the given +output+.
      def initialize(output, window_size: 960, graphical: false, header_lines: 1)
        raise "Output streams must respond to #write" unless output.respond_to?(:write)

        @header_lines = header_lines
        @window_size = 960

        @output = output

        if graphical
          @p = MB::Sound::Plot.new
        else
          @p = MB::Sound::Plot.terminal(height_fraction: (U.height - header_lines - 2).to_f / U.height)
        end

        @min = -0.1
        @max = 0.1

        @next_time = nil
      end

      # Writes the data to the output, saves it for the plotting thread, then
      # wakes up the plotting thread.
      def write(data)
        @output.write(data)

        period = data[0].length.to_f / @output.rate
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # Subtract some time to build up a buffer before plotting
        first_time = @next_time.nil?
        @next_time ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) - 0.2

        remaining = @next_time - now
        this_time = @next_time
        @next_time += period

        if remaining > 0.5 * period || first_time
          plot(data)

          # The sleep is necessary to maintain sync
          remaining = this_time - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          sleep 0.75 * remaining if remaining > 0
        elsif remaining < 0
          # Force a plot eventually for really large lags (e.g. when looping
          # input to output)
          @next_time += 0.1 * period
        end
      end

      # Stops the plotting thread and closes the output stream.
      def close
        puts "\e[#{@p.height + @header_lines + 2}H"
        @p.close
        @output.close
      end

      private

      def plot(data)
        puts "\e[#{@header_lines + 1}H\e[36mPress Ctrl-C to stop\e[0m\e[K"

        samples = [@window_size, data[0].length].min

        max = data.map { |c| c.abs.max * 0.999 }.max
        @max = (max * 2).ceil * 0.5 if max > @max

        @p.xrange(0, samples)
        @p.yrange(-@max, @max)

        d = data.map.with_index.map { |c, idx|
          [idx, c[-samples..-1]]
        }.to_h

        @p.plot(d)
      end
    end
  end
end
