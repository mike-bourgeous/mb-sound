RSpec.describe('MB::Sound.bounce_hits') do
  before { MB::Sound.bpm(120) }

  it 'times hits geometrically, converging on the length, with falling velocities' do
    c = MB::Sound.bounce_hits(2.bars, count: 6, elasticity: 0.5, note: 36, decay: :speed)
    expect(c.map(&:start)).to eq([0r, 1r, 3/2r, 7/4r, 15/8r, 31/16r])
    expect(c.map(&:velocity)).to eq([1, 0.5, 0.25, 0.125, 0.0625, 0.03125])
    expect(c.map(&:value).uniq).to eq([36])
    expect(c.length).to eq(2r)
    expect(c.looping?).to eq(false)
  end

  it 'counts plain numbers as bars and drops hits closer than min_gap' do
    c = MB::Sound.bounce_hits(1, count: 100, elasticity: 0.9, min_gap: 1/256r)
    expect(c.length).to eq(1r)
    expect(c.map(&:start).each_cons(2).map { |a, b| b - a }.min).to be >= 1/256r
    expect(c.count).to be < 100
  end

  it 'accelerates apart with reverse: true, soft to loud' do
    c = MB::Sound.bounce_hits(1.bar, count: 4, elasticity: 0.5, reverse: true, decay: :speed)
    expect(c.map(&:start)).to eq([0r, 1/8r, 3/8r, 7/8r])
    expect(c.map(&:velocity)).to eq([0.125, 0.25, 0.5, 1.0])
  end

  it 'plays as a clip (triggers on the hit samples)' do
    trig = MB::Sound.bounce_hits(1.bar, count: 3, elasticity: 0.5).trigger
    out = trig.sample(96000)
    expect(out.ne(0).where.to_a).to eq([0, 48000, 72000])
  end

  describe 'decay:' do
    def vels(decay, **opts)
      MB::Sound.bounce_hits(1, count: 5, elasticity: 0.5, decay: decay, **opts).map { |e| e.velocity.round(6) }
    end

    it 'falls by the impact speed, e^i, with :speed' do
      expect(vels(:speed)).to eq([1, 0.5, 0.25, 0.125, 0.0625])
    end

    it 'defaults to :gentle, the square root of the speed, and falls not at all with :none' do
      expect(vels(:gentle)).to eq([1, 0.707107, 0.5, 0.353553, 0.25])
      expect(MB::Sound.bounce_hits(1, count: 5, elasticity: 0.5).map { |e| e.velocity.round(6) }).to eq(vels(:gentle))
      expect(vels(:none, velocity: 0.8)).to eq([0.8] * 5)
    end

    it 'falls by a fixed factor per hit given a number, keeping the timing' do
      expect(vels(0.9)).to eq([1, 0.9, 0.81, 0.729, 0.6561])
      expect(MB::Sound.bounce_hits(1, count: 5, elasticity: 0.5, decay: 0.9).map(&:start)).to eq(MB::Sound.bounce_hits(1, count: 5, elasticity: 0.5).map(&:start))
    end

    it 'follows a Curve or Curve name over the hits, reaching 0 on the last' do
      expect(vels(MB::Sound::Curve[:linear])).to eq([1, 0.75, 0.5, 0.25, 0])
      expect(vels(:quad_out)).to eq([1, 0.5625, 0.25, 0.0625, 0])
    end

    it 'calls a Proc with the hit index and its position fraction' do
      expect(vels(->(i) { 1.0 / (i + 1) })).to eq([1, 0.5, 0.333333, 0.25, 0.2])
      expect(vels(->(_i, f) { 1 - f })).to eq([1, 0.5, 0.25, 0.125, 0.0625])
    end

    it 'applies before reverse, so a reversed ball still goes soft to loud' do
      expect(vels(:gentle, reverse: true)).to eq(vels(:gentle).reverse)
    end

    it 'rejects unknown decays and factors outside 0..1' do
      expect { vels(:nope) }.to raise_error(ArgumentError, /Unknown bounce decay :nope/)
      expect { vels(1.5) }.to raise_error(ArgumentError, /between 0 and 1/)
      expect { vels('x') }.to raise_error(ArgumentError, /Unknown bounce decay/)
    end
  end

  describe 'pitch:' do
    it 'moves each hit by semitones per bounce' do
      c = MB::Sound.bounce_hits(1, count: 4, note: MB::Sound::E3, pitch: -1)
      expect(c.map { |e| e.value.number }).to eq([MB::Sound::E3, MB::Sound::Ds3, MB::Sound::D3, MB::Sound::Cs3].map(&:number))
      expect(MB::Sound.bounce_hits(1, count: 3, note: 60, pitch: 2.st).map(&:value)).to eq([60, 62, 64])
    end

    it 'rises with reverse, and takes a Proc' do
      expect(MB::Sound.bounce_hits(1, count: 4, note: 52, pitch: -1, reverse: true).map(&:value)).to eq([49, 50, 51, 52])
      expect(MB::Sound.bounce_hits(1, count: 3, note: 60, pitch: ->(i) { i * i * -1 }).map(&:value)).to eq([60, 59, 56])
    end
  end

  it 'rejects bad elasticities and counts' do
    expect { MB::Sound.bounce_hits(1, elasticity: 1) }.to raise_error(ArgumentError, /elasticity/)
    expect { MB::Sound.bounce_hits(1, count: 0) }.to raise_error(ArgumentError, /hit/)
  end
end
