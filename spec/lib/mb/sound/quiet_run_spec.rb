# The one quiet-run engine (node-traits-1, arch-core finding 4): sleepers,
# buses, tails, ring-outs, and the render loops share MB::Sound::QuietRun.
# The callers' own specs (buffer size invariance, session fuzz, tails, buses,
# drums, sub-lanes) guard that each kept its samples; these pin the modes.
RSpec.describe(MB::Sound::QuietRun) do
  let(:q) { described_class }

  it 'keeps the levels in one place' do
    expect(q::QUIET).to eq(10.0**(-90 / 20.0))
    expect(q::SILENCE).to eq(1e-6)
    expect(q::GRID).to eq(MB::Sound::Synth::SKIP_GRID)
    # (float samples above a level are those at least its loud bound)
    expect(Numo::SFloat[q::SILENCE_LOUD][0]).to be > q::SILENCE
    expect(Numo::SFloat[q::SILENCE][0]).to be <= q::SILENCE
    expect(Numo::SFloat[q::QUIET_LOUD][0]).to be >= q::QUIET
  end

  describe ':sample mode' do
    it 'completes a window after the last loud sample, at any buffer split' do
      x = Numo::SFloat.zeros(100)
      x[10] = 0.5
      x[37] = -0.2
      [100, 7, 1].each do |n|
        r = q.new(20)
        (0...100).step(n) { |f| r.track(x, f, f, [n, 100 - f].min) }
        expect(r.quiet_from).to eq(38)
        expect(r.ends_at).to eq(58)
        expect(r.complete_at?(57)).to eq(false)
        expect(r.complete_at?(58)).to eq(true)
      end
    end

    it 'completes only at grid points with a grid' do
      r = q.new(1000, grid: 800, from: 100)
      expect(r.ends_at).to eq(1600)
      expect(r.complete_at?(1100)).to eq(false)
      expect(r.complete_at?(1600)).to eq(true)
      expect(r.next_point(0)).to eq(1600)
      expect(r.next_point(1600)).to eq(2400)
    end
  end

  describe ':cells mode' do
    it 'counts whole silent cells, splitting where a sleeper could fall asleep' do
      r = q.new(1600, loud: q::SILENCE_LOUD, mode: :cells, grid: 800)
      x = Numo::SFloat.zeros(800)
      x[5] = 0.1
      r.track(x, 800) # (a loud sample in the second cell)
      expect(r.quiet_from).to eq(1600)
      expect(r.split_point(1000, 0, 5000)).to eq(2200) # (offset of frame 3200: two silent cells after it)
      expect(r.sleep_due?(2400)).to eq(false)
      expect(r.sleep_due?(3200)).to eq(true)
      r.reset(3250) # (a wake mid-cell counts that cell)
      expect(r.ends_at).to eq(4800)
    end

    it 'ignores samples within the silence level' do
      r = q.new(800, loud: q::SILENCE_LOUD, mode: :cells, grid: 800)
      r.track(Numo::SFloat.new(800).fill(q::SILENCE), 0)
      expect(r.sleep_due?(800)).to eq(true)
    end
  end

  describe ':buffer mode' do
    it 'counts quiet buffers on its own clock' do
      r = q.new(1000, mode: :buffer)
      expect(r.advance_buffer(600, true)).to eq(false)
      expect(r.advance_buffer(600, false)).to eq(false)
      expect(r.advance_buffer(400, false)).to eq(true)
      expect(r).to be_done
      r.reset(r.at)
      expect(r).not_to be_done
    end
  end
end
