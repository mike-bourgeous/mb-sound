#!/usr/bin/env ruby
# Shares a REPL (Pry, or any command) with other terminals over a socket,
# without screen or tmux: the host runs the program on a pty, keeps a
# terminal model of its screen (MB::Term::VT), and sends each viewer the
# cells that changed (or the program's raw bytes); viewers send keys back.
# A prototype for the maintainer's first application of mb-term
# (term-extract-1, 2026-10-29), not a product: see "Limits" below.
#
# Two machines, over SSH (the safe way; the host listens on localhost only):
#
#     host$   ruby examples/share_repl.rb host                 # Pry; prints a token
#     host$   ruby examples/share_repl.rb host -- bash         # or any command
#     guest$  ssh -N -L 7777:localhost:7777 host &              # a tunnel
#     guest$  ruby examples/share_repl.rb join -t TOKEN        # watch and type
#     guest$  ruby examples/share_repl.rb join -t VIEWTOKEN    # watch only
#
# Ctrl-] then q quits (the host: ends the session; a guest: leaves it);
# Ctrl-] Ctrl-] sends a Ctrl-].  Late joiners get the whole screen first.
#
#     ruby examples/share_repl.rb measure    # bytes per second, frames vs raw
#
# Security: the host binds 127.0.0.1 unless --bind says otherwise (then it
# prints a warning: plain TCP carries the token and every key unencrypted),
# every client must send a token within 5 s (compared in constant time;
# a wrong one waits 1 s and closes), a second token joins read-only, and at
# most --max clients join.
#
# Limits (what a real version would need): TLS or SSH channels instead of
# plain TCP (or a Unix socket with file permissions); real accounts
# instead of shared tokens; resize negotiation (the host's size is fixed;
# smaller viewers see the screen clipped and wrapped); scrollback for
# viewers; raw mode is exact only for viewers present from the start (a
# late raw viewer gets the screen's cells and cursor, not the program's
# modes, such as scroll regions); no flow control beyond dropping viewers
# who fall too far behind.
require 'io/console'
require 'optparse'
require 'securerandom'
require 'socket'
require 'timeout'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'mb/term'

