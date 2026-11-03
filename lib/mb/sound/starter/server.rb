# The process starter's own process (spawner-1, 2026-11-03): a small Ruby
# process (plain Ruby, --disable-gems: about 13 MB) that MB::Sound::Starter
# launches before anything plays, and that starts every later process for
# the console, so the console never forks while audio plays (a fork from
# the console's big heap holds the GVL, so the render thread waits: up to
# 17 ms in the container per start; design/notes/terminal_ui.md).
#
# This file loads only Ruby's socket and json (no mb-sound): it is run as
# `ruby --disable-gems server.rb FD`, FD being one end of a UNIX socket
# pair, and MB::Sound::Starter requires it for the framing (Frame).
#
# Protocol.  To the starter, frames: a 4-byte big-endian length and that
# many bytes of JSON, sent with sendmsg, any file descriptors riding on the
# frame as SCM_RIGHTS (read back with recvmsg asking for exactly the
# frame's remaining bytes, so a read never takes the first byte of the next
# frame and its descriptors):
#   {"op":"spawn","id":N,"argv":[...],"env":{...},"chdir":dir,"pgroup":p,"fds":[0,1,2]}
#     the descriptors become the child's fds, in the order of "fds"; the
#     child gets exactly "env" (unsetenv_others)
#   {"op":"kill","child":N,"signal":"TERM"}  (only if child N runs)
#   {"op":"ping","id":N}
#   {"op":"quit"}
# From it, JSON lines: {"ready":true,"pid":P} once; {"id":N,"pid":P} or
# {"id":N,"error":"Errno::ENOENT","detail":"ffmpegx"} for a spawn;
# {"exit":N,"status":S,"signal":G} when child N ends (always after its
# spawn reply); {"id":N,"pong":true,"children":C} for a ping.
#
# The starter exits at the end of its socket (the console closed it, or
# exited, or crashed); children it started keep running and are reparented.
require 'socket'
require 'json'

module MB
  module Sound
    class Starter
      # Length-prefixed JSON frames with file descriptors (see the file's
      # header comment).
      module Frame
        # The length prefix ("N": 32-bit big-endian).
        HEAD = 4

        # Room for the descriptors of one frame (a few; cmsg headers
        # included).
        CONTROL = 1024

        module_function

        # +h+ (a Hash) as a frame's bytes.
        def pack(h)
          json = JSON.generate(h)
          [json.bytesize].pack('N') + json
        end

        # Sends +h+ on +sock+ with +ios+ (IOs) riding on it.
        def put(sock, h, ios = [])
          data = pack(h)
          ctl = ios.empty? ? [] : [Socket::AncillaryData.unix_rights(*ios)]
          sent = sock.sendmsg(data, 0, nil, *ctl)
          sock.write(data.byteslice(sent..)) if sent < data.bytesize
          nil
        end

        # The next frame on +sock+ as [Hash, IOs], or nil at its end.
        def get(sock)
          ios = []
          head = read_exact(sock, HEAD, ios) or return nil
          body = read_exact(sock, head.unpack1('N'), ios) or return nil
          [JSON.parse(body), ios]
        rescue StandardError
          ios.each { |io| io.close rescue nil }
          raise
        end

        # Exactly +n+ bytes from +sock+ (nil at its end), adding any
        # descriptors received to +ios+.
        def read_exact(sock, n, ios)
          buf = ''.b
          while buf.bytesize < n
            data, _addr, flags, *ctl = sock.recvmsg(n - buf.bytesize, 0, CONTROL, scm_rights: true)
            return nil if data.nil? || data.empty?
            ctl.each { |c| ios.concat(c.unix_rights) if c.cmsg_is?(:SOCKET, :RIGHTS) }
            raise IOError, 'process starter: descriptors lost (MSG_CTRUNC)' if flags.to_i & Socket::MSG_CTRUNC != 0
            buf << data
          end
          buf
        end
      end

      # The starter's loop (see the file's header comment).
      class Server
        # Runs a starter on descriptor +fd+ (a UNIX stream socket) until
        # its end.
        def self.run(fd)
          new(UNIXSocket.for_fd(fd)).run
        end

        def initialize(sock)
          @sock = sock
          @sock.close_on_exec = true # (a descriptor given at launch: children mustn't inherit it)
          @sock.sync = true
          @out = Mutex.new
          @lock = Mutex.new
          @live = {}
        end

        def run
          say(ready: true, pid: Process.pid)
          loop do
            msg, ios = Frame.get(@sock)
            break unless msg
            begin
              break if handle(msg, ios) == :quit
            ensure
              ios.each { |io| io.close rescue nil }
            end
          end
        rescue Errno::ECONNRESET, Errno::EPIPE, IOError
          nil
        end

        private

        def handle(msg, ios)
          case msg['op']
          when 'spawn' then spawn_child(msg, ios)
          when 'kill' then kill(msg)
          when 'ping' then @lock.synchronize { say(id: msg['id'], pong: true, children: @live.length) }
          when 'quit' then :quit
          end
        end

        def spawn_child(msg, ios)
          id = msg['id']
          opts = { unsetenv_others: true }
          chdir = msg['chdir']
          opts[:chdir] = chdir if chdir && File.directory?(chdir)
          opts[:pgroup] = msg['pgroup'] unless msg['pgroup'].nil?
          Array(msg['fds']).each_with_index { |fd, i| opts[Integer(fd)] = ios[i] if ios[i] }
          # (argv as Process.spawn takes it: one String may run through the
          # shell, [[cmd, argv0], ...] doesn't)
          pid = Process.spawn(msg['env'] || {}, *msg['argv'], opts)
          @lock.synchronize { @live[id] = pid }
          say(id: id, pid: pid)
          Thread.new do
            _, st = Process.wait2(pid)
            @lock.synchronize { @live.delete(id) }
            say(exit: id, status: st.exitstatus, signal: st.termsig)
          end
        rescue SystemCallError, ArgumentError, TypeError => e
          detail = e.message
          if e.is_a?(SystemCallError)
            base = e.class.new.message
            detail = detail.delete_prefix(base).delete_prefix(' - ')
          end
          say(id: id, error: e.class.name, detail: detail)
        end

        def kill(msg)
          @lock.synchronize {
            pid = @live[msg['child']]
            Process.kill(msg['signal'] || 'TERM', pid) if pid
          }
        rescue SystemCallError, ArgumentError
          nil
        end

        def say(h)
          line = "#{JSON.generate(h)}\n"
          @out.synchronize { @sock.write(line) }
        rescue Errno::EPIPE, Errno::ECONNRESET, IOError
          nil
        end
      end
    end
  end
end

MB::Sound::Starter::Server.run(Integer(ARGV[0])) if $PROGRAM_NAME == __FILE__ && ARGV[0]
