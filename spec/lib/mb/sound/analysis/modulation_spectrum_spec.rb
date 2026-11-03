require_relative '../../../../support/synthetic_sounds'

RSpec.describe(MB::Sound::Analysis::ModulationSpectrum) do
  let(:ms) { MB::Sound::Analysis::ModulationSpectrum }

  it 'finds slow AM: its rate and depth, in the bands it moves' do
    m = ms.new(SyntheticSounds.tone(220, 4, am: [0.6, 1.5]))
    expect(m.peaks.length).to eq(1)
    pk = m.peaks.first
    expect(pk.rate).to be_a(MB::Sound::Pitch)
    expect(pk.rate.frequency).to be_within(0.02).of(0.6)
    expect(pk.depth).to be_a(MB::Sound::Decibels)
    expect(pk.depth.decibels).to be_within(0.1).of(1.5)
    expect(pk.bands.first[0]).to eq(125.0)
    expect(m.to_s).to match(/AM 0\.60 Hz \(rate ±0\.0\d\), ±1\.5 dB in 125 Hz-/)
    expect(pk.rate_error).to be_between(0.005, 0.05)
  end

  it 'finds faster AM in one band only' do
    base = SyntheticSounds.tone(110, 2, harmonics: 4, level: 0.3)
    hi = SyntheticSounds.sine(3000, 2, level: 0.2) * 10**(3 * Numo::NMath.sin(SyntheticSounds.times(2) * 2 * Math::PI * 5.5) / 20)
    m = ms.new(base + hi)
    pk = m.peaks.find { |p| p.bands.any? { |lo, hi_| lo <= 3000 && hi_ > 3000 } }
    expect(pk).not_to be_nil
    expect(pk.rate.frequency).to be_within(0.05).of(5.5)
    expect(pk.depth.decibels).to be_within(0.2).of(3.0)
    expect(m.peaks.map(&:bands).flatten(1)).not_to include([125.0, 250.0])
  end

  it 'reports no AM for a steady or decaying tone' do
    expect(ms.new(SyntheticSounds.tone(220, 2)).peaks).to eq([])
    decay = SyntheticSounds.tone(220, 2) * Numo::NMath.exp(-SyntheticSounds.times(2) * 2)
    expect(ms.new(decay).peaks).to eq([])
    expect(ms.new(decay).to_s).to start_with('no clear amplitude modulation')
  end

  it 'measures the depth table and a distance that grows with the AM' do
    a = ms.new(SyntheticSounds.tone(220, 2))
    expect(a.depths.shape).to eq([a.bands.length, ms::MOD_BANDS.length])
    expect(a.valid).to eq([false, true, true, true, true, true, true])
    expect(a.weights.sum).to be_within(1e-12).of(1)
    expect(a.distance(a)).to eq(0)
    near = a.distance(SyntheticSounds.tone(220, 2, am: [3, 0.5]))
    far = a.distance(SyntheticSounds.tone(220, 2, am: [3, 3]))
    expect(near).to be > 0
    expect(far).to be > 3 * near
  end

  it 'refuses distances over different bands' do
    a = ms.new(SyntheticSounds.tone(220, 1), band: 4000)
    b = ms.new(SyntheticSounds.tone(220, 1), band: 8000)
    expect { a.distance(b) }.to raise_error(ArgumentError, /Bands differ/)
  end

  it 'is deterministic' do
    x = SyntheticSounds.tone(220, 2, am: [2, 2])
    expect(ms.new(x).depths).to eq(ms.new(x).depths)
  end
end
