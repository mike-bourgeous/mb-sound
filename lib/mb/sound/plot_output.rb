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
          @p = MB::Sound::Plot.terminal(height_fraction: 0.7)
        end

        # Clear existing text on the screen
        puts "\e[H#{@header_lines + 1}"
        puts "\e[K\n" * (IO.console.winsize[0] - header_lines - 1)

        @run = true
        @t = Thread.new(&method(:plot_thread))
      end

      # Writes the data to the output, saves it for the plotting thread, then
      # wakes up the plotting thread.
      def write(data)
        @output.write(data)
        @data = data
        @t.wakeup
      end

      # Stops the plotting thread and closes the output stream.
      def close
        @run = false
        @t.kill
        @t.join
        @data = nil
        @last_data = nil
        puts "\e[#{@p.height + @header_lines + 2}H"
        @p.close
        @output.close
      end

      private

      def plot_thread
        while @run do
          if @last_data != @data
            @last_data = @data

            puts "\e[#{@header_lines + 2}H\e[36mPress Ctrl-C to stop\e[0m\e[K"

            @p.yrange(@last_data.map(&:min).min, @last_data.map(&:max).max)

            samples = [@window_size, @last_data[0].length].min
            d = @last_data.map.with_index.map { |c, idx|
              [idx, c[-samples..-1]]
            }.to_h
            @p.plot(d)
          end

          sleep
        end
      end
    end
  end
end
