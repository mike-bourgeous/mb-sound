require 'socket'
require 'io/wait'
require 'json'
require 'rbconfig'
require_relative 'starter/server'

module MB
  module Sound
    # Starts processes for the console without forking it (spawner-1,
    # 2026-11-03).  Starting a process from a big Ruby process forks with
    # the GVL held, so a playing Session's render thread waits for it: in
    # the Mac container a process started every 2 s while techno played
    # gave 20 render-thread GVL waits of 1 ms or more in 30 s (longest 16.9
    # ms) against 7 at idle (hand-tune-2), and the first ui.note's
    # `git rev-parse` up to 19 ms (audio-safety-2).  bin/sound.rb launches
    # a small starter process before anything plays (.start; plain Ruby
    # without gems, Starter::Server, about 13 MB), and every later process
    # (ffmpeg readers and writers, ffprobe, git, the refine worker,
    # graphviz) starts through it: the console sends the command, its
    # environment and directory, and the child's stdin/stdout/stderr (pipe
    # ends or files the console opened) over a UNIX socket (SCM_RIGHTS),
    # and gets back the pid and, later, the exit status.  Nothing forks in
    # the console, so nothing holds its GVL longer than a socket write.
    #
    # Where no starter runs (scripts, a fork of the process, or
    # MB_SOUND_STARTER=0), .spawn and the helpers start the process
    # directly with Process.spawn, as before; scripts start processes
    # while nothing plays, and the spawn guard of the specs fails direct
    # starts while a Session plays.  If the starter dies (or stops
    # answering for TIMEOUT seconds), callers fall back to direct starts
    # with a warning once per call site, never a hang; children it started
    # end with an unknown status (Status#unknown?).
    #
    # Library code starts processes only through .spawn, .popen, and
    # .capture (spec/lib/mb/sound/spawn_sites_spec.rb lists the direct
    # starts left in lib/, with their reasons).
    class Starter
      # Seconds to wait for the starter's answer to a request before
      # giving up on it (it answers in well under a millisecond).
      TIMEOUT = 10.0

      # Seconds to wait for a new starter to say it's ready.
      READY_TIMEOUT = 10.0

      # Raised inside the client when the starter is gone (callers fall
      # back to direct starts).
      class Dead < StandardError; end

      # The exit status of a child: like Process::Status (#exitstatus,
      # #termsig, #success?, #exited?, #signaled?, #pid, #to_s), plus
      # #unknown? for a child whose starter died before it ended.
      class Status
        attr_reader :pid, :exitstatus, :termsig

        # A Status from a Process::Status.
        def self.from(st) = new(st.pid, st.exitstatus, st.termsig)

        # The status of a child whose starter died first.
        def self.unknown(pid) = new(pid, nil, nil, unknown: true)

        def initialize(pid, exitstatus, termsig, unknown: false)
          @pid = pid
          @exitstatus = exitstatus
          @termsig = termsig
          @unknown = unknown
        end

        def unknown? = @unknown
        def exited? = !@exitstatus.nil?
        def signaled? = !@termsig.nil?

        # true for exit 0, false for another exit or a signal, nil if
        # unknown (as Process::Status#success?).
        def success?
          return nil if @unknown
          exited? ? @exitstatus == 0 : false
        end

        def to_s
          if @unknown
            "pid #{@pid} (exit status unknown: the process starter exited first)"
          elsif signaled?
            "pid #{@pid} SIG#{Signal.signame(@termsig)} (signal #{@termsig})"
          else
            "pid #{@pid} exit #{@exitstatus}"
          end
        end

        def inspect = "#<#{self.class.name} #{self}>"
      end

      # A process started by .spawn.  #wait for its Status, #kill to
      # signal it.
      class Child
        attr_reader :pid

        def initialize(pid = nil)
          @pid = pid
          @status = nil
          @mutex = Mutex.new
          @cond = ConditionVariable.new
        end

        # Waits up to +timeout+ seconds (nil: forever) for the process to
        # end.  Returns its Status, or nil on a timeout.
        def wait(timeout = nil)
          deadline = timeout && MB::U.clock_now + timeout
          @mutex.synchronize do
            until @status
              left = deadline && deadline - MB::U.clock_now
              return nil if left && left <= 0
              @cond.wait(@mutex, left)
            end
            @status
          end
        end

        # The Status once the process ended, else nil.
        def status = @mutex.synchronize { @status }

        # True once the process ended.
        def exited? = !status.nil?

        # True while the process runs.
        def alive? = !exited?

        # Sends +signal+ to the process if it still runs.
        def kill(signal = :TERM)
          Process.kill(signal, @pid) if @pid && !exited?
        rescue SystemCallError
          nil
        end

        # (from the starter's reader or a waiter thread)
        def finish(status)
          @mutex.synchronize do
            @status ||= status
            @cond.broadcast
          end
        end
      end

      # A child of the starter (killed through it, so a pid reused after it
      # ended is never signaled).
      class StarterChild < Child
        attr_reader :id

        def initialize(starter, id)
          super()
          @starter = starter
          @id = id
          @reply = Queue.new
        end

        def kill(signal = :TERM)
          return if exited?
          @starter.kill_child(@id, signal)
        end

        # (from the starter's reader thread: the spawn's reply)
        def reply(msg) = @reply << msg

        # The spawn's reply (a Hash), nil after +timeout+ seconds.
        def take_reply(timeout) = @reply.pop(timeout: timeout)

        # (the pid, once replied)
        def started(pid) = @pid = pid
      end

      # A process started directly (no starter running): waited for by a
      # Process.detach thread, off the GVL.
      class DirectChild < Child
        def initialize(pid)
          super(pid)
          @waiter = Thread.new { finish(Status.from(Process.wait2(pid)[1])) }
          @waiter.name = 'MB::Sound::Starter::DirectChild'
        end
      end

      @current = nil
      @started = false
      @owner = nil
      @lock = Mutex.new

      class << self
        # Starts the process's starter unless one runs (bin/sound.rb, before
        # anything plays; specs).  Returns it, or nil when
        # $MB_SOUND_STARTER is 0 or it didn't start (with a warning).
        def start
          return nil if ENV['MB_SOUND_STARTER'] == '0'
          @lock.synchronize do
            return @current if usable?(@current)
            @current = new
            @started = true
            @owner = Process.pid
            @current
          end
        rescue StandardError => e
          warn "The process starter didn't start (#{e.class}: #{e.message}); processes start directly (a possible dropout if one starts while playing)"
          nil
        end

        # The running starter of this process, or nil (none started, it
        # died, it was stopped, or this is a fork of the process that
        # started it).
        def current
          s = @current
          usable?(s) ? s : nil
        end

        # Makes +starter+ (a Starter, or nil) the process's starter (specs).
        # Returns the one it replaces.
        def use(starter)
          @lock.synchronize do
            old = @current
            @current = starter
            @owner = Process.pid
            @started = !starter.nil?
            old
          end
        end

        # Stops the starter (its children keep running).
        def stop
          s = @lock.synchronize {
            c = @current
            @current = nil
            c
          }
          @started = false
          s&.close
          nil
        end

        # Starts a process like Process.spawn([env,] *command, in:, out:,
        # err:, chdir:, pgroup:) through the starter, or directly where
        # none runs.  Redirections: an IO (or anything with #to_io), a path
        # String or File::NULL (opened for reading for in:, writing
        # otherwise), :null, or err: :out (the same as out:); nil inherits
        # the console's descriptor.  Returns a Child.
        def spawn(*args, **opts)
          env = args.first.is_a?(Hash) ? args.shift : {}
          raise ArgumentError, 'Starter.spawn: no command' if args.empty?
          if (s = current)
            begin
              return s.spawn_child(env, args, **opts)
            rescue Dead
              nil
            end
          end
          if @started && @owner == Process.pid
            Internal.warn_once_per_site(:starter_dead,
              "the process starter exited; starting #{Array(args.first).first} directly (a fork from this process holds the GVL: " \
              'a possible dropout while playing; MB::Sound::Starter.start starts a new starter while nothing plays)')
          end
          spawn_direct(env, args, **opts)
        end

        # Starts +command+ (an Array of arguments, or a String for the
        # shell) with a pipe to (+mode+ "w") or from ("r") it, like IO.popen;
        # other options as .spawn.  Returns [IO, Child]: close the IO, then
        # Child#wait for its status.
        def popen(command, mode = 'r', **opts)
          argv = command.is_a?(Array) ? command : [command]
          r, w = IO.pipe
          if mode.include?('w')
            child = spawn(*argv, in: r, **opts)
            r.close
            io = w
          else
            child = spawn(*argv, out: w, **opts)
            w.close
            io = r
          end
          io.binmode if mode.include?('b')
          io.sync = true
          [io, child]
        rescue StandardError
          r&.close unless r&.closed?
          w&.close unless w&.closed?
          raise
        end

        # Runs [env,] *command to its end and returns [stdout, stderr,
        # Status] (Open3.capture3, or capture2/capture2e with +err+): +err+
        # :capture (stderr returned), :out (merged into stdout; stderr nil),
        # :null, or nil (the console's stderr; stderr nil).  +stdin_data+ is
        # written to its stdin (else stdin is /dev/null).  +binmode+ reads
        # binary Strings.
        def capture(*args, stdin_data: nil, err: :capture, binmode: false, **opts)
          out_r, out_w = IO.pipe
          err_r, err_w = IO.pipe if err == :capture
          in_r, in_w = IO.pipe if stdin_data
          errs = { capture: err_w, out: :out, null: :null, nil => nil }
          raise ArgumentError, "capture err: is :capture, :out, :null, or nil (got #{err.inspect})" unless errs.key?(err)
          child = spawn(*args, in: in_r || :null, out: out_w, err: errs[err], **opts)
          [out_w, err_w, in_r].compact.each(&:close)
          [out_r, err_r].compact.each { |io| io.binmode if binmode }
          feeder = in_w && Thread.new do
            in_w.write(stdin_data)
          rescue Errno::EPIPE
            nil
          ensure
            in_w.close
          end
          err_reader = err_r && Thread.new { err_r.read }
          out = out_r.read
          err_text = err_reader&.value
          feeder&.join
          [out, err_text, child.wait]
        ensure
          [out_r, out_w, err_r, err_w, in_r].compact.each { |io| io.close unless io.closed? }
        end

        # Lines of a starter (and its use) for the console's diagnostics:
        # { running:, pid:, spawned:, children: }.
        def info
          s = current
          return { running: false, started: @started } unless s
          { running: true, pid: s.pid, spawned: s.spawned, children: s.children }
        end

        private

        def usable?(s) = s && !s.dead? && @owner == Process.pid

        def spawn_direct(env, args, in: nil, out: nil, err: nil, chdir: nil, pgroup: nil)
          o = {}
          o[:in] = direct_target(binding.local_variable_get(:in)) unless binding.local_variable_get(:in).nil?
          o[:out] = direct_target(out) unless out.nil?
          o[:err] = err == :out ? [:child, :out] : direct_target(err) unless err.nil?
          o[:chdir] = chdir if chdir
          o[:pgroup] = pgroup unless pgroup.nil?
          DirectChild.new(Process.spawn(env, *args, o))
        end

        def direct_target(v)
          return File::NULL if v == :null
          v.respond_to?(:to_io) ? v.to_io : v
        end
      end

      attr_reader :pid, :spawned

      # Launches a starter process (see .start; one per process is the
      # usual use, but specs make their own).
      def initialize
        mine, theirs = UNIXSocket.pair(:STREAM)
        server = File.expand_path('starter/server.rb', __dir__)
        env = { 'RUBYOPT' => nil, 'RUBYLIB' => nil }
        @pid = Process.spawn(env, RbConfig.ruby, '--disable-gems', server, '3', 3 => theirs, in: File::NULL, pgroup: true)
        theirs.close
        @sock = mine
        @sock.sync = true
        @send_lock = Mutex.new
        @lock = Mutex.new
        @children = {}
        @serial = 0
        @spawned = 0
        @dead = false
        @closed = false
        @owner = Process.pid
        @reaper = Process.detach(@pid)
        @reaper.name = 'MB::Sound::Starter'
        ready = @sock.wait_readable(READY_TIMEOUT) && (JSON.parse(@sock.gets.to_s) rescue nil)
        unless ready && ready['ready']
          close
          raise Dead, 'the starter process did not say it was ready'
        end
        @reader = Thread.new { read_replies }
        @reader.name = 'MB::Sound::Starter'
        ExitClose.register(self)
      end

      # True once the starter process is gone (or this object closed).
      def dead? = @dead

      # Number of children still running.
      def children = @lock.synchronize { @children.length }

      # Asks the starter to start [env, args] (see Starter.spawn for
      # +opts+).  Returns a StarterChild; raises Dead if the starter is
      # gone, and the same SystemCallError as Process.spawn if the command
      # can't start.
      def spawn_child(env, args, in: nil, out: nil, err: nil, chdir: nil, pgroup: nil)
        raise Dead, 'process starter is closed' if @dead || @owner != Process.pid
        opened = []
        ios = [target(binding.local_variable_get(:in), 0, opened), target(out, 1, opened)]
        ios << (err == :out ? ios[1] : target(err, 2, opened))
        child = nil
        @lock.synchronize do
          raise Dead, 'process starter is closed' if @dead
          @serial += 1
          child = StarterChild.new(self, @serial)
          @children[@serial] = child
        end
        dir = chdir || (Dir.pwd rescue nil)
        msg = { op: 'spawn', id: child.id, argv: args, env: child_env(env), chdir: dir, pgroup: pgroup, fds: [0, 1, 2] }
        begin
          @send_lock.synchronize { Frame.put(@sock, msg, ios) }
        rescue SystemCallError, IOError => e
          lost!
          raise Dead, "process starter: #{e.message}"
        end
        reply = child.take_reply(TIMEOUT)
        if reply.nil?
          # (killed, not left: the descriptors in its unread frames stay
          # open while it lives, so a pipe sent to it would never end)
          lost!
          Process.kill(:KILL, @pid) rescue nil
          @reaper.join(2)
          raise Dead, "the process starter did not answer in #{TIMEOUT} s"
        end
        raise Dead, 'the process starter exited' if reply['dead']
        if reply['error']
          @lock.synchronize { @children.delete(child.id) }
          raise starter_error(reply)
        end
        child.started(reply['pid'])
        @spawned += 1
        child
      ensure
        opened&.each { |io| io.close rescue nil }
      end

      # Asks the starter to send +signal+ to child +id+ if it still runs.
      def kill_child(id, signal)
        sig = signal.is_a?(Integer) ? Signal.signame(signal) : signal.to_s.delete_prefix('SIG')
        @send_lock.synchronize { Frame.put(@sock, { op: 'kill', child: id, signal: sig }) }
      rescue SystemCallError, IOError
        nil
      end

      # True if the starter answers within +timeout+ seconds.
      def ping(timeout = 2.0)
        child = nil
        @lock.synchronize {
          return false if @dead
          child = StarterChild.new(self, @serial += 1)
          @children[child.id] = child
        }
        @send_lock.synchronize { Frame.put(@sock, { op: 'ping', id: child.id }) }
        r = child.take_reply(timeout)
        @lock.synchronize { @children.delete(child.id) }
        r && r['pong'] ? true : false
      rescue SystemCallError, IOError
        false
      end

      # Ends the starter process (children it started keep running) and
      # waits for it.  Only the process that launched it closes it (a fork
      # inherits the object, not the starter).
      def close
        return unless @owner == Process.pid
        return if @closed
        @closed = true
        @send_lock.synchronize { Frame.put(@sock, { op: 'quit' }) } rescue nil
        @sock.close rescue nil
        unless @reaper.join(2)
          Process.kill(:KILL, @pid) rescue nil
          @reaper.join(2)
        end
        @reader&.join(2)
        lost!
        ExitClose.unregister(self)
        nil
      end

      private

      # The console's environment with +env+ applied (nil values unset), as
      # Process.spawn would give the child.
      def child_env(env)
        e = ENV.to_h
        env.each { |k, v| v.nil? ? e.delete(k.to_s) : e[k.to_s] = v.to_s }
        e
      end

      # The IO to send as descriptor +fd+ for redirection +v+ (opening
      # files into +opened+, closed after sending).
      def target(v, fd, opened)
        case v
        when nil
          std = [STDIN, STDOUT, STDERR][fd]
          return std unless std.closed?
          v = :null
        end
        v = File::NULL if v == :null
        return v.to_io if v.respond_to?(:to_io)
        raise ArgumentError, "Starter.spawn: redirect #{v.inspect} (an IO, a path, :null, or err: :out)" unless v.is_a?(String)
        File.open(v, fd == 0 ? 'r' : 'w').tap { |io| opened << io }
      end

      def starter_error(reply)
        name = reply['error'].to_s
        klass = name.start_with?('Errno::') && Errno.const_defined?(name.delete_prefix('Errno::'), false) ? Errno.const_get(name.delete_prefix('Errno::')) : nil
        return klass.new(reply['detail']) if klass && klass < SystemCallError
        (name == 'TypeError' ? TypeError : ArgumentError).new(reply['detail'].to_s)
      end

      def read_replies
        while (line = @sock.gets)
          msg = begin
            JSON.parse(line)
          rescue JSON::ParserError
            next
          end
          if (id = msg['exit'])
            child = @lock.synchronize { @children.delete(id) }
            child&.finish(Status.new(child.pid, msg['status'], msg['signal']))
          elsif (id = msg['id'])
            child = @lock.synchronize { @children[id] }
            child&.reply(msg)
          end
        end
      rescue IOError, SystemCallError
        nil
      ensure
        lost!
        @sock.close rescue nil
      end

      # The starter is gone: waiting spawns fall back, running children end
      # with an unknown status.
      def lost!
        list = @lock.synchronize {
          @dead = true
          l = @children.values
          @children.clear
          l
        }
        list.each do |c|
          if c.pid
            c.finish(Status.unknown(c.pid))
          else
            c.reply('dead' => true)
          end
        end
      end
    end
  end
end