module ShareRepl
  PROTOCOL = 'MBTERM1'
  MAX_MESSAGE = 4 << 20
  NAV = "\x1D" # Ctrl-]

  # Messages are a type byte, a 4-byte big-endian length, and the payload.
  # Client to host: H (hello: "MBTERM1\ntoken\nframes|raw\ncolor mode"),
  # K (key bytes).  Host to client: S ("rows cols role mode"), F (bytes to
  # write to the terminal), E (an error, then the host closes).
  module Wire
    module_function

    def write(io, type, payload = '')
      payload = payload.b
      io.write(type + [payload.bytesize].pack('N') + payload)
    end

    def read(io)
      head = io.read(5)
      return nil if head.nil? || head.bytesize < 5
      type = head[0]
      len = head.byteslice(1, 4).unpack1('N')
      raise IOError, "message too long (#{len} bytes)" if len > MAX_MESSAGE
      payload = len.zero? ? +''.b : io.read(len)
      return nil if payload.nil? || payload.bytesize < len
      [type, payload]
    end
  end

  # Constant-time String comparison (tokens).
  def self.same?(a, b)
    a = a.to_s.b
    b = b.to_s.b
    return false unless a.bytesize == b.bytesize
    a.bytes.zip(b.bytes).reduce(0) { |acc, (x, y)| acc | (x ^ y) }.zero?
  end

  # One viewer: a socket (or the host's own terminal) with its own last
  # frame, so a slow viewer gets one bigger frame later instead of a queue.
  class Viewer
    attr_reader :io, :role, :mode, :color, :name, :bytes_sent
    attr_accessor :prev, :cursor, :offset

    def initialize(io, role:, mode:, color:, name:, local: false)
      @io = io
      @role = role
      @mode = mode
      @color = color
      @name = name
      @local = local
      @bytes_sent = 0
      @prev = nil
      @cursor = nil
      @offset = 0
      @raw = Thread::Queue.new
      @raw_bytes = 0
      @wake = Thread::Queue.new
      @closed = false
    end

    def local? = @local
    def closed? = @closed

    # Sends terminal bytes (raises IOError when the viewer is gone).
    def send_bytes(bytes)
      return if bytes.empty?
      if @local
        @io.write(bytes)
        @io.flush
      else
        Wire.write(@io, 'F', bytes)
      end
      @bytes_sent += bytes.bytesize
    end

    # Raw mode: queues a piece of the program's output.
    def push_raw(piece)
      @raw_bytes += piece.bytesize
      raise IOError, "#{@name} fell #{@raw_bytes} bytes behind" if @raw_bytes > MAX_MESSAGE
      @raw << piece
    end

    def pop_raw
      piece = @raw.pop
      @raw_bytes -= piece.bytesize if piece
      piece
    end

    def wake = @wake << true
    def wait_wake = @wake.pop

    def close
      return if @closed
      @closed = true
      @raw.close
      @wake.close
      @io.close unless @local || @io.closed?
    rescue IOError
      nil
    end
  end

  # The host: a program on a pty, its VT, and the viewers.
  class Host
    attr_reader :port, :repl, :viewers

    def initialize(command:, rows:, cols:, bind: '127.0.0.1', port: 7777, token: nil, view_token: nil, fps: 30, max: 8, log: $stderr)
      @rows = rows
      @cols = cols
      @bind = bind
      @want_port = port
      @token = token || SecureRandom.hex(16)
      @view_token = view_token
      @fps = fps
      @max = max
      @log = log
      @lock = Mutex.new # (viewers, the shared grid)
      @viewers = []
      @repl = if command
                MB::Term::Input::ReplHost.new(rows: rows, cols: cols, mode: :command, command: command, env: { 'TERM' => 'xterm-256color' })
              else
                MB::Term::Input::ReplHost.new(rows: rows, cols: cols, mode: :thread, pry: { pager: false })
              end
      @grid = MB::Term::Grid.new(cols, rows)
      @stream = 0 # (raw bytes mirrored so far)
      host = self
      mirror = Object.new
      mirror.define_singleton_method(:write) { |piece| host.mirrored(piece) }
      @repl.mirror = mirror
    end

    attr_reader :token, :view_token

    def start
      @server = TCPServer.new(@bind, @want_port)
      @port = @server.addr[1]
      unless %w[127.0.0.1 ::1 localhost].include?(@bind)
        @log.puts "WARNING: listening on #{@bind}:#{@port}: anyone who reaches this port with the token can type into this session, " \
                  'and plain TCP carries the token and every key unencrypted.  Prefer the default (localhost) and ssh -L.'
      end
      @repl.start
      @accept = Thread.new { accept_loop }
      @ticker = Thread.new { tick_loop }
      self
    end

    def stop
      @stopping = true
      @server&.close rescue nil
      @accept&.kill
      @ticker&.kill
      @lock.synchronize { @viewers.dup }.each { |v| drop(v) }
      @repl.stop
    end

    def exited? = @repl.exited?

    # Adds a viewer (the host's terminal, or an accepted socket): it gets
    # the whole screen first, then what changes.
    def add(viewer)
      @repl.synchronize do
        @lock.synchronize do
          if viewer.mode == :raw
            @grid_raw = MB::Term::Grid.new(@cols, @rows)
            @repl.vt.draw(@grid_raw, 0, 0, @cols, @rows, all: true)
            viewer.offset = @repl.vt.bytes_fed # (raw bytes after this point follow the snapshot)
            snapshot = "\e[H\e[2J" + @grid_raw.frame(nil, viewer.color, sync: false) + cursor_bytes
            @repl.vt.invalidate # (the shared grid redraws everything at the next tick)
            viewer.send_bytes(snapshot)
          else
            viewer.prev = MB::Term::Grid.new(@cols, @rows)
            viewer.send_bytes("\e[H\e[2J")
          end
          @viewers << viewer
        end
      end
      Thread.new { viewer_loop(viewer) }
      @lock.synchronize { viewer.wake unless viewer.closed? }
      log "#{viewer.name} joined (#{viewer.role}, #{viewer.mode})"
    end

    # Keys from a viewer.
    def keys(viewer, bytes)
      return unless viewer.role == :rw
      @repl.write(bytes)
    end

    # From the pty reader: the program's output (after the VT has it).
    def mirrored(piece)
      @lock.synchronize do
        start = @stream
        @stream += piece.bytesize
        @viewers.each do |v|
          next unless v.mode == :raw && !v.closed?
          skip = v.offset - start
          next if skip >= piece.bytesize
          v.push_raw(skip > 0 ? piece.byteslice(skip, piece.bytesize - skip) : piece)
        rescue IOError, ClosedQueueError => e
          log "#{v.name}: #{e.message}"
          v.close
        end
      end
    end

    def log(msg)
      @log&.puts("share_repl: #{msg}") unless @quiet_log
    end

    attr_writer :quiet_log

    private

    def cursor_bytes
      vt = @repl.vt
      "\e[#{vt.row + 1};#{vt.col + 1}H#{vt.cursor_visible? ? "\e[?25h" : "\e[?25l"}"
    end

    def accept_loop
      loop do
        sock = @server.accept
        Thread.new { handshake(sock) }
      end
    rescue IOError, SystemCallError
      nil
    end

    def handshake(sock)
      sock.sync = true
      type, payload = Timeout.timeout(5) { Wire.read(sock) }
      proto, token, mode, color = payload.to_s.force_encoding(Encoding::UTF_8).split("\n")
      role = if type == 'H' && proto == PROTOCOL && ShareRepl.same?(token, @token) then :rw
             elsif type == 'H' && proto == PROTOCOL && @view_token && ShareRepl.same?(token, @view_token) then :ro
             end
      unless role
        sleep 1
        Wire.write(sock, 'E', 'bad token or protocol')
        sock.close
        log "refused #{sock.remote_address.inspect_sockaddr rescue '?'}"
        return
      end
      if @lock.synchronize { @viewers.count { |v| !v.local? } } >= @max
        Wire.write(sock, 'E', "full (#{@max} viewers)")
        sock.close
        return
      end
      mode = mode == 'raw' ? :raw : :frames
      color = %w[truecolor ansi256 ansi16 none].include?(color) ? color.to_sym : :truecolor
      v = Viewer.new(sock, role: role, mode: mode, color: color, name: (sock.remote_address.inspect_sockaddr rescue 'viewer'))
      Wire.write(sock, 'S', "#{@rows} #{@cols} #{role} #{mode}")
      add(v)
      while (msg = Wire.read(sock))
        keys(v, msg[1]) if msg[0] == 'K'
      end
    rescue Timeout::Error, IOError, SystemCallError => e
      log "viewer: #{e.class}: #{e.message}"
    ensure
      drop(v) if v
      sock.close rescue nil
    end

    def drop(v)
      @lock.synchronize { @viewers.delete(v) }
      v.close
    end

    # Each tick: the VT's changed rows into the shared grid, then every
    # frame viewer is woken to send its own diff.
    def tick_loop
      period = 1.0 / @fps
      loop do
        sleep period
        next unless @repl.changed! || cursor_moved?
        @repl.synchronize do
          @lock.synchronize do
            @repl.vt.draw(@grid, 0, 0, @cols, @rows)
            @cursor = cursor_bytes
            @viewers.each { |v| v.wake if v.mode == :frames && !v.closed? }
          end
        end
      end
    end

    def cursor_moved?
      @repl.synchronize { cursor_bytes } != @cursor
    end

    def viewer_loop(v)
      if v.mode == :raw
        while (piece = v.pop_raw)
          v.send_bytes(piece)
        end
      else
        while v.wait_wake
          bytes = @lock.synchronize {
            b = @grid.frame(v.prev, v.color, sync: true)
            b = '' if b == empty_frame(v.color)
            v.prev.copy_from(@grid)
            c = @cursor || cursor_bytes
            b += c if !b.empty? || c != v.cursor
            v.cursor = c
            b
          }
          v.send_bytes(bytes)
        end
      end
    rescue IOError, SystemCallError, ClosedQueueError
      nil
    ensure
      drop(v)
    end

    def empty_frame(color)
      (@empty ||= {})[color] ||= MB::Term::Grid.new(1, 1).frame(MB::Term::Grid.new(1, 1), color, sync: true)
    end
  end

  # Raw terminal input until Ctrl-] q; Ctrl-] Ctrl-] sends Ctrl-].
  def self.read_keys(input)
    nav = false
    loop do
      data = input.readpartial(4096)
      out = +''.b
      data.each_char do |c|
        if nav
          nav = false
          if c == 'q'
            yield out unless out.empty?
            return
          end
          out << NAV if c == NAV
        elsif c == NAV
          nav = true
        else
          out << c
        end
      end
      yield out unless out.empty?
    end
  rescue EOFError, IOError
    nil
  end

  def self.with_terminal(out = $stdout, input = $stdin)
    out.write("\e[?1049h\e[H\e[2J")
    input.raw { yield }
  ensure
    out.write("\e[0m\e[?25h\e[?1049l")
    out.flush
  end

  def self.host(opts, command)
    rows, cols = opts[:size] || ($stdin.tty? ? $stdin.winsize : [30, 100])
    h = Host.new(command: command.empty? ? nil : command, rows: rows, cols: cols, bind: opts[:bind], port: opts[:port],
                 token: opts[:token], view_token: opts[:view_token], fps: opts[:fps])
    h.start
    $stderr.puts "share_repl: #{command.empty? ? 'Pry' : command.join(' ')} at #{rows}x#{cols} on #{opts[:bind]}:#{h.port}"
    $stderr.puts "share_repl: token #{h.token}#{h.view_token ? ", view-only token #{h.view_token}" : ''}"
    $stderr.puts 'share_repl: Ctrl-] q ends the session'
    sleep 1.5 if $stdin.tty? # (time to read the token)
    if $stdin.tty?
      h.quiet_log = true
      with_terminal do
        local = Viewer.new($stdout, role: :rw, mode: :frames, color: :truecolor, name: 'host', local: true)
        h.add(local)
        watcher = Thread.new { sleep 0.2 until h.exited?; Process.kill(:TERM, Process.pid) rescue nil }
        begin
          read_keys($stdin) { |b| h.keys(local, b) }
        rescue SignalException
          nil
        end
        watcher.kill
      end
    else
      sleep 0.5 until h.exited?
    end
  ensure
    h&.stop
  end

  def self.join(opts)
    sock = TCPSocket.new(opts[:connect], opts[:port])
    sock.sync = true
    Wire.write(sock, 'H', [PROTOCOL, opts[:token], opts[:raw] ? 'raw' : 'frames', opts[:color]].join("\n"))
    type, payload = Wire.read(sock)
    abort "share_repl: #{payload}" if type == 'E'
    abort 'share_repl: no answer' unless type == 'S'
    rows, cols, role, mode = payload.split
    if $stdout.tty?
      lr, lc = $stdout.winsize
      $stderr.puts "share_repl: the session is #{rows}x#{cols}, this terminal #{lr}x#{lc}: it will be clipped" if lr < rows.to_i || lc < cols.to_i
    end
    $stderr.puts "share_repl: joined #{rows}x#{cols} (#{role}, #{mode}); Ctrl-] q leaves"
    sleep 1
    received = 0
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    with_terminal do
      reader = Thread.new do
        while (msg = Wire.read(sock))
          case msg[0]
          when 'F'
            $stdout.write(msg[1])
            $stdout.flush
            received += msg[1].bytesize
          when 'E'
            break
          end
        end
        Process.kill(:TERM, Process.pid) rescue nil
      end
      begin
        read_keys($stdin) { |b| Wire.write(sock, 'K', b) if role == 'rw' }
      rescue SignalException
        nil
      end
      reader.kill
    end
    secs = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    $stderr.puts format('share_repl: %d bytes in %.1f s (%.0f B/s)', received, secs, received / secs)
  ensure
    sock&.close
  end

  # Bytes per second of a scripted Pry session (human-speed typing, then a
  # scrolling burst) to two viewers on real sockets, one getting frames,
  # one raw bytes.
  def self.measure(opts)
    h = Host.new(command: [RbConfig.ruby, '-e', 'require "pry"; Pry.config.history_file = File::NULL; Pry.start'], rows: 30, cols: 100, port: 0, fps: opts[:fps], log: nil)
    h.start
    counts = {}
    socks = { frames: 'frames', raw: 'raw' }.map do |name, mode|
      s = TCPSocket.new('127.0.0.1', h.port)
      Wire.write(s, 'H', [PROTOCOL, h.token, mode, 'truecolor'].join("\n"))
      Wire.read(s)
      counts[name] = Hash.new(0)
      Thread.new do
        while (msg = Wire.read(s))
          counts[name][@phase] += msg[1].bytesize + 5 if msg[0] == 'F'
          counts[name][:"#{@phase} messages"] += 1
        end
      rescue IOError, SystemCallError
        nil
      end
      s
    end
    @phase = :start
    sleep 3 # (Pry starts)
    script = ['x = (1..20).map { |i| i * i }', 'x.select(&:even?).sum', 'def hi(n) = "hi #{n}"', 'hi :there', '{ a: 1, b: [2, 3], c: "four" }']
    @phase = :typing
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    script.each do |line|
      line.each_char do |c|
        h.repl.write(c)
        sleep 0.1 # (10 keys a second)
      end
      h.repl.write("\r")
      sleep 0.5
    end
    typing = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
    sleep 0.3
    @phase = :burst
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    h.repl.write("puts (1..5000).map { |i| \"line \#{i} \" + 'x' * 60 }; :done\r")
    sleep 0.05 until h.repl.vt.text.include?('=> :done')
    sleep 0.2
    burst = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
    @phase = :end
    sleep 0.2
    puts "share_repl measure: Pry 30x100, #{opts[:fps]} frames/s, #{script.sum(&:length)} keys typed at 10/s (#{typing.round(1)} s), " \
         "then 5000 lines of 75 characters (#{burst.round(2)} s); bytes on the socket including 5-byte message headers"
    puts
    puts '| | frames | raw bytes |'
    puts '|---|---|---|'
    puts format('| typing: bytes/s | %.0f | %.0f |', counts[:frames][:typing] / typing, counts[:raw][:typing] / typing)
    puts format('| typing: bytes per key | %.0f | %.0f |', counts[:frames][:typing] / script.sum { |l| l.length + 1 }.to_f, counts[:raw][:typing] / script.sum { |l| l.length + 1 }.to_f)
    puts format('| typing: messages | %d | %d |', counts[:frames][:"typing messages"], counts[:raw][:"typing messages"])
    puts format('| burst: bytes | %d | %d |', counts[:frames][:burst], counts[:raw][:burst])
    puts format('| burst: bytes/s | %.0f | %.0f |', counts[:frames][:burst] / burst, counts[:raw][:burst] / burst)
    puts format('| burst: messages | %d | %d |', counts[:frames][:"burst messages"], counts[:raw][:"burst messages"])
  ensure
    socks&.each { |s| s.close rescue nil }
    h&.stop
  end
end

if $PROGRAM_NAME == __FILE__
  opts = { bind: '127.0.0.1', connect: 'localhost', port: 7777, fps: 30, color: 'truecolor' }
  parser = OptionParser.new do |o|
    o.banner = "Usage: #{$PROGRAM_NAME} host [options] [-- command ...] | join [options] | measure"
    o.on('-p', '--port N', Integer, 'Port (7777)') { |v| opts[:port] = v }
    o.on('-b', '--bind ADDR', 'Host: address to listen on (127.0.0.1; anything else warns)') { |v| opts[:bind] = v }
    o.on('-c', '--connect HOST', 'Join: host to connect to (localhost: through an ssh -L tunnel)') { |v| opts[:connect] = v }
    o.on('-t', '--token T', 'Host: the read-write token (random if not given); join: the token to send') { |v| opts[:token] = v }
    o.on('-v', '--view-token T', 'Host: a second token that joins read-only') { |v| opts[:view_token] = v }
    o.on('-s', '--size ROWSxCOLS', 'Host: the session size (default: this terminal)') { |v| opts[:size] = v.split('x').map { |n| Integer(n) } }
    o.on('-f', '--fps N', Integer, 'Host: frames per second at most (30)') { |v| opts[:fps] = v }
    o.on('-r', '--raw', 'Join: get the program\'s raw bytes instead of frames') { opts[:raw] = true }
    o.on('--color MODE', 'Join: truecolor, ansi256, ansi16, none') { |v| opts[:color] = v }
  end
  args = parser.parse(ARGV)
  case args.shift
  when 'host' then ShareRepl.host(opts, args)
  when 'join' then ShareRepl.join(opts)
  when 'measure' then ShareRepl.measure(opts)
  else abort parser.help
  end
end
