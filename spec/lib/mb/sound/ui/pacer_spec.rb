# The painters' deadline pacing (UI::Pacer, ux-1 r3 item 23), with a fake
# clock: the target rate holds whenever a frame's work fits in its period,
# long frames skip the deadlines they missed (no catching up, no period +
# work drift), and every (state, event) pair is defined or refused.
RSpec.describe(MB::Sound::UI::Pacer, :aggregate_failures) do
  # A fake clock: sleeping and working advance it.
  def fake(fps, oversleep: 0.0)
    @t = 0.0
    described_class.new(fps, clock: -> { @t }, sleeper: ->(s) { @t += s + oversleep })
  end

  def run_for(pacer, seconds, work)
    frames = 0
    pacer.run(-> { @t >= seconds }) do |_now|
      frames += 1
      @t += work.respond_to?(:call) ? work.call(frames) : work
      'x'
    end
    frames
  end

  it 'hits the target when the work fits, whatever the work takes' do
    [0.0, 0.004, 0.012, 0.0166].each do |work|
      p = fake(60)
      frames = run_for(p, 10.0, work)
      expect(frames).to be_within(1).of(600), "work #{work}"
      expect(p.skipped).to eq(0)
    end
  end

  it 'keeps deadlines through oversleep (the next frame starts on the grid, not a period after the last)' do
    p = fake(60, oversleep: 0.002)
    frames = run_for(p, 10.0, 0.005)
    expect(frames).to be_within(1).of(600)
    b = p.breakdown(window: 2.0)
    expect(b[:oversleep_ms][:p50]).to be_within(0.01).of(2.0)
    expect(b[:late_ms][:p50]).to be < 0.1 # (the wake offset learned the 2 ms: frames start on their deadlines; ui-api-1)
  end

  # ui-perf-1: a key wakes the painter early (Thread#wakeup ends its sleep);
  # the deadline it slept toward is still served, a period after the last
  # one, instead of the woken frame taking it and pushing the next frame a
  # whole period past it (typing showed on screen 22-31 ms after the key:
  # the woken frame ran before the REPL's echo, 0.6 ms later, and the next
  # one came up to two periods on)
  it 'keeps the deadline a woken frame started before (a key wakes the painter)' do
    @t = 0.0
    wake_at = [0.1055, 0.2027]
    p = described_class.new(50, clock: -> { @t }, sleeper: lambda { |s|
      w = wake_at.find { |x| x > @t && x < @t + s }
      @t = w || @t + s
    })
    starts = []
    p.run(-> { @t >= 0.4 }) do |now|
      starts << now
      @t += 0.001
      'x'
    end
    # Frames at 0, 20, ... 100 ms, the woken one at 105.5, then 120 (not 140)
    i = starts.index { |s| (s - 0.1055).abs < 1e-9 }
    expect(starts[i + 1]).to be_within(1e-6).of(0.12)
    j = starts.index { |s| (s - 0.2027).abs < 1e-9 }
    expect(starts[j + 1]).to be_within(1e-6).of(0.22)
    expect(starts.length).to eq(22) # (20 on the grid and the 2 woken ones)
    expect(p.offset).to eq(0.0) # (early wakes don't teach the wake offset)
  end

  # ui-perf-1 (an option): frames timed to the render thread's snapshots
  # (FrameRate::SnapshotTiming).  800-frame buffers at 48 kHz come 60 times
  # a second, as do the painter's frames; on the grid alone the two beat,
  # and with jitter a frame now and then shows the snapshot before (the
  # scope's visible updates 33 ms apart).
  describe 'frames timed to snapshots' do
    snap = Struct.new(:seq, :time, :buffer_size, :sample_rate, :latency)

    # A feed publishing a snapshot every 800 frames from +phase+ seconds,
    # each up to +jitter+ seconds late (a render thread's wake), until
    # +stop_at+; its #latest is what has been published by @t, #times all
    # the publish times.
    define_method(:feed) do |phase:, jitter:, stop_at: Float::INFINITY, latency: 0.0|
      buf = 800 / 48000.0
      rnd = Random.new(3)
      times = (0...200).map { |k| phase + k * buf + rnd.rand * jitter }.select { |t| t < stop_at }
      f = Object.new
      t = -> { @t }
      f.define_singleton_method(:times) { times }
      f.define_singleton_method(:latest) {
        n = times.count { |x| x <= t.call }
        n == 0 ? nil : snap.new(n, times[n - 1], 800, 48000, latency)
      }
      f
    end

    # [snapshot seq shown, frame start] per frame after the first 10:
    # shown is the newest heard at the frame's start (Follow#heard).
    def shown(timed, fd, seconds: 1.5)
      @t = 0.0
      p = described_class.new(60, clock: -> { @t }, sleeper: ->(s) { @t += s })
      p.timing = MB::Sound::UI::FrameRate::SnapshotTiming.new(-> { fd }, p) if timed
      seqs = []
      starts = []
      p.run(-> { @t >= seconds }) do |now|
        lat = fd.latest&.latency.to_f
        seqs << fd.times.count { |x| x + lat <= now }
        starts << now
        @t += 0.0015 # (the frame's work)
        'x'
      end
      [seqs.drop(10), starts.drop(10)]
    end

    it 'shows each snapshot once, a buffer apart, where the grid repeats and skips them' do
      seqs, starts = shown(true, feed(phase: 0.0161, jitter: 0.001))
      expect(seqs.each_cons(2).map { |a, b| b - a }.uniq).to eq([1])
      expect(starts.each_cons(2).map { |a, b| b - a }.max).to be < 1 / 60.0 + 0.0012
      grid, = shown(false, feed(phase: 0.0161, jitter: 0.001))
      expect(grid.each_cons(2).map { |a, b| b - a }.uniq.sort).to include(0, 2)
    end

    it 'shows each heard snapshot once under output latency (kept snapshot times)' do
      seqs, = shown(true, feed(phase: 0.005, jitter: 0.002, latency: 3 * 800 / 48000.0))
      expect(seqs.each_cons(2).map { |a, b| b - a }.uniq).to eq([1])
    end

    it 'shows the snapshot heard nearest the frame with timing on (Follow#heard), the last one passed without' do
      screen = Class.new {
        include MB::Sound::UI::Follow
        def initialize(pacer) = (@pacer = pacer; @heard = nil)
        public :heard
      }.new(described_class.new(60, clock: -> { 0.0 }))
      now = MB::U.clock_now
      a = MB::Sound::UI::Snapshot.fake(seq: 1, time: now - 0.030, latency: 0.020) # (heard 10 ms ago)
      b = MB::Sound::UI::Snapshot.fake(seq: 2, time: now - 0.016, latency: 0.020) # (heard in 4 ms: under half a period)
      old = MB::Sound::UI::FrameRate.snapshot_timed
      begin
        MB::Sound::UI::FrameRate.snapshot_timed = false
        screen.heard(a, now)
        expect(screen.heard(b, now).seq).to eq(1)
        MB::Sound::UI::FrameRate.snapshot_timed = true
        expect(screen.heard(b, now).seq).to eq(2)
      ensure
        MB::Sound::UI::FrameRate.snapshot_timed = old
      end
    end

    it 'keeps the grid when snapshots stop (a stopped render thread still gets frames)' do
      _, starts = shown(true, feed(phase: 0.003, jitter: 0.0, stop_at: 0.5))
      late = starts.select { |s| s > 0.7 }
      expect(late.each_cons(2).map { |a, b| (b - a).round(4) }.uniq).to eq([(1 / 60.0).round(4)])
    end
  end

  it 'skips only the whole periods a long frame overran, starting at once after a partial one' do
    p = fake(100)
    # Every 10th frame takes 35 ms (3.5 periods): it skips 2 deadlines and
    # the next frame starts at once (half a period late; ui-api-1: it used
    # to skip 3)
    frames = run_for(p, 10.0, ->(n) { n % 10 == 0 ? 0.035 : 0.002 })
    expect(p.skipped).to be > 0
    # (the rate trim makes up some of the skipped frames: at most MAX_TRIM)
    expect(frames).to be_between(1000 * 10 / 12.0 - 3, 1000 * 10 / 12.0 * (1 + described_class::MAX_TRIM) + 3)
    expect(p.breakdown[:sleep_ms][:p50]).to be > 0
  end

  # ui-api-1 (maintainer, 2026-10-18: "UI is still falling a bit short of
  # target fps when it's capable of more"; then "adaptive pacing so that
  # deadlines are adjusted until the target fps is hit")
  describe 'adaptive pacing' do
    # A fake clock whose sleeps overshoot by +overhead+ (a Proc of the
    # frame number, or seconds) and round up to +grain+ seconds (timer
    # granularity).
    def adaptive(fps, overhead:, grain: 0.0)
      @t = 0.0
      n = 0
      described_class.new(fps, clock: -> { @t }, sleeper: ->(s) {
        n += 1
        s = (s / grain).ceil * grain if grain > 0
        @t += s + (overhead.respond_to?(:call) ? overhead.call(n) : overhead)
      })
    end

    {
      'a fixed 1.5 ms wake latency' => { overhead: 0.0015 },
      'a jittery 0-3 ms wake latency' => { overhead: ->(n) { ((n * 7919) % 1000) / 1000.0 * 0.003 } },
      '1 ms timer grain plus 0.8 ms latency' => { overhead: 0.0008, grain: 0.001 },
    }.each do |what, opts|
      [60, 144, 240].each do |fps|
        it "converges on #{fps}/s within 1% with #{what} (paint 0.7 ms)" do
          p = adaptive(fps, **opts)
          run_for(p, 8.0, 0.0007)
          b = p.breakdown(window: 2.0)
          expect(b[:refreshes]).to be_within(fps * 0.01).of(fps), "#{b.inspect} trim #{p.trim} offset #{p.offset}"
          expect(p.trim).to be <= described_class::MAX_TRIM * p.period
          expect(p.offset).to be <= described_class::MAX_OFFSET * p.period
        end
      end
    end

    it 'starts frames near their deadlines: the wake offset absorbs a steady latency' do
      p = adaptive(60, overhead: 0.002)
      run_for(p, 4.0, 0.0007)
      expect(p.offset).to be_within(0.0003).of(0.002)
      expect(p.breakdown(window: 1.0)[:late_ms][:p50]).to be < 0.3
    end

    it 'never paints faster than the work allows, and resets when the target changes' do
      p = adaptive(240, overhead: 0.0)
      frames = run_for(p, 4.0, 0.006) # (6 ms of work: at most ~166/s)
      expect(frames / 4.0).to be <= 1 / 0.006 + 1
      p.fps = 60
      expect([p.trim, p.offset]).to eq([0.0, 0.0])
      expect(p.period).to eq(1 / 60.0)
    end

    it 'keeps 2 s of frames at 240/s (the readout said 120/240 Hz)' do
      p = adaptive(240, overhead: 0.0)
      run_for(p, 4.0, 0.0007)
      expect(p.breakdown(window: 2.0)[:refreshes]).to be_within(2.4).of(240)
      expect(p.readout).to start_with('240/240 Hz')
    end
  end

  it 'splits a frame into paint and write' do
    p = fake(50)
    p.run(-> { @t >= 1.0 }) do
      @t += 0.003
      p.note_write(0.001)
      'bytes'
    end
    b = p.breakdown(window: 1.0)
    expect(b[:paint_ms][:p50]).to be_within(1e-9).of(2.0)
    expect(b[:write_ms][:p50]).to be_within(1e-9).of(1.0)
    expect(b[:refreshes]).to be_within(1).of(50)
    expect(p.readout(window: 1.0)).to match(%r{\A(49|50)/50 Hz · (49|50) written · paint 2\.0 write 1\.0 wait 17\.0\+0\.0 ms\z})
    expect(p.hitches(b)).to eq(false)
  end

  it 'names p99 lateness and the longest stall in the readout only when frames hitch (ui-perf-1)' do
    p = fake(50)
    n = 0
    p.run(-> { @t >= 1.0 }) do
      n += 1
      @t += n == 20 ? 0.1 : 0.003 # (one 100 ms frame: a stall over two periods)
      'bytes'
    end
    b = p.breakdown(window: 1.0)
    expect(p.hitches(b)).to eq(true)
    expect(p.readout(window: 1.0)).to match(%r{ · late p99 [0-9.]+ / stall 1\d\d ms})
  end

  it 'defines every (state, event) pair: the table\'s transitions, StateError for the rest' do
    described_class::STATES.each do |s|
      described_class::EVENTS.each do |e|
        p = fake(60)
        p.instance_variable_set(:@state, s)
        to = described_class::TRANSITIONS[[s, e]]
        if to
          p.event!(e)
          expect(p.state).to eq(to)
        else
          expect { p.event!(e) }.to raise_error(described_class::StateError, /#{e}.*#{s}/)
        end
      end
    end
    expect(described_class.table.length).to eq(described_class::TRANSITIONS.length)
  end

  it 'stops cleanly from a failing frame and starts again' do
    p = fake(60)
    expect { p.run(-> { false }) { raise 'boom' } }.to raise_error('boom')
    expect(p.state).to eq(:stopped)
    expect(run_for(p, @t + 1.0, 0.001)).to be_within(1).of(60)
  end
end
