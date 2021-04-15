require 'pty'
require 'tempfile'
require 'timeout'

module MB
  module Sound
    # Super basic interface to GNUplot.  You can plot to the terminal or to a
    # separate window.
    #
    # TODO: examples
    #
    # Created because Numo::Gnuplot was giving an error.
    class Plot
      class StopReadLoop < RuntimeError; end

      # Creates an ASCII-art plotter sized to the terminal.
      def self.terminal(width_fraction: 1.0, height_fraction: 0.5, width: nil, height: nil)
        cols = (((width || MB::U.width) - 1) * width_fraction).round
        rows = (((height || MB::U.height) - 1) * height_fraction).round
        Plot.new(terminal: 'dumb', width: cols, height: rows)
      end

      # The plot type (e.g. 'lines', 'boxes', 'pm3d').
      attr_accessor :type

      # The window title (change with #terminal).
      attr_reader :title

      # If true, all incoming lines from gnuplot are printed to the terminal.
      attr_accessor :debug

      attr_reader :width, :height

      # Use a longer +timeout+ if you will be plotting lots of data.
      def initialize(terminal: 'qt', title: nil, width: 800, height: 800, timeout: 5)
        @width = width
        @height = height
        @yrange = nil
        @title = title
        @rows = nil
        @cols = nil
        @logscale = false
        @type = 'lines'
        @timeout = timeout

        @read_mutex = Mutex.new

        @buf = []
        @buf_idx = 0 # offset in the buf where we left off looking for something
        @stdout, @stdin, @pid = PTY.spawn('gnuplot')

        @run = true
        @debug = false
        @t = Thread.new do read_loop end

        at_exit do
          @timeout = 1
          close rescue nil
        end

        # Wait for any output
        wait_for('')

        terminal(terminal: terminal, title: title)
      end

      # Returns an Array with all lines of output from gnuplot up to this point and
      # clears the buffer.
      def read
        @read_mutex.synchronize {
          @buf_idx = 0
          @buf.dup.tap { @buf.clear }
        }
      end

      # Sends the given command to gnuplot, then waits for the gnuplot command
      # prompt to return.
      def command(cmd)
        raise 'Plot is closed' unless @stdin

        @stdin.puts cmd
        wait_prompt # wait for the 'gnuplot>' that came before the current line

        @stdin.puts # 'gnuplot>' isn't printed with a new line, so make a new line
        wait_prompt
      end

      # Change the terminal type to +terminal+ (defaults to 'qt') with window title
      # +title+ (nil for unchanged) and the given size (also nil for unchanged).
      def terminal(terminal: 'qt', title: nil, width: nil, height: nil)
        @terminal = terminal
        @title = title || @title || ''
        @width = width || @width || 800
        @height = height || @height || 800
        command "set terminal #{terminal} #{title ? "title #{@title.inspect}" : ""} size #{@width},#{@height} enhanced font 'Helvetica,10'"
      end

      # Switches the GNUplot terminal to write to a PNG file on the next plot.
      def save_image(filename, width: 1080, height: 1080)
        ext = File.extname(filename)
        case ext
        when '.svg'
          term = 'svg'
        when '.png'
          term = 'pngcairo'
        else
          raise "Unknown file extension #{ext}"
        end

        terminal(terminal: term, width: width, height: height, title: nil)
        command "set output #{filename.inspect}"
      end

      # Stops gnuplot and closes the connecting pipes.
      def close
        return if @pid.nil?

        err = nil

        @stdin.puts 'exit'
        @stdin.puts ''
        @stdin.puts ''
        @stdin.flush
        wait_for(/plot>.*exit/) rescue err ||= $!

        @stdin&.close
        @stdin = nil

        begin
          begin
            Timeout.timeout(@timeout) do
              Process.wait(@pid)
            end
          rescue Timeout::Error
            Process.kill(:TERM, @pid)
            Timeout.timeout(@timeout) do
              Process.wait(@pid)
            end
          end
        rescue => e
          err ||= $!
        end

        @run = false
        @t&.raise StopReadLoop, 'Closing the plotter' if @t&.alive?
        @stdout&.close
        @t&.join rescue err ||= $!
        @stdout = nil

        @pid = nil
        @rows = nil
        @cols = nil

        raise err if err
      end

      def logscale(enabled = true)
        @logscale = enabled
      end

      # Sets xrange of the next plot (not kept after a reset) also don't rely on this documentation
      def xrange(min, max)
        @xrange = [min, max]
        command "set xrange [#{min}:#{max}]"
      end

      # Sets yrange of the next plot (not kept after a reset) also don't rely on this documentation
      def yrange(min, max)
        @yrange = [min, max]
        command "set yrange [#{min}:#{max}]"
      end

      # Displays a multi-plot of the given +data+ hash of labels to arrays, with
      # the given number of +columns+ and +rows+ (defaults to a roughly square
      # layout based on number of graphs).  The graph X axis is always array
      # index.
      #
      # If the read buffer (see #read) gets larger than 1100 lines, it will be
      # trimmed to the most recent 1000 lines to prevent unbounded memory
      # growth.  But if the terminal type is 'dumb', then the buffer will be
      # cleared before and after plotting so the resulting plot can be
      # displayed.
      #
      # If +:print+ is true, then 'dumb' terminal plots are printed to the
      # console.  If false, then plots are returned as an array of lines.
      def plot(data, rows: nil, columns: nil, print: true)
        raise 'Plotter is closed' unless @pid

        @read_mutex.synchronize {
          if @terminal == 'dumb'
            @buf.clear
            @buf_idx = 0
          elsif @buf.length > 1100
            remove = @buf.length - 1000
            @buf_idx -= remove
            @buf_idx = 0 if @buf_idx < 0
            @buf.shift(remove)
          end
        }

        rows ||= columns.nil? ? Math.sqrt(data.size).ceil : (data.size.to_f / columns).ceil
        cols = columns || (data.size.to_f / rows).ceil

        set_multiplot(rows, cols)

        tmps = data.compact.each_with_index.map { |(name, a), idx| [Tempfile.new("plotdata_#{idx}"), name, a] }
        tmps.each do |(file, name, plotinfo)|
          if plotinfo.is_a?(Hash)
            write_data(file, plotinfo[:data])
          else
            write_data(file, plotinfo)
          end
        end

        tmps.each_with_index do |(file, name, plotinfo), idx|
          r, g, b = rand(255), rand(255), rand(255)
          if r+g+b > 255
            r /= 4
            g /= 4
            b /= 4
          end

          if plotinfo.is_a?(Hash)
            array = plotinfo[:data]
          else
            array = plotinfo
            plotinfo = {
              data: plotinfo
            }
          end

          # Set graph range
          if plotinfo[:yrange]
            yrange(*plotinfo[:yrange])
          elsif @yrange
            yrange(*@yrange)
          else
            if array.is_a?(Numo::DComplex) || array.is_a?(Numo::SComplex)
              range = array.not_inplace!.abs
            elsif array[0].is_a?(Complex)
              range = array.map(&:abs)
            else
              range = array
            end

            finite = range.to_a.select { |v| v.finite? }
            min = finite.min || -10
            max = finite.max || 10

            min = [0, min.floor].min
            max = max > 0.2 ? max.ceil : 0.1
            yrange(min, max)
            @yrange = nil
          end

          if plotinfo[:logscale] == true || (plotinfo[:logscale] != false && @logscale)
            command "set logscale x 10"
          else
            command "unset logscale x"
          end

          command %Q{plot '#{file.path}' using 1:2 with #{@type} title '#{name}' lt rgb "##{'%02x%02x%02x' % [r,g,b]}"}
        end

        command 'unset multiplot'

        if @terminal == 'dumb'
          print_terminal_plot(print)
        end

      ensure
        tmps&.map { |(file, data)|
          file&.close rescue puts $!
          file&.unlink rescue puts $!
        }
      end

      private

      def print_terminal_plot(print)
        buf = read.reject { |l| l.empty? || l.include?('plot>') || l.strip.start_with?(/[[:alpha:]]/) }
        start_index = buf.index { |l| l.include?('+----') }
        lines = buf[start_index..-1]

        row = 0
        in_graph = false
        lines.map!.with_index { |l, idx|
          if l.include?('+----')
            if in_graph
              in_graph = false
              row += 1
            else
              in_graph = true
              l = "\n#{l}"
            end
          end

          clr = (row + 1) % 6 + 31
          l.gsub(/^\s+([+-]?\d+(\.\d+)?\s*){1,}/, "\e[1;35m\\&\e[0m")
            .gsub(/([[:alnum:]_-]+ ){0,}[*]+/, "\e[1;#{clr}m\\&\e[0m")
            .gsub(/(?<=[|])-[+]| [+] |[+]-(?=[|])/, "\e[1;35m\\&\e[0m")
            .gsub(/[+]-+[+]|[|]/, "\e[1;30m\\&\e[0m")
        }

        binding.pry if lines.any? { |l| l.include?('plot') } # XXX seeing some spurious lines above graphs

        if print
          puts lines
        else
          lines
        end
      end

      # Waits for the gnuplot prompt.
      def wait_prompt(timeout: nil)
        wait_for('plot>', timeout: timeout)
      end

      # Waits for the given +text+ output from gnuplot (which must occur on a
      # single line), with a default +timeout+ of 5s (or whatever was passed to the
      # constructor).
      def wait_for(text, timeout: nil)
        timeout ||= @timeout

        start = ::MB::Sound.clock_now
        while (::MB::Sound.clock_now - start) < timeout
          # @stdout.expect is locking up on #eof? when combined with the read
          # thread, so we'll just do our own thing.
          @read_mutex.synchronize {
            # Maybe the text already arrived in the background read thread
            idx = @buf_idx
            @buf_idx = @buf.length

            case text
            when String
              return if @buf[idx..-1].any? { |line| line.include?(text) }
            when Regexp
              return if @buf[idx..-1].any? { |line| line =~ text }
            else
              raise "Invalid text #{text.inspect}"
            end
          }

          Thread.pass
        end

        raise "Timed out waiting for #{text.inspect} after #{timeout} seconds: #{@buf}"
      end

      # Background thread runs this to read GNUplot's output.
      def read_loop
        while @run
          line = @stdout.readline.rstrip
          @read_mutex.synchronize {
            @buf << line
          }

          puts "\e[33mGNUPLOT: \e[1m#{line}\e[0m" if @debug
        end

      rescue StopReadLoop, Errno::EIO
        # Ignore
      end

      def set_multiplot(rows, cols)
        if rows != @rows || cols != @cols
          @rows = rows
          @cols = cols
          command 'unset multiplot' if @rows && @cols
        end
        command "set multiplot layout #{rows}, #{cols}"
      end

      # Writes data to a temporary file.  Plotting larger amounts of data is faster
      # if the data is written to a file, rather than input on the gnuplot
      # commandline.
      def write_data(file, array)
        array.each_with_index do |value, idx|
          value = value.abs if value.is_a?(Complex)
          file.puts "#{idx}\t#{value}"
        end

        file.close
      end
    end
  end
end
