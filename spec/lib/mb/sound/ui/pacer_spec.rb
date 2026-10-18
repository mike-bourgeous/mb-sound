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
