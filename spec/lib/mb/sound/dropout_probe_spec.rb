RSpec.describe(MB::Sound::DropoutProbe) do
  describe MB::Sound::DropoutProbe::Analysis do
    ms = 1_000_000
    period = 512 / 48.0 # ms per write

    # A steady writer from 0 to +stall_at+ ms (render 1 ms, then waiting
    # for room), a stall of +stall+ ms before the next write, then steady
    # again.  +cpu+ is the render thread's CPU during the stall.
    let(:build) {
      ->(stall_at: 200.0, stall: 100.0, cpu: 1.0, limit: 2400, wait_through: false) {
        writes = []
        cpu_total = 0.0
        t = 0.0
        while t < stall_at + stall + 50
          stalled = t >= stall_at && writes.none? { |w| w[:stalled] }
          render = stalled ? stall : 1.0
          cpu_total += stalled ? cpu : 1.0
          enter = (t + render) * ms
          wait = stalled ? 0.0 : period - 1.0
          wait = wait_through if wait_through && stalled
          room = enter + wait * ms
          writes << {
            enter: enter.round, exit: (room + 0.02 * ms).round, wait: (wait * ms + 0.01 * ms).round, room: wait > 0 ? room.round : 0,
            back: wait > 0 ? (room + 0.01 * ms).round : 0, pull: wait > 0 ? (room - 0.05 * ms).round : 0,
            cpu_enter: (cpu_total * ms).round, cpu_exit: ((cpu_total + 0.02) * ms).round,
            queued: limit - 512, limit: limit, frames: 512, stalled: stalled,
          }
          t = (room + 0.02 * ms) / ms
        end
        writes
      }
    }

    let(:stall_start) { ->(writes) { writes.find { |w| w[:stalled] }.then { |w| writes[writes.index(w) - 1][:exit] } } }

    def ctx(writes, t, **extra)
      gap = { start: t, end: t + 20 * 1_000_000, since: 2_666_666, frames: 128, available: 0, short: 960, pulls: 8, limit: 2400, write_pos: 0, underrun: 1, late: 2_666_666, late_at: t - 2_666_666 }
      {
        gap: gap, writes: writes.map { |w| w.except(:stalled) }, threads: [], gc: [], samples: [], episodes: [],
        rate: 48000.0, buffer: 512, first_write: t - 10_000 * 1_000_000, limit_before: 2400, ended: false,
      }.merge(extra)
    end

    it 'blames the render thread when it was busy rendering through the window' do
      w = build.(cpu: 100.0)
      s = stall_start.(w)
      r = described_class.classify(ctx(w, s + 45 * ms))
      expect(r[:cause]).to eq(:render)
      expect(r[:components][:cpu_ms]).to be > 40
      expect(r[:detail]).to include('render thread cpu')
    end

    it 'blames the GVL when the render thread waited for it, naming the holder' do
      w = build.(cpu: 1.0)
      s = stall_start.(w)
      threads = [{ thread: 'render', holder: 'ui', a: s + 0.5 * ms, b: s + 1 * ms, c: s + 99 * ms }]
      r = described_class.classify(ctx(w, s + 45 * ms, threads: threads))
      expect(r[:cause]).to eq(:gvl)
      expect(r[:detail]).to include('held by ui')
      expect(r[:components][:gvl_by]).to include('ui' => be > 40)
    end

    it 'blames GC on another thread over the GVL wait it caused, and GC on the render thread over its CPU' do
      w = build.(cpu: 1.0)
      s = stall_start.(w)
      threads = [{ thread: 'render', holder: nil, a: s + 0.5 * ms, b: s + 1 * ms, c: s + 99 * ms }]
      gc = [{ thread: nil, a: s + 1 * ms, b: s + 98 * ms, major: true }]
      r = described_class.classify(ctx(w, s + 45 * ms, threads: threads, gc: gc))
      expect(r[:cause]).to eq(:gc)
      expect(r[:detail]).to start_with('major:').and include('another thread')

      w = build.(cpu: 100.0)
      s = stall_start.(w)
      gc = [{ thread: 'render', a: s + 2 * ms, b: s + 95 * ms, major: false }]
      r = described_class.classify(ctx(w, s + 45 * ms, gc: gc))
      expect(r[:cause]).to eq(:gc)
      expect(r[:detail]).to start_with('minor:').and include('on the render thread')
    end

    it 'blames a lock when the render thread was blocked off the GVL outside #write' do
      w = build.(cpu: 1.0)
      s = stall_start.(w)
      threads = [{ thread: 'render', holder: nil, a: s + 0.5 * ms, b: s + 99 * ms, c: s + 99.1 * ms }]
      r = described_class.classify(ctx(w, s + 45 * ms, threads: threads))
      expect(r[:cause]).to eq(:lock)
    end

    it 'blames the system when the render thread was not running, or the probe saw the machine stall' do
      w = build.(cpu: 1.0)
      s = stall_start.(w)
      r = described_class.classify(ctx(w, s + 45 * ms))
      expect(r[:cause]).to eq(:system)
      expect(r[:detail]).to include('the probe saw nothing')

      # The VM's minute stall: the CPU itself ran slow, so the render
      # thread looks busy, but the probe outside the GVL stalled too
      w = build.(cpu: 100.0)
      s = stall_start.(w)
      r = described_class.classify(ctx(w, s + 45 * ms, episodes: [{ start: s, duration: 90 * ms, stall: 60 * ms }]))
      expect(r[:cause]).to eq(:system)
      expect(r[:detail]).to include('probe episode stalled 60.0 ms')
    end

    it 'blames the system when the device thread itself stalled and caught up, even with the writer waiting' do
      w = build.(cpu: 1.0, stall: 1.0, wait_through: 100.0)
      s = stall_start.(w)
      c = ctx(w, s + 45 * ms)
      c[:gap][:late] = 150 * ms
      r = described_class.classify(c)
      expect(r[:cause]).to eq(:system)
      expect(r[:detail]).to include('device thread itself was stalled 150.0 ms')
    end

    it 'blames the device when the writer was waiting for room' do
      w = build.(cpu: 1.0, stall: 1.0, wait_through: 100.0)
      s = stall_start.(w)
      r = described_class.classify(ctx(w, s + 45 * ms))
      expect(r[:cause]).to eq(:device)
    end

    it 'blames a queue shrink when the queue before it would have covered the lateness' do
      w = build.(cpu: 60.0, stall: 60.0)
      s = stall_start.(w)
      r = described_class.classify(ctx(w, s + 45 * ms, limit_before: 4080))
      expect(r[:cause]).to eq(:queue_shrink)
      expect(r[:after_shrink]).to eq(true)
      expect(r[:detail]).to include('85 -> 50 ms')

      r = described_class.classify(ctx(w, s + 45 * ms))
      expect(r[:cause]).to eq(:render)
      expect(r[:after_shrink]).to eq(false)
    end

    it 'counts YJIT compile time from cumulative samples' do
      w = build.(cpu: 100.0)
      s = stall_start.(w)
      samples = [{ mono: s - 100 * ms, yjit_ns: 0 }, { mono: s + 100 * ms, yjit_ns: 180 * ms }]
      r = described_class.classify(ctx(w, s + 45 * ms, samples: samples))
      expect(r[:cause]).to eq(:yjit)
    end

    it 'calls early dropouts startup and gaps after the last write idle' do
      w = build.(cpu: 100.0)
      s = stall_start.(w)
      expect(described_class.classify(ctx(w, s + 45 * ms, first_write: s - 1_000 * ms))[:cause]).to eq(:startup)
      expect(described_class.classify(ctx(w.select { |x| x[:enter] < s }, s + 45 * ms, ended: true))[:cause]).to eq(:idle)
    end

    it 'calls a window with no part standing out unexplained' do
      w = build.(cpu: 33.0)
      s = stall_start.(w)
      threads = [{ thread: 'render', holder: 'main', a: s + 15 * ms, b: s + 30 * ms, c: s + 45 * ms }]
      r = described_class.classify(ctx(w, s + 45 * ms, threads: threads, episodes: []))
      expect(r[:cause]).to eq(:unexplained)
    end
  end

  # A realtime Session on miniaudio's null device (the trace needs a
  # DeviceOutput), with a stall injected on the render thread
  it 'traces a live Session, finds an injected render stall, and writes its log' do
    output = MB::Sound::DeviceOutput.new(channels: 1, backends: [:null], latency: 0.03, buffer_size: 512, adaptive: false)
    session = MB::Sound::Session.new(output: output)
    json = tmp_path('dropouts.json')
    begin
      session.add(0.1.constant, name: :quiet)
      Thread.pass until session.running?
      stall = false
      tap = session.add_tap { |_| (stall = false; MB::Sound::FastLatency.spin(0.12)) if stall }
      probe = described_class.start(session, json: json, system: false, quiet: true, settle: 0.3, startup: 0)
      sleep 0.4
      stall = true
      t = MB::U.clock_now
      Thread.pass while probe.dropouts.empty? && MB::U.clock_now - t < 5
      session.remove_tap(tap)
      probe.stop
    ensure
      session.close
      MB::Sound.rewind
    end

    expect(probe.dropouts.map { |d| d[:result][:cause] }).to include(:render)
    expect(probe.totals[:writes]).to be > 20
    data = JSON.parse(File.read(json))
    expect(data['summary']['causes']).to include('render')
    d = data['dropouts'].find { |x| x['cause'] == 'render' }
    expect(d['context']['writes']).not_to be_empty
    expect(d['short_ms']).to be > 0
    expect(File.read(json.sub(/\.json\z/, '.csv')).lines.length).to be >= 2
    expect(File.read(json.sub(/\.json\z/, '.txt'))).to include('Likely causes:', 'render overrun')
  end
end
