require 'pty'
require 'io/console'
require_relative '../screen/vt'

module MB
  module Sound
    module UI
      module Input
        # Hosts the real Pry and Reline in a pane: they read and write the
        # slave side of an in-process pty pair, keys from the router are
        # written to the master, and what they write is read back into a
        # VT whose cells the pane draws (option (a2) of research-ui-4).
        # Every Reline feature keeps working (history, Ctrl-R, completion
        # dialogs, multi-line editing, vi mode), in any outer terminal.
        #
        # Two ways in:
        # - :adopt (the console): the process's stdin, stdout, and stderr
        #   are reopened onto the slave (the real terminal stays reachable
        #   through #real_in/#real_out), so the running Pry, Reline,
        #   `puts`, warnings, and subprocesses all land in the pane with no
        #   reconfiguration; #stop puts them back.  Ctrl-C sends SIGINT to
        #   the process, exactly as the terminal's line discipline would.
        # - :thread (specs, tools): a Pry of its own on a thread, reading
        #   through Reline on the slave; Ctrl-C raises Interrupt in it.
        #
        # Generic: no MB::Sound types.
        class ReplHost
          # Pry calls #readline(prompt) only on inputs whose #readline takes
          # one argument (Reline.readline takes optional ones), so a Pry of
          # our own reads through this.
          class PryInput
            def readline(prompt) = Reline.readline(prompt, true)

            def completion_proc=(proc)
              Reline.completion_proc = proc
            end
          end

          # Bytes fed to the VT between Thread.pass calls (so long output
          # can't hold the GVL for long).
          CHUNK = 4096

          attr_reader :vt, :mode, :real_in, :real_out, :thread, :reader

          # Bytes read from the program so far, and reader CPU seconds.
          attr_reader :bytes_read, :reader_cpu

          # Called (from the reader thread) after output was fed to the VT.
          attr_accessor :on_output

          # +rows+ x +cols+ the pane's size; +mode+ :adopt or :thread;
          # +target+ the binding or object a :thread Pry starts in; +pry+
          # options for a :thread Pry.
          def initialize(rows:, cols:, mode: :adopt, scrollback: VT::SCROLLBACK, ambiguous_width: 1, target: TOPLEVEL_BINDING, pry: {})
            raise ArgumentError, "ReplHost modes are :adopt and :thread (got #{mode.inspect})" unless %i[adopt thread].include?(mode)
            @rows = rows
            @cols = cols
            @mode = mode
            @target = target
            @pry_opts = pry
            @vt = VT.new(rows, cols, scrollback: scrollback, ambiguous_width: ambiguous_width)
            @lock = Mutex.new
            @bytes_read = 0
            @reader_cpu = 0.0
            @changed = true
          end

          # Runs the block holding the VT's lock (the painter draws with it).
          def synchronize(&block)
            @lock.synchronize(&block)
          end

          # True (once) when output arrived since the last call.
          def changed!
            c = @changed
            @changed = false
            c
          end

          # True while hosting.
          def active?
            !@master.nil?
          end

          # Opens the pty and starts hosting.  Returns self.
          def start
            return self if active?

            @master, @slave = PTY.open
            @slave.winsize = [@rows, @cols]
            @master.sync = true
            @stopping = false
            if @mode == :adopt
              adopt
            else
              Reline.input = @slave
              Reline.output = @slave
            end
            @reader = Thread.new { read_loop }
            start_pry if @mode == :thread
            self
          end

          # Stops hosting: the process's streams go back to the terminal
          # (:adopt), or the Pry thread ends (:thread).  Returns self.
          def stop
            return self unless active?

            @stopping = true
            if @mode == :adopt
              unadopt
            else
              @thread&.kill
              @thread&.join(2)
              @thread = nil
              Reline.input = STDIN
              Reline.output = STDOUT
            end
            @slave.close rescue nil
            @reader&.join(1)
            @master.close rescue nil
            @reader&.kill
            @master = @slave = @reader = nil
            self
          end

          # Writes key bytes to the program (as typed on a terminal).
          # Translates cursor keys when the program asked for application
          # cursor keys.
          def write(bytes)
            return unless @master
            bytes = bytes.b
            bytes = bytes.gsub(/\e\[([ABCDHF])/n, "\eO\\1") if @vt.app_cursor?
            @master.write(bytes)
          rescue IOError, SystemCallError
            nil
          end

          # Sends a key (its bytes; legacy bytes for keys decoded from the
          # kitty protocol).
          def key(k)
            b = k.bytes
            write(b.nil? || b.match?(/\A\e\[[\d;:]*u\z/n) ? Input.legacy_bytes(k) : b)
          end

          # Pastes +text+ (bracketed when the program turned that on).
          def paste(text)
            write(@vt.bracketed_paste? ? "\e[200~#{text}\e[201~" : text)
          end

          # Ctrl-C: SIGINT in :adopt mode (Reline's handler while reading, an
          # Interrupt in the main thread while evaluating, as on a
          # terminal); an Interrupt raised in the Pry thread in :thread mode.
          def interrupt
            if @mode == :adopt
              Process.kill(:INT, Process.pid)
            else
              @thread&.raise(Interrupt)
            end
          end

          # A new pane size: the VT, the pty, and Reline (its WINCH handler,
          # called through the signal, as a terminal would).
          def resize(rows, cols)
            return if rows == @rows && cols == @cols
            @rows = rows
            @cols = cols
            @lock.synchronize { @vt.resize(rows, cols) }
            return unless @slave
            @slave.winsize = [rows, cols]
            Process.kill(:WINCH, Process.pid)
          rescue SystemCallError, IOError
            nil
          end

          # The size [rows, cols].
          def size = [@rows, @cols]

          def inspect = "#<UI::Input::ReplHost #{@mode} #{@rows}x#{@cols}#{active? ? '' : ' (stopped)'}>"

          private

          def adopt
            @real_in = STDIN.dup
            @real_out = STDOUT.dup
            @real_err = STDERR.dup
            [STDOUT, STDERR].each(&:flush)
            STDIN.reopen(@slave)
            STDOUT.reopen(@slave)
            STDERR.reopen(@slave)
            STDOUT.sync = true
            STDERR.sync = true
          end

          def unadopt
            return unless @real_in
            [STDOUT, STDERR].each { |io| io.flush rescue nil }
            STDIN.reopen(@real_in)
            STDOUT.reopen(@real_out)
            STDERR.reopen(@real_err)
            [@real_in, @real_out, @real_err].each { |io| io.close rescue nil }
            @real_in = @real_out = @real_err = nil
          end

          def start_pry
            require 'pry'
            slave = @slave
            opts = { input: PryInput.new, output: slave, pager: false, target: @target }.merge(@pry_opts)
            @thread = Thread.new do
              Thread.current.name = 'MB::Sound::UI REPL'
              Thread.current.report_on_exception = false
              begin
                Pry::REPL.new(Pry.new(opts), target: opts[:target]).start
              rescue IOError
                nil
              end
            end
          end

          def read_loop
            Thread.current.name = 'MB::Sound::UI pty'
            Thread.current.priority = -1
            master = @master
            loop do
              data = master.readpartial(65_536)
              @bytes_read += data.bytesize
              t = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
              pos = 0
              while pos < data.bytesize
                piece = data.byteslice(pos, CHUNK)
                pos += CHUNK
                replies = @lock.synchronize {
                  @vt.feed(piece)
                  @vt.take_replies
                }
                master.write(replies) unless replies.empty?
                Thread.pass if pos < data.bytesize
              end
              @reader_cpu += Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID) - t
              @changed = true
              @on_output&.call
            end
          rescue IOError, Errno::EIO, Errno::EBADF
            nil
          end
        end

        # Legacy terminal bytes for a Key without its own (kitty-protocol
        # keys forwarded to a program that reads legacy input).
        def self.legacy_bytes(k)
          base =
            case k.key
            when :enter then "\r"
            when :tab then k.mods.include?(:shift) ? "\e[Z" : "\t"
            when :backspace then "\x7f"
            when :escape then "\e"
            when :up then "\e[A"
            when :down then "\e[B"
            when :right then "\e[C"
            when :left then "\e[D"
            when :home then "\e[H"
            when :end then "\e[F"
            when :delete then "\e[3~"
            when :page_up then "\e[5~"
            when :page_down then "\e[6~"
            when String
              if k.mods.include?(:ctrl) && k.key.length == 1 && k.key.ord < 128
                c = k.key == ' ' ? 0 : k.key.downcase.ord & 0x1F
                c = { ']' => 0x1D, '\\' => 0x1C, '^' => 0x1E, '_' => 0x1F }.fetch(k.key, c)
                c.chr
              else
                k.key
              end
            else ''
            end
          k.mods.include?(:alt) ? "\e#{base}" : base
        end
      end
    end
  end
end
