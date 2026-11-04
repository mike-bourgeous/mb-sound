# The process starter (spawner-1): a small process launched before anything
# plays that starts every later process for the console, handing the
# children's descriptors over a UNIX socket, so the console never forks
# while audio plays.  Round trips (pipes, exit statuses, environment,
# directory, signals, many children at once), the fallbacks (no starter,
# a dead or stopped starter: direct starts with a warning, never a hang),
# forks of the process, and file loads through it while a Session plays.
RSpec.describe(MB::Sound::Starter, :aggregate_failures) do
  let(:starter) { MB::Sound::Starter.current }

  after {
    MB::Sound::Session.default.close
    MB::Sound.use_output(nil)
    MB::Sound.rewind
  }

  it 'runs in the spec process as in bin/sound.rb, small and without mb-sound' do
    expect(starter).not_to be_nil
    expect(starter.ping).to eq(true)
    if File.exist?("/proc/#{starter.pid}/status")
      rss = File.read("/proc/#{starter.pid}/status")[/VmRSS:\s*(\d+)/, 1].to_i
      expect(rss).to be < 30_000 # kB (about 13 MB: plain Ruby, --disable-gems)
      cmd = File.read("/proc/#{starter.pid}/cmdline").split("\0")
      expect(cmd).to include('--disable-gems')
      expect(cmd.last(2).first).to end_with('lib/mb/sound/starter/server.rb')
    end
  end

  describe '.capture' do
    it 'returns stdout, stderr, and the exit status' do
      out, err, st = described_class.capture('sh', '-c', 'echo out; echo err >&2; exit 3')
      expect([out, err]).to eq(["out\n", "err\n"])
      expect(st).to be_a(MB::Sound::Starter::Status)
      expect(st.exitstatus).to eq(3)
      expect(st.success?).to eq(false)
      expect(st.to_s).to match(/\Apid \d+ exit 3\z/)
    end

    it 'merges stderr into stdout, drops it, or feeds stdin' do
      expect(described_class.capture('sh', '-c', 'echo a; echo b >&2', err: :out)[0..1]).to eq(["a\nb\n", nil])
      expect(described_class.capture('sh', '-c', 'echo a; echo b >&2', err: :null)[0..1]).to eq(["a\n", nil])
      out, _, st = described_class.capture('cat', stdin_data: 'piped in')
      expect(out).to eq('piped in')
      expect(st.success?).to eq(true)
      expect(described_class.capture('cat')[0]).to eq('') # (stdin is /dev/null)
    end

    it "gives the child the console's current environment and directory, with changes" do
      ENV['MB_STARTER_SPEC'] = 'now'
      expect(described_class.capture('sh', '-c', 'echo "$MB_STARTER_SPEC $MB_STARTER_EXTRA"')[0]).to eq("now \n")
      expect(described_class.capture({ 'MB_STARTER_EXTRA' => 'x', 'MB_STARTER_SPEC' => nil }, 'sh', '-c', 'echo "[$MB_STARTER_SPEC] $MB_STARTER_EXTRA"')[0]).to eq("[] x\n")
      dir = File.realpath(File.dirname(tmp_path('x')))
      expect(Dir.chdir(dir) { described_class.capture('pwd')[0].strip }).to eq(dir)
      expect(described_class.capture('pwd', chdir: '/')[0].strip).to eq('/')
    ensure
      ENV.delete('MB_STARTER_SPEC')
    end

    it 'raises what Process.spawn raises for a missing program' do
      expect { described_class.capture('mb-sound-no-such-program') }.to raise_error(Errno::ENOENT, /mb-sound-no-such-program/)
      expect(starter.ping).to eq(true)
    end

    it 'runs many children at once' do
      # (children other examples left running, such as an ffmpeg reader of
      # an FFMPEGInput never closed until the GC closes its pipe, count in
      # Starter#children too: 3 suite failures "expected 0, got 1" were
      # such leftovers, fix-flaky-1104; this counts its own)
      left = described_class.spawn('sleep', '30') # (one such leftover)
      before = starter.child_list.map { |c| c[:id] }
      expect(starter.child_list).to include({ id: left.id, pid: left.pid, argv: ['sleep', '30'] })
      spawned = starter.spawned
      got = Array.new(40) { |i| Thread.new { described_class.capture('sh', '-c', "echo #{i}; exit #{i % 5}") } }.map(&:value)
      expect(got.map { |o, _, _| o.to_i }).to eq((0...40).to_a)
      expect(got.map { |_, _, st| st.exitstatus }).to eq((0...40).map { |i| i % 5 })
      # (each Status has its pid, set before its exit line can arrive)
      expect(got.map { |_, _, st| st.pid }).to all(be_a(Integer))
      expect(starter.spawned - spawned).to eq(40)
      # (every capture waited for its status, which drops its child)
      expect(starter.child_list.reject { |c| before.include?(c[:id]) }).to eq([])
      expect(starter.child_list.map { |c| c[:id] }).to include(left.id)
    ensure
      left&.kill(:KILL)
      left&.wait(5)
    end
  end

  describe '.popen' do
    it 'reads from and writes to a child, with its status after closing' do
      io, child = described_class.popen(['sh', '-c', 'head -c 300000 /dev/zero'], 'rb')
      data = io.read
      io.close
      expect(data.bytesize).to eq(300_000)
      expect(data.encoding).to eq(Encoding::BINARY)
      expect(child.wait.success?).to eq(true)

      path = tmp_path('written.txt')
      io, child = described_class.popen(['sh', '-c', "cat > #{path.shellescape}"], 'wb')
      io.write('x' * 100_000)
      io.close
      expect(child.wait(5).success?).to eq(true)
      expect(File.size(path)).to eq(100_000)
    end
  end

  describe '.spawn' do
    it 'signals its children through the starter, and waits with a timeout' do
      child = described_class.spawn('sleep', '30')
      expect(child).to be_a(MB::Sound::Starter::StarterChild)
      expect(child.wait(0.05)).to be_nil
      expect(child.alive?).to eq(true)
      child.kill(:TERM)
      st = child.wait(5)
      expect(st.signaled?).to eq(true)
      expect(st.termsig).to eq(Signal.list['TERM'])
      expect(st.to_s).to include('SIGTERM')
      child.kill(:TERM) # (ended: nothing to signal)
    end

    it 'redirects to files and paths' do
      path = tmp_path('out.txt')
      described_class.spawn('sh', '-c', 'echo to-file; echo err-too >&2', out: path, err: :out).wait(5)
      expect(File.read(path)).to eq("to-file\nerr-too\n")
      File.open(path, 'w') { |f| described_class.spawn('echo', 'io', out: f).wait(5) }
      expect(File.read(path)).to eq("io\n")
    end

    it 'starts directly where no starter runs, and in a fork of the process' do
      old = described_class.use(nil)
      begin
        child = described_class.spawn('true')
        expect(child).to be_a(MB::Sound::Starter::DirectChild)
        expect(child.wait(5).success?).to eq(true)
        expect(described_class.capture('echo', 'direct')[0]).to eq("direct\n")
      ensure
        described_class.use(old)
      end

      r, w = IO.pipe
      pid = fork do
        r.close
        w.puts(described_class.current.nil? ? 'none' : 'inherited')
        w.puts(described_class.capture('echo', 'forked')[0])
        w.close
        exit!(0)
      end
      w.close
      expect(r.read).to eq("none\nforked\n")
      Process.wait(pid)
      r.close
      pid = fork { exit(0) } # (ExitClose at the fork's exit leaves the parent's starter alone)
      Process.wait(pid)
      expect(starter.ping).to eq(true)
    end
  end

  describe 'fallbacks' do
    # A starter of this example, made the process's own (restored after).
    def own_starter
      s = described_class.new
      @old = described_class.use(s)
      @own = s
    end

    after {
      if @own
        Process.kill(:CONT, @own.pid) rescue nil
        @own.close
        described_class.use(@old)
      end
    }

    it "falls back to direct starts when the starter dies, warning once per call site; its children's statuses are unknown" do
      s = own_starter
      child = described_class.spawn('sleep', '30')
      Process.kill(:KILL, s.pid)
      st = child.wait(5)
      expect(st).not_to be_nil
      expect(st.unknown?).to eq(true)
      expect(st.success?).to be_nil
      expect(st.to_s).to include('unknown')
      Process.kill(:KILL, child.pid) rescue nil
      expect(s.dead?).to eq(true)
      expect(described_class.current).to be_nil

      outs = []
      expect {
        2.times { outs << described_class.capture('echo', 'still works')[0] }
      }.to output(/the process starter exited; starting echo directly/).to_stderr
      expect(outs).to eq(["still works\n"] * 2)
      expect { described_class.capture('true') }.to output(/process starter exited/).to_stderr # (another site)
    end

    it "gives up on a starter that doesn't answer (never a hang)" do
      s = own_starter
      stub_const('MB::Sound::Starter::TIMEOUT', 0.3)
      Process.kill(:STOP, s.pid)
      out = nil
      t0 = MB::U.clock_now
      expect { out = described_class.capture('echo', 'x')[0] }.to output(/process starter exited/).to_stderr
      expect(MB::U.clock_now - t0).to be < 3
      expect(out).to eq("x\n")
      expect(s.dead?).to eq(true)
    end

    it "keeps the starter's children running when it closes" do
      s = own_starter
      child = described_class.spawn('sleep', '30')
      pid = child.pid
      s.close
      expect(Process.kill(0, pid)).to eq(1)
      Process.kill(:KILL, pid)
      expect(child.wait(1).unknown?).to eq(true)
    end
  end

  describe 'while a Session plays' do
    before {
      MB::Sound.use_output(MB::Sound::NullOutput.new(channels: 2, buffer_size: 800, sleep: :virtual))
      MB::Sound.bg(:hum, 110.hz.sine.at(-30.db))
      Thread.pass until MB::Sound::Session.default.running?
    }

    it 'loads ffmpeg-backed files through the starter, which the spawn guard accepts' do
      path = tmp_path('arp.flac')
      FileUtils.cp(File.expand_path('../../../test_data/arp_a7.flac', __dir__), path)
      n = starter.spawned
      data = MB::Sound.read(path)
      expect(data.length).to eq(2)
      expect(data[0].length).to be > 10_000
      expect(starter.spawned).to eq(n + 2) # (ffprobe and ffmpeg)
      MB::Sound.write(tmp_path('out.flac'), data)
      expect(starter.spawned).to eq(n + 3)
      expect(SpawnGuard.take).to eq([])
    end

    it 'records a direct start (no starter) in the spawn guard' do
      old = described_class.use(nil)
      begin
        described_class.capture('true')
      ensure
        described_class.use(old)
      end
      list = SpawnGuard.take
      expect(list.length).to eq(1)
      expect(list.first).to match(%r{spawn `true` from lib/mb/sound/starter\.rb:\d+})
    end
  end
end
