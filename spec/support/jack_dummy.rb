require 'tmpdir'
require 'fileutils'

# Starts a private JACK server with the dummy driver (no sound card), so
# MIDI specs can send real messages through JACK MIDI ports.  The server
# gets a unique name, and JACK_DEFAULT_SERVER points libjack (and RtMidi's
# JACK clients) at it.
#
# Usage in a spec file:
#     before(:context) { @jack_error = JackDummy.start }
#     after(:context) { JackDummy.stop }
#     before(:each) { skip @jack_error if @jack_error }
#
# Several spec processes (e.g. agents in other worktrees) share one machine's
# JACK state, which has three limits (measured with jackd2 1.9.22,
# 2026-10-05):
#
# - Shared memory: every JACK2 server maps about 38-40 MB of /dev/shm
#   whatever its --port-max (16 ports: 38.2 MB, 64: 39.3 MB), so Docker's
#   64 MB /dev/shm holds only one.  A second server dies with SIGBUS, often
#   taking the first with it.  So servers started here take turns, through
#   an exclusive lock (LOCK_PATH) held from #start to #stop, and wait while
#   another server (one started without the lock: an older checkout, or a
#   user's) leaves too little room (#wait_for_room).
# - The server registry (/dev/shm/jack-shm-registry) has 8 server slots.  A
#   server that dies without cleaning up (SIGKILL, SIGBUS) keeps its slot,
#   and JACK only reclaims a dead server's slot for a server of the same
#   name, so dead servers with unique names fill the registry ("Too many
#   servers already active").  #start frees the slots of dead spec servers
#   (see #free_slot).
# - JACK's metadata database (/dev/shm/jack_db-UID, Berkeley DB) is shared
#   by every server of a user.  A server that crashes while holding its
#   mutex makes every later server hang at startup (with SIGTERM blocked).
#   #start removes it when no jackd is running (the last server to stop
#   normally removes it too).
#
# Servers also run under `setpriv --pdeathsig TERM`, so they stop (cleanly,
# freeing their slot) when the spec process dies without running #stop, and
# #stop runs at exit.
module JackDummy
  SHM_DIR = '/dev/shm'

  # The lock that serializes spec JACK servers, in /dev/shm itself (the
  # shared resource; TMPDIR may differ between processes) when it exists.
  LOCK_PATH = File.join(File.directory?(SHM_DIR) ? SHM_DIR : Dir.tmpdir, "mbspec-jackd-#{Process.uid}.lock")

  # How long #start waits for another spec process's server to stop.
  LOCK_TIMEOUT = 300

  # Free /dev/shm space a server needs (see the module comment).
  SHM_NEEDED = 42 << 20

  # How long #start waits for a server to accept clients.
  START_TIMEOUT = 10

  REGISTRY_PATH = File.join(SHM_DIR, 'jack-shm-registry')
  REGISTRY_MAGIC = 0x4a41434b # 'JACK'
  REGISTRY_SERVERS = 8 # MAX_SERVERS in JACK2's shm.h
  REGISTRY_SERVER_SIZE = 4 + 257 + 3 # pid_t, name[JACK_SERVER_NAME_SIZE + 1], padding
  REGISTRY_HEADER_SIZE = 24 + REGISTRY_SERVERS * REGISTRY_SERVER_SIZE

  class << self
    # The current server's name, or nil.
    attr_reader :name

    # Starts the server and waits until a client can connect.  Returns nil
    # on success, or a reason to skip the specs.
    def start
      return 'jackd is not installed (apt install jackd2)' unless system('which jackd > /dev/null 2>&1')
      raise 'JackDummy is already running a server' if @pid

      lock or return "another spec process kept its JACK dummy server for #{LOCK_TIMEOUT} s (#{LOCK_PATH})"

      @name = "mbspec#{Process.pid}_#{rand(1 << 30)}"
      @old_server = ENV['JACK_DEFAULT_SERVER']
      ENV['JACK_DEFAULT_SERVER'] = @name

      reason = nil
      2.times do
        clean_stale
        wait_for_room
        reason = launch
        return nil if reason.nil?
      end

      stop
      "the JACK dummy server did not start: #{reason}"
    end

    # Stops the server and restores JACK_DEFAULT_SERVER, closing this
    # process's shared JACK client first.  Safe to call more than once.
    def stop
      MB::Sound::FastAudio.jack_close if @pid
      if @pid
        # A server that died early explains failing JACK specs
        _, status = Process.wait2(@pid, Process::WNOHANG) rescue nil
        if status
          how = status.signaled? ? Signal.signame(status.termsig) : "exit #{status.exitstatus}"
          warn "\nThe JACK dummy server #{@name} stopped during the specs (#{how}): #{log_summary}"
        else
          terminate(@pid, child: true)
        end
        @pid = nil
      end
      if @name
        @old_server ? ENV['JACK_DEFAULT_SERVER'] = @old_server : ENV.delete('JACK_DEFAULT_SERVER')
        @name = nil
      end
      unlock
    end

    # The servers in JACK's registry, as [[slot, pid, name], ...] (empty if
    # the registry is missing or its layout is not the one this code knows).
    def registry_servers
      data = File.binread(REGISTRY_PATH, REGISTRY_HEADER_SIZE) rescue nil
      return [] if data.nil? || data.bytesize < REGISTRY_HEADER_SIZE

      magic, hdr_len = data.unpack('L<x12l<')
      return [] unless magic == REGISTRY_MAGIC && hdr_len == REGISTRY_HEADER_SIZE

      REGISTRY_SERVERS.times.filter_map { |i|
        pid, prefix = data[24 + i * REGISTRY_SERVER_SIZE, REGISTRY_SERVER_SIZE].unpack('l<Z*')
        # The registry holds "jack-UID:NAME:" prefixes
        name = prefix[/\Ajack-#{Process.uid}:(.*):\z/, 1]
        [i, pid, name] if pid != 0 && name
      }
    end

    # Pids of running jackd processes by server name (nil for servers
    # started without -n).
    def running_servers
      Dir.glob('/proc/[0-9]*/cmdline').filter_map { |path|
        args = File.binread(path).split("\0") rescue next
        next unless args[0] && File.basename(args[0]) == 'jackd'

        idx = args.index('-n') || args.index('--name')
        [path[%r{/proc/(\d+)/}, 1].to_i, idx && args[idx + 1]]
      }
    end

    private

    # Takes the cross-process lock, waiting up to LOCK_TIMEOUT.  Returns
    # false on timeout.
    def lock
      return true if @lock

      file = File.open(LOCK_PATH, File::RDWR | File::CREAT, 0o666)
      deadline = MB::U.clock_now + LOCK_TIMEOUT
      until file.flock(File::LOCK_EX | File::LOCK_NB)
        if MB::U.clock_now > deadline
          file.close
          return false
        end
        sleep 0.05
      end

      @lock = file
      true
    end

    def unlock
      return unless @lock

      @lock.flock(File::LOCK_UN)
      @lock.close
      @lock = nil
    end

    # Waits up to LOCK_TIMEOUT while other servers run and /dev/shm has less
    # than SHM_NEEDED free (starting anyway then).  Without running servers
    # the new one starts at once: JACK frees the memory of dead servers when
    # a server starts.
    def wait_for_room
      deadline = MB::U.clock_now + LOCK_TIMEOUT
      while running_servers.any? && shm_free < SHM_NEEDED && MB::U.clock_now < deadline
        sleep 0.2
      end
    end

    # Free bytes in /dev/shm (from df; infinite if unknown).
    def shm_free
      avail = `df -Pk #{SHM_DIR} 2>/dev/null`.lines.last&.split&.at(3)
      avail&.match?(/\A\d+\z/) ? avail.to_i * 1024 : Float::INFINITY
    end

    # Starts jackd as @name; returns nil once a client can connect, or the
    # reason it failed (the server is stopped then).
    def launch
      @log = File.join(defined?(SpecTmp) ? SpecTmp::ROOT : Dir.tmpdir, "jackd-#{@name}.log")
      @pid = spawn_server(@name, @log)

      # Wait for the server's socket before connecting: a JACK MIDI output
      # created while no server runs leaks RtMidi's ring buffers (see
      # spec/valgrind/ruby.supp)
      deadline = MB::U.clock_now + START_TIMEOUT
      until MB::U.clock_now > deadline
        _, status = Process.wait2(@pid, Process::WNOHANG)
        if status
          @pid = nil
          return "jackd exited (#{status.signaled? ? Signal.signame(status.termsig) : status.exitstatus}): #{log_summary}"
        end

        return nil if socket?(@name) && connectable?

        sleep 0.1
      end

      terminate(@pid, child: true)
      @pid = nil
      "jackd did not accept clients within #{START_TIMEOUT} s: #{log_summary}"
    end

    # Spawns jackd for server +name+, logging to +log+.  With setpriv, the
    # server gets SIGTERM when this process dies (PR_SET_PDEATHSIG; that
    # follows the spawning thread, which is RSpec's main thread here).
    def spawn_server(name, log)
      cmd = ['jackd', '--no-realtime', '--port-max', '64', '-n', name, '-d', 'dummy', '-r', '48000', '-p', '256']
      cmd = ['setpriv', '--pdeathsig', 'TERM', *cmd] if setpriv?
      spawn(*cmd, out: File::NULL, err: [log, 'w'])
    end

    def setpriv?
      @setpriv = system('setpriv --help > /dev/null 2>&1') if @setpriv.nil?
      @setpriv
    end

    def socket?(name)
      Dir.glob(["#{SHM_DIR}/jack_#{name}_*", "/tmp/jack-#{Process.uid}/jack_#{name}_*"]).any?
    end

    # RtMidi's JACK input only connects when a port opens, so open one
    def connectable?
      MB::Sound::FastMIDI::Output.new(:jack, 'mbspec_probe', nil, 'probe').close
      true
    rescue MB::Sound::FastMIDI::Error
      false
    end

    # The interesting lines of the current server's log.
    def log_summary
      lines = File.readlines(@log, chomp: true) rescue []
      lines = lines.reject { |l| l.empty? || l.match?(/copyright|jackdmp|warranty|free software|under certain conditions/i) }
      lines.empty? ? '(no output)' : lines.first(3).join('; ')
    end

    # Sends SIGTERM to +pid+ and waits up to 5 seconds, then SIGKILLs it (a
    # server stuck at startup has SIGTERM blocked).  +child+ means this
    # process can wait for it.
    def terminate(pid, child:)
      Process.kill('TERM', pid) rescue return
      deadline = MB::U.clock_now + 5
      until MB::U.clock_now > deadline
        return if child ? Process.wait(pid, Process::WNOHANG) : !alive?(pid)

        sleep 0.02
      end

      Process.kill('KILL', pid) rescue nil
      Process.wait(pid) rescue nil if child
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    # The spec process that started a server named +name+, or nil if the
    # name isn't a spec server's.
    def spec_pid(name)
      name.to_s[/\Ambspec(\d+)_\d+\z/, 1]&.to_i
    end

    # Cleans up after spec servers whose processes died (see the module
    # comment).  Runs under the lock, so no other spec server is starting.
    def clean_stale
      return unless File.directory?(SHM_DIR) && File.directory?('/proc')

      # Orphaned servers of dead spec processes (e.g. started before
      # pdeathsig, or by an old checkout)
      running_servers.each do |pid, name|
        owner = spec_pid(name)
        terminate(pid, child: false) if owner && owner != Process.pid && !alive?(owner)
      end

      # A metadata database left by a crashed server
      db = File.join(SHM_DIR, "jack_db-#{Process.uid}")
      FileUtils.rm_rf(db) if File.exist?(db) && running_servers.empty?

      # Registry slots of dead spec servers
      registry_servers.each do |slot, pid, name|
        free_slot(slot, pid) if spec_pid(name) && !alive?(pid)
      end

      # Semaphore and socket files of dead spec servers (small, but they
      # pile up)
      running = running_servers.map(&:last)
      Dir.glob(["#{SHM_DIR}/jack_sem.#{Process.uid}_mbspec*", "#{SHM_DIR}/jack_mbspec*"]).each do |path|
        name = File.basename(path)[/mbspec\d+_\d+/]
        owner = spec_pid(name)
        File.delete(path) rescue nil if owner && !alive?(owner) && !running.include?(name)
      end
    end

    # Frees the registry +slot+ of the dead server +pid+ by zeroing its pid,
    # as JACK does for a dead server's slot when a server of the same name
    # starts.  JACK takes a free slot by its pid alone (and overwrites the
    # name), so a single aligned 4-byte write is enough; JACK guards the
    # registry with a SysV semaphore that Ruby can't take, so the pid is
    # checked again just before writing.  (Starting and stopping a server
    # under the dead one's name also frees the slot, but needs room for a
    # server in /dev/shm, which is what crashed the dead one.)
    def free_slot(slot, pid)
      offset = 24 + slot * REGISTRY_SERVER_SIZE
      File.open(REGISTRY_PATH, 'r+b') do |f|
        f.pwrite([0].pack('l<'), offset) if f.pread(4, offset).unpack1('l<') == pid
      end
    rescue SystemCallError
      nil
    end
  end

  owner = Process.pid
  at_exit { stop if Process.pid == owner }
end
