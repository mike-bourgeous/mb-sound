RSpec.describe('MB::Sound.bounce_hits') do
  before { MB::Sound.bpm(120) }

  it 'times hits geometrically, converging on the length, with falling velocities' do
    c = MB::Sound.bounce_hits(2.bars, count: 6, elasticity: 0.5, note: 36)
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
    c = MB::Sound.bounce_hits(1.bar, count: 4, elasticity: 0.5, reverse: true)
    expect(c.map(&:start)).to eq([0r, 1/8r, 3/8r, 7/8r])
    expect(c.map(&:velocity)).to eq([0.125, 0.25, 0.5, 1.0])
  end

  it 'plays as a clip (triggers on the hit samples)' do
    trig = MB::Sound.bounce_hits(1.bar, count: 3, elasticity: 0.5).trigger
    out = trig.sample(96000)
    expect(out.ne(0).where.to_a).to eq([0, 48000, 72000])
  end

  it 'rejects bad elasticities and counts' do
    expect { MB::Sound.bounce_hits(1, elasticity: 1) }.to raise_error(ArgumentError, /elasticity/)
    expect { MB::Sound.bounce_hits(1, count: 0) }.to raise_error(ArgumentError, /hit/)
  end
end
