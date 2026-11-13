RSpec.describe(MB::Sound::PerHarmonic, :aggregate_failures) do
  def ph(*a, **k) = MB::Sound.per_harmonic(*a, **k)

  it 'spreads a Range across the bands along a curve, in the values\' own units' do
    expect(ph(1..3).to_a(3)).to eq([1, 2, 3])
    expect(ph(1.0..3.0).to_a(1)).to eq([1.0])
    expect(ph(15.cents..90.cents).to_a(4).map(&:to_cents)).to eq([15.0, 40.0, 65.0, 90.0])
    expect(ph(100.hz..400.hz).to_a(4).map(&:frequency)).to eq([100.0, 200.0, 300.0, 400.0])
    expect(ph(100.hz..400.hz).value(1, 4)).to be_a(MB::Sound::Pitch)
    expect(ph(-12.db..0.db).to_a(3).map(&:db_value)).to eq([-12.0, -6.0, 0.0])

    exp = ph(0.0..1.0, curve: :exp).to_a(5)
    expect(exp).to eq(Array.new(5) { |i| MB::Sound::Curve[:exp].call(i / 4.0) })
    sq = ph(0.0..1.0, curve: MB::Sound::Curve.power(2)).to_a(3)
    expect(sq).to eq([0.0, 0.25, 1.0])
  end

  it 'gives a list one value per band, repeating' do
    expect(ph(1, 2).to_a(5)).to eq([1, 2, 1, 2, 1])
    expect(ph([3, 4, 5]).to_a(2)).to eq([3, 4])
  end

  it 'prints itself back as Ruby' do
    expect(ph(15.cents..90.cents, curve: :exp).to_ruby).to eq('per_harmonic(15.cents..90.cents, curve: :exp)')
    expect(ph(0.db, -3.db).to_ruby).to eq('per_harmonic(0.db, -3.db)')
    expect(ph(1..2)).to eq(ph(1..2))
    expect(ph(1..2)).to be_frozen
  end

  it 'rejects ranges it can\'t spread' do
    expect { ph }.to raise_error(ArgumentError, /Range or at least one/)
    expect { ph(1.hz..3.0) }.to raise_error(ArgumentError, /one kind/)
    expect { ph(1...3) }.to raise_error(ArgumentError, /\.\./)
    expect { ph(1..) }.to raise_error(ArgumentError, /both ends/)
    expect { ph(1, 2, curve: :exp) }.to raise_error(ArgumentError, /curve/)
    expect { ph(1..2, curve: :bogus) }.to raise_error(ArgumentError, /Unknown curve/)
  end
end
