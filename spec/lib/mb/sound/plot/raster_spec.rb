RSpec.describe(MB::Sound::Plot::Geometry) do
  describe '.decimate' do
    let(:xs) { Numo::DFloat.linspace(0, 99, 100_000) }
    let(:ys) { Numo::NMath.sin(Numo::DFloat.new(100_000).seq * 0.37) * Numo::DFloat.linspace(0, 1, 100_000) }

    [true, false].each do |regular|
      [true, false].each do |ends|
        it "keeps every column's extremes (regular: #{regular}, ends: #{ends})" do
          dx, dy = described_class.decimate(xs, ys, 100, regular: regular, ends: ends)
          expect(dx.length).to be <= 404
          expect(dy.max).to be_within(1e-12).of(ys.max)
          expect(dy.min).to be_within(1e-12).of(ys.min)
          next if ends

          # Text rasters: every column gets points
          expect(dx.round.to_a.uniq.length).to be >= 99
        end
      end
    end

    it 'leaves short data alone' do
      expect(described_class.decimate(Numo::DFloat[0, 1], Numo::DFloat[1, 2], 10)).to eq([Numo::DFloat[0, 1], Numo::DFloat[1, 2]])
    end
  end

  describe '.line_points' do
    it 'connects points without gaps' do
      ix, iy = described_class.line_points(Numo::DFloat[0, 10, 10], Numo::DFloat[0, 3, -5])
      pts = ix.to_a.zip(iy.to_a).uniq
      expect(pts.select { |_, y| y >= 0 }.map(&:first).uniq.sort).to eq((0..10).to_a)
      expect(pts.select { |x, _| x == 10 }.map(&:last).sort).to eq((-5..3).to_a)
      expect(pts.length).to eq(11 + 8)
    end

    it 'breaks lines at NaN and keeps isolated points' do
      ix, _ = described_class.line_points(Numo::DFloat[0, 2, Float::NAN, 5, Float::NAN, 7, 8], Numo::DFloat[0, 0, 0, 0, 0, 0, 0])
      expect(ix.to_a.sort).to eq([0, 1, 2, 5, 7, 8])
    end

    it 'draws one segment' do
      ix, iy = described_class.line_points(Numo::DFloat[0, 3], Numo::DFloat[0, 0])
      expect(ix.to_a).to eq([0, 1, 2, 3])
      expect(iy.to_a.uniq).to eq([0])
    end
  end
end

RSpec.describe(MB::Sound::Plot::Raster) do
  it 'fills areas to a base row and between lines' do
    r = described_class.new(5, 6)
    c = r.color([1, 2, 3])
    mask = r.line_mask(Numo::DFloat[0, 4], Numo::DFloat[1, 1])
    r.fill_between(mask, c, base: 4.0)
    expect(r.dots[1..4, true].eq(c).all?).to eq(true)
    expect(r.dots[0, true].eq(0).all?).to eq(true)
    expect(r.dots[5, true].eq(0).all?).to eq(true)
  end
end
