require 'pty'
require 'io/console'
require_relative '../vt'

module MB
  module Term
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
      # - :command (any program: a shell, irb, another process's Pry):
      #   +command+ runs with the slave as its controlling terminal
      #   (PTY.spawn); Ctrl-C is ^C through its line discipline, #stop
      #   hangs it up, #exited? says when it ended.
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

        # An IO that also gets everything the program writes, unchanged
        # (the real terminal while the tiled screen is hidden: the plain
        # console through the pty).  While set, the VT still keeps the
        # scrollback but doesn't answer queries (the terminal does).
        attr_reader :relay

        # An object with #write that also gets everything the program
        # writes, unchanged, after the VT has it (from the reader thread).
        # Unlike #relay, the VT keeps answering the program's queries: for
        # sharing a session with other terminals (examples/share_repl.rb).
        attr_accessor :mirror

        # The process of a :command host (nil otherwise).
        attr_reader :pid

        def relay=(io)
          @lock.synchronize do
            @relay = io
            @vt.take_replies # (stale answers)
          end
        end

        # +rows+ x +cols+ the pane's size; +mode+ :adopt, :thread, or
        # :command; +target+ the binding or object a :thread Pry starts in;
        # +pry+ options for a :thread Pry; +command+ (an Array of words or
        # a String for the shell) and +env+ for :command.
        def initialize(rows:, cols:, mode: :adopt, scrollback: VT::SCROLLBACK, ambiguous_width: 1, target: TOPLEVEL_BINDING, pry: {}, command: nil, env: {})
          raise ArgumentError, "ReplHost modes are :adopt, :thread, and :command (got #{mode.inspect})" unless %i[adopt thread command].include?(mode)
          raise ArgumentError, 'A :command ReplHost needs a command' if mode == :command && (command.nil? || command.empty?)
          @command = command
          @env = env
          @pid = nil
          @waiter = nil
          @writer = nil
          @mirror = nil
          @rows = rows
          @cols = cols
          @mode = mode
          @target = target
          @pry_opts = pry
          @vt = VT.new(rows, cols, scrollback: scrollback, ambiguous_width: ambiguous_width)
          @lock = Mutex.new
          @synced = ConditionVariable.new
          @sync_seq = 0
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

          if @mode == :command
            start_command
            return self
          end
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
          if @mode == :command
            stop_command
          elsif @mode == :adopt
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
          @writer&.close rescue nil
          @reader&.kill
          @master = @slave = @reader = @writer = nil
          self
        end

        # Waits until the VT has everything the program wrote to the pty
        # so far (output still in the pty, or read and not yet fed, when
        # the reader thread is behind): a sync mark (VT::SYNC_OSC) is
        # written after it, and the VT has it when it reaches the mark.
        # Call it before reading the VT for what the program just wrote
        # (a screen switch copying the REPL's lines).  Returns true, or
        # false after +timeout+ seconds (or when not hosting).
        def sync_output(timeout = 2.0)
          return false unless @slave && @reader&.alive?
          [$stdout, $stderr].each { |io| io.flush rescue nil }
          n = @lock.synchronize { @sync_seq += 1 }
          @slave.write("\e]#{VT::SYNC_OSC};#{n}\a")
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          @lock.synchronize do
            until @vt.sync_mark >= n
              left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              return false if left <= 0
              @synced.wait(@lock, left)
            end
          end
          true
        rescue IOError, SystemCallError
          false
        end

        # Writes key bytes to the program (as typed on a terminal).
        # Translates cursor keys when the program asked for application
        # cursor keys.
        def write(bytes)
          return unless @master
          bytes = bytes.b
          bytes = bytes.gsub(/\e\[([ABCDHF])/n, "\eO\\1") if @vt.app_cursor?
          (@writer || @master).write(bytes)
        rescue IOError, SystemCallError
          nil
        end

        # Sends a key (its bytes; legacy bytes for keys in the kitty
        # protocol's forms: CSI u, event types, an explicit "no
        # modifiers" 1, which line editors don't read).
        def key(k)
          b = k.bytes
          write(b.nil? || Input.kitty_bytes?(b) ? Input.legacy_bytes(k) : b)
        end

        # Pastes +text+ (bracketed when the program turned that on).
        def paste(text)
          write(@vt.bracketed_paste? ? "\e[200~#{text}\e[201~" : text)
        end

        # Prints +text+ in the pane as program output above the prompt:
        # the line being edited is cleared, the text written, and the
        # program asked to redraw its prompt and line below it (a resize,
        # as a terminal would).
        def print_above(text)
          return unless @slave
          body = text.to_s.gsub(/\r?\n/, "\r\n")
          body += "\r\n" unless body.end_with?("\r\n")
          @slave.write("\r\e[J#{body}")
          @slave.flush
          resize(@rows, @cols, force: true)
        rescue IOError, SystemCallError
          nil
        end

        # Ctrl-C: SIGINT in :adopt mode (Reline's handler while reading, an
        # Interrupt in the main thread while evaluating, as on a
        # terminal); an Interrupt raised in the Pry thread in :thread mode.
        def interrupt
          if @mode == :adopt
            Process.kill(:INT, Process.pid)
          elsif @mode == :command
            write("\x03")
          else
            @thread&.raise(Interrupt)
          end
        end

        # A new pane size: the VT, the pty, and Reline (its WINCH handler,
        # called through the signal, as a terminal would).  +force+
        # signals even at the same size (so Reline redraws its line).
        def resize(rows, cols, force: false)
          return if rows == @rows && cols == @cols && !force
          @rows = rows
          @cols = cols
          @lock.synchronize { @vt.resize(rows, cols) }
          return unless @slave
          @slave.winsize = [rows, cols]
          Process.kill(:WINCH, @pid || Process.pid) # (a :command's kernel signal comes only for a new size)
        rescue SystemCallError, IOError
          nil
        end

        # The size [rows, cols].
        def size = [@rows, @cols]

        # True once a :command host's program has ended.
        def exited?
          @mode == :command && !@waiter.nil? && !@waiter.alive?
        end

        # A :command program's Process::Status once it ended, else nil.
        def status
          exited? ? @waiter.value : nil
        end

        def inspect = "#<MB::Term::Input::ReplHost #{@mode} #{@rows}x#{@cols}#{active? ? '' : ' (stopped)'}>"

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

        def start_command
          cmd = @command.is_a?(Array) ? @command : [@command]
          @master, @writer, @pid = PTY.spawn(@env, *cmd) # (PTY.spawn's reader is read-only)
          @master.sync = true
          @writer.sync = true
          # The slave, held for the size and sync marks (O_NOCTTY: never
          # this process's controlling terminal)
          @slave = File.open(@master.path, File::RDWR | File::NOCTTY)
          @slave.winsize = [@rows, @cols]
          Process.kill(:WINCH, @pid) rescue nil
          @stopping = false
          @reader = Thread.new { read_loop }
          pid = @pid
          slave = @slave
          @waiter = Thread.new do
            Thread.current.name = 'MB::Term command'
            st = Process.wait2(pid)[1]
            slave.close rescue nil # (the master reads EIO: the reader ends)
            st
          end
        end

        def stop_command
          if @waiter&.alive?
            Process.kill(:HUP, @pid) rescue nil
            unless @waiter.join(2)
              Process.kill(:KILL, @pid) rescue nil
              @waiter.join(2)
            end
          end
        end

        def start_pry
          require 'pry'
          slave = @slave
          opts = { input: PryInput.new, output: slave, pager: false, target: @target }.merge(@pry_opts)
          @thread = Thread.new do
            Thread.current.name = 'MB::Term REPL'
            Thread.current.report_on_exception = false
            begin
              Pry::REPL.new(Pry.new(opts), target: opts[:target]).start
            rescue IOError
              nil
            end
          end
        end

        def read_loop
          Thread.current.name = 'MB::Term pty'
          Thread.current.priority = -1
          master = @master
          writer = @writer || master
          loop do
            data = master.readpartial(65_536)
            @bytes_read += data.bytesize
            t = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
            pos = 0
            while pos < data.bytesize
              piece = data.byteslice(pos, CHUNK)
              pos += CHUNK
              replies, relay = @lock.synchronize {
                mark = @vt.sync_mark
                @vt.feed(piece)
                @synced.broadcast if @vt.sync_mark != mark
                r = @vt.take_replies
                [@relay ? '' : r, @relay]
              }
              writer.write(replies) unless replies.empty?
              begin
                relay&.write(piece)
              rescue IOError, SystemCallError
                nil
              end
              begin
                @mirror&.write(piece)
              rescue StandardError => e
                warn "MB::Term::Input::ReplHost mirror: #{e.class}: #{e.message}" # (the reader keeps going)
              end
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

      # True for key bytes only the kitty keyboard protocol sends: CSI u,
      # an event type after the modifiers ("1;1:2A"), or a modifier field
      # of 1 (none) on a cursor or tilde key ("\e[1;1A").
      def self.kitty_bytes?(b)
        b.match?(/\A\e\[[\d;:]*u\z/n) || b.match?(/\A\e\[[\d;]*:[\d;:]*[A-Z~]\z/n) || b.match?(/\A\e\[\d+;1[A-Z~]\z/n)
      end

      # Legacy terminal bytes for a Key without its own (kitty-protocol
      # keys forwarded to a program that reads legacy input).  Cursor and
      # editing keys keep Shift, Alt, and Ctrl as xterm sends them
      # ("\e[1;5D" for Ctrl-Left).
      def self.legacy_bytes(k)
        mod = 1 + (k.mods.include?(:shift) ? 1 : 0) + (k.mods.include?(:alt) ? 2 : 0) + (k.mods.include?(:ctrl) ? 4 : 0)
        if mod > 1
          letter = { up: 'A', down: 'B', right: 'C', left: 'D', home: 'H', end: 'F' }[k.key]
          return "\e[1;#{mod}#{letter}" if letter
          tilde = { delete: 3, page_up: 5, page_down: 6 }[k.key]
          return "\e[#{tilde};#{mod}~" if tilde
        end

        base =
          case k.key
          when :enter then "\r"
          when :tab then k.mods.include?(:shift) ? "\e[Z" : "\t"
          when :backspace then k.mods.include?(:ctrl) ? "\x08" : "\x7f" # (Ctrl-Backspace: ^H, as xterm sends it)
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
