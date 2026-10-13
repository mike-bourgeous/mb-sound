RSpec.describe(MB::Sound::Decibels, :aggregate_failures) do
  let(:d) { -6.db }
  let(:gain) { 10.0 ** (-6 / 20.0) }

  it 'is what Numeric#db returns, with the same gain as before' do
    expect(d).to be_a(MB::Sound::Decibels)
    expect(d.to_f).to eq(gain)
    expect(d.decibels).to eq(-6)
    expect(d.db_value).to eq(-6.0)
    expect(-6.5.db.to_f).to eq(10.0 ** (-6.5 / 20.0))
    expect((13r / 2).db.to_f).to eq(10.0 ** (13r / 2 / 20.0))
    expect(-6.dB).to eq(d)
    expect(Complex(1, 1).db).to be_a(Complex)
  end

  it 'does arithmetic as its gain, returning plain numbers' do
    expect(d * 2).to eq(gain * 2)
    expect((d * 2).class).to eq(Float)
    expect(2 * d).to eq(2 * gain)
    expect(1 - d).to eq(1 - gain)
    expect(d / 2r).to eq(gain / 2r)
    expect(2r * d).to eq(2r * gain)
    expect(-d).to eq(-gain)
    expect(d ** 2).to eq(gain ** 2)
    expect(Math.log10(d)).to eq(Math.log10(gain))
    expect(d.to_db).to eq(gain.to_db)
    expect(d.round(3)).to eq(0.501)
    expect(Float(d)).to eq(gain)
    expect(format('%.4f', d)).to eq('0.5012')
  end

  it 'compares with numbers like its gain' do
    expect(d).to eq(gain)
    expect(gain).to eq(d)
    expect(d < 1).to eq(true)
    expect(1 > d).to eq(true)
    expect(d.clamp(0, 0.25)).to eq(0.25)
    expect([0.6, d, 0.1].sort).to eq([0.1, gain, 0.6])
    expect((0..1).cover?(d)).to eq(true)
    expect(d).to be_positive
    expect(0.db).to eq(1)
  end

  it 'is equal as a Hash key only to the same dB value' do
    expect(d).to eql(-6.db)
    expect(d).not_to eql(gain)
    expect({ -6.db => 1 }[-6.db]).to eq(1)
    expect(d).to be_frozen
  end

  it 'prints as Ruby that makes it, and as its gain in strings' do
    expect(d.inspect).to eq('-6.db')
    expect(-6.5.db.inspect).to eq('-6.5.db')
    expect((13r / 2).db.inspect).to eq('(13r/2).db')
    expect("#{d}").to eq(gain.to_s)
    expect(Marshal.load(Marshal.dump(d))).to eql(d)
  end

  it 'works with Numo arrays on either side' do
    a = Numo::SFloat[1, 2]
    expect(a * d).to eq(a * gain)
    expect(d * a).to eq(gain * a)
    expect(Numo::DFloat[1, 2] / d).to eq(Numo::DFloat[1, 2] / gain)
    expect(Numo::Int32[1, 2] * d).to eq(Numo::Int32[1, 2] * gain)
    expect(Numo::SComplex[1i] * d).to eq(Numo::SComplex[1i] * gain)
    expect(Numo::SFloat.zeros(3).fill(d)).to eq(Numo::SFloat.zeros(3).fill(gain))
    expect(Numo::SFloat[d, 1]).to eq(Numo::SFloat[gain, 1])
    b = Numo::SFloat[1, 2]
    b.inplace * d
    expect(b).to eq(Numo::SFloat[1, 2] * gain)
  end

  it 'gives graph nodes the same samples as its Float gain' do
    expect((220.hz.ramp * -20.db).sample(256)).to eq((220.hz.ramp * 0.1).sample(256))
    expect(220.hz.ramp.at(-6.db).sample(256)).to eq(220.hz.ramp.at(gain).sample(256))
    expect((1.constant * -6.db).sample(4)).to eq(Numo::SFloat.zeros(4).fill(gain))
  end

  it 'prints back as k.db in graph export and loads back in graph documents' do
    g = 220.hz.ramp.at(-6.db) * -6.5.db * (13r / 2).db
    code = g.to_ruby
    expect(code).to eq('220.hz.ramp.at(-6.db) * -6.5.db * (13r/2).db')

    h = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(g, name: 'db'))
    expect(h.to_ruby).to eq(code)
    expect(h.sample(800)).to eq(g.sample(800))
  end
end
