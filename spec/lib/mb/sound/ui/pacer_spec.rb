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
    expect(b[:late_ms][:p50]).to be_within(0.01).of(2.0) # (each frame starts 2 ms late, and the next deadline stays put)
  end

  it 'skips the deadlines a long frame missed instead of rushing' do
    p = fake(100)
    # Every 10th frame takes 35 ms (3.5 periods)
    frames = run_for(p, 10.0, ->(n) { n % 10 == 0 ? 0.035 : 0.002 })
    expect(p.skipped).to be > 0
    # 10 s at 100/s, minus 3 skipped deadlines per long frame
    expect(frames).to be_within(3).of(1000 * 10 / 13.0)
    expect(p.breakdown[:sleep_ms][:p50]).to be > 0
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
