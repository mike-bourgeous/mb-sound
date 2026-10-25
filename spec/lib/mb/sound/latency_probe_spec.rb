RSpec.describe(MB::Sound::LatencyProbe, :aggregate_failures) do
  let(:hist) { MB::Sound::LatencyProbe::Histogram }
  let(:per) { MB::Sound::LatencyProbe::Periodicity }

  # Probes started by an example, stopped after it.
  let(:probes) { [] }

  def start_probe(**opts)
    p = MB::Sound::LatencyProbe.start(memory: 4 << 20, memory_touch: 16_384, cpu_iterations: 2000, **opts)
    probes << p
    p
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.005 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    yield
  end

  # Waits until the probe has filed a row for a second that started after
  # this call (rows are filed 3 seconds after their second).
  def wait_for_rows(probe, n = 1, timeout: 15)
    wait_until(timeout: timeout) { probe.rows.length >= n }
  end

  after do
    probes.each(&:stop)
  end

  describe MB::Sound::LatencyProbe::Histogram do
    it 'counts values and reads percentiles and counts over limits' do
      h = hist.new
      1000.times { |i| h << (i + 1) * 1000 } # 1..1000 us
      expect(h.total).to eq(1000)
      expect(h.percentile(0.5)).to be_within(0.05 * 500_000).of(500_000)
      expect(h.percentile(0.99)).to be_within(0.05 * 990_000).of(990_000)
      expect(h.max_ns).to eq(1_000_000)
      expect(h.count_at_least(500_000)).to be_within(25).of(500)
      expect(h.count_at_least(2_000_000)).to eq(0)

      other = hist.new
      other << 5_000_000
      h.merge!(other)
      expect(h.total).to eq(1001)
      expect(h.max_ns).to eq(5_000_000)
      expect(hist.new(h.counts).max_ns).to be_within(0.05 * 5e6).of(5e6)
      expect(h.to_pairs.sum(&:last)).to eq(1001)
    end
  end

  describe MB::Sound::LatencyProbe::Periodicity do
    # Wall times like the Mac Docker VM's: a stall near :59.9 of each
    # minute for +minutes+ minutes (one minute skipped), plus random noise.
    def minute_stalls(minutes, phase: 59.9, noise: 10, seed: 1)
      rng = Random.new(seed)
      t0 = 1_792_800_000 # a whole minute
      times = (0...minutes).filter_map { |m| t0 + m * 60 + phase + rng.rand(-0.4..0.4) unless m == 3 }
      times += Array.new(noise) { t0 + rng.rand(0.0..minutes * 60.0) }
      [times, t0, t0 + minutes * 60]
    end

    it 'finds stalls at the top of every wall-clock minute' do
      times, start, stop = minute_stalls(15)
      r = per.detect(times, start: start, stop: stop)
      expect(r).not_to be_nil
      expect(r.period).to eq(60)
      circular = ((r.phase - 59.9 + 30) % 60) - 30
      expect(circular.abs).to be < 0.5
      expect(r.coverage).to be >= 0.8
      expect(r.hits).to eq(14)
      expect(r.phase_label).to match(/\A:(59\.\d|00\.\d)\z/)
      expect(r.to_s).to match(/stalls cluster at :\d\d\.\d of each minute \(\d+% of stall episodes; in 14 of 1[45] minutes\)/)
    end

    it 'finds a 30 s period, and a phase that wraps across :00' do
      rng = Random.new(3)
      t0 = 1_792_800_000
      times = (0...40).map { |k| t0 + k * 30 + 29.8 + rng.rand(0.0..0.5) }
      r = per.detect(times, start: t0, stop: t0 + 1200)
      expect(r.period).to eq(30)
      expect(r.coverage).to be >= 0.9
    end

    it 'finds nothing in random times' do
      rng = Random.new(5)
      times = Array.new(40) { 1_792_800_000 + rng.rand(0.0..3600.0) }
      expect(per.detect(times, start: 1_792_800_000, stop: 1_792_803_600)).to be_nil
      expect(per.detect([1.0, 2.0])).to be_nil
    end

    it 'merges times closer than a second' do
      expect(per.merge_times([1.0, 1.5, 2.2, 5.0], 1.0)).to eq([1.0, 5.0])
    end

    it 'finds the lag of a repeating per-second series' do
      series = Array.new(600) { |i| i % 60 == 59 ? 1 : 0 }
      lag, r = per.best_lag(series, 200)
      expect(lag).to eq(60)
      expect(r).to be > 0.9
    end
  end

  it 'rejects unknown options and work probes' do
    expect { described_class.new(perido: 1) }.to raise_error(ArgumentError, /perido/)
    expect { described_class.new(work: [:disk]) }.to raise_error(ArgumentError, /disk/)
  end

  it 'starts, snapshots, and stops, with per-second rows from every series' do
    probe = start_probe
    expect(probe.running?).to eq(true)
    wait_for_rows(probe, 2)
    snap = probe.snapshot
    expect(snap[:running]).to eq(true)
    expect(snap[:ticks]).to be > 100
    expect(snap[:last]).to include(:stall_max_ms, :r_late_max_ms)
    expect(probe.status_line).to match(/probe max .* ms .* ruby max .* episodes \d+/)

    probe.stop
    expect(probe.running?).to eq(false)
    rows = probe.seconds
    full = rows.select { |r| r[:ticks].to_i > 0 && r[:r_ticks].to_i > 0 }
    expect(full).not_to be_empty
    expect(full.first[:late_p99_ms]).to be >= 0
    expect(rows.map { |r| r[:second] }).to eq(rows.map { |r| r[:second] }.sort.uniq)
    expect(rows.any? { |r| r[:gc_count] }).to eq(true)
    expect(rows.any? { |r| r[:load1] }).to eq(true)
    expect(rows.any? { |r| r[:mem_available_mb] }).to eq(true) if File.readable?('/proc/meminfo') || RUBY_PLATFORM.include?('darwin')
    expect(probe.histogram(:ruby).total).to be > 0
    expect(probe.histogram(:stall).total).to eq(probe.stats[:ticks])
  end

  it 'blames a GVL hold on the process, not the system' do
    probe = start_probe(threshold: 0.02)
    wait_until(timeout: 10) { probe.stats[:calibrated] }
    MB::Sound::FastLatency.spin(0.3)
    wait_until(timeout: 5) { probe.snapshot[:ruby_events] > 0 }
    probe.stop

    worst_ruby = probe.ruby_events.map { |e| e[:late_ns] }.max
    expect(worst_ruby).to be >= 250_000_000
    # The probe thread kept waking on time (generous for loaded machines)
    expect(probe.stats[:max_late_ns]).to be < 100_000_000

    causes = MB::Sound::LatencyProbe::Report.new(probe).ruby_causes
    big = probe.ruby_events.select { |e| e[:late_ns] >= 250_000_000 }
    expect(big.length).to eq(1)
    expect(causes[:process][0] + causes[:gc][0]).to be >= 1
    expect(probe.report).to match(/Ruby ticker stalls over 20 ms: [1-9]/)
  end

  it 'blames a Ruby stall on the system only when probe episodes then stalled a quarter as long' do
    ms = 1_000_000
    ruby = [{ wall_ns: 1000 * ms, late_ns: 300 * ms }]
    report = ->(episodes) {
      probe = double(seconds: [], episodes: episodes, ruby_events: ruby, session_events: [], stats: {}, options: {})
      MB::Sound::LatencyProbe::Report.new(probe).ruby_causes.transform_values(&:first)
    }
    # (a loaded machine's short episodes during a GVL hold, omnibus13)
    expect(report.([{ wall_ns: 800 * ms, duration_ns: 30 * ms, stall_ns: 25 * ms }, { wall_ns: 900 * ms, duration_ns: 40 * ms, stall_ns: 30 * ms }])).to eq(process: 1)
    expect(report.([{ wall_ns: 750 * ms, duration_ns: 250 * ms, stall_ns: 280 * ms }])).to eq(system: 1)
    expect(report.([{ wall_ns: 2000 * ms, duration_ns: 250 * ms, stall_ns: 280 * ms }])).to eq(process: 1)
  end

  it 'logs a watched Session and writes data files, a report, and plots' do
    dir = tmp_path('latency')
    output = MB::Sound::NullOutput.new(channels: 1, sleep: false)
    session = MB::Sound::Session.new(realtime: false, output: output, channels: 1, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
    probe = start_probe(dir: dir, flush_every: 1)
    probe.watch(session)
    expect(probe.session_watch).not_to be_nil
    session.add(220.hz.at(0.1))
    deadline = Time.now + 1.2
    session.process_buffer(800) while Time.now < deadline && (sleep(0.005) || true)
    probe.stop # (files every pending second)
    session.close

    expect(probe.seconds.sum { |r| r[:s_buffers].to_i }).to be > 0
    expect(File.read(File.join(dir, 'seconds.csv')).lines.first.chomp.split(',')).to eq(described_class::COLUMNS.map(&:to_s))
    expect(File.read(File.join(dir, 'events.csv')).lines.first.chomp).to eq(described_class::EVENT_COLUMNS.join(','))

    paths = probe.save
    expect(File.read(paths[:report])).to match(/Percentiles \(ms\).*Session: \d+ buffers/m)
    %w[time histogram].each do |name|
      %w[svg png txt].each do |ext|
        path = File.join(dir, "#{name}.#{ext}")
        expect(File.size(path)).to be > 100, path
      end
    end
    expect(File.read(File.join(dir, 'time.svg'))).to start_with('<svg')
    expect(File.binread(File.join(dir, 'time.png'))[0, 8]).to eq("\x89PNG\r\n\x1A\n".b)
    meta = JSON.parse(File.read(File.join(dir, 'meta.json')))
    expect(meta['probe']['priority']).to be_a(String)
    expect(JSON.parse(File.read(File.join(dir, 'histograms.json'))).keys).to include('stall', 'ruby', 'session')

    # Read back (LatencyProbe.load): the same rows and tables
    saved = described_class.load(dir)
    expect(saved.seconds.map { |r| r[:second] }).to eq(probe.seconds.map { |r| r[:second] })
    expect(saved.histogram(:stall).total).to eq(probe.histogram(:stall).total)
    expect(saved.report.lines.grep(/^(stall \(probe\)|ruby ticker) /)).to eq(probe.report.lines.grep(/^(stall \(probe\)|ruby ticker) /))
  end

  it 'starts from MB_SOUND_LATENCY_PROBE and finishes with a report' do
    expect(described_class.from_env(nil, env: {})).to be_nil
    expect(described_class.from_env(nil, env: { 'MB_SOUND_LATENCY_PROBE' => '0' })).to be_nil

    dir = tmp_path('env_probe')
    probe = nil
    expect {
      probe = described_class.from_env(nil, env: { 'MB_SOUND_LATENCY_PROBE' => dir })
    }.to output(/Latency probe running .*#{Regexp.escape(dir)}/).to_stderr
    probes << probe
    expect(probe.running?).to eq(true)
    paths = nil
    expect { paths = probe.finish }.to output(/Latency report: /).to_stderr
    expect(File.exist?(paths[:report])).to eq(true)
  end
end
