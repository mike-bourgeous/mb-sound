require_relative '../../../../support/synthetic_sounds'

RSpec.describe(MB::Sound::Analysis::BandEnvelopes) do
  let(:envs) { MB::Sound::Analysis::BandEnvelopes }

  it 'gives octave band levels every 5 ms and the top three octaves in thirds' do
    b = envs.new(SyntheticSounds.noise(0.5), band: 16000)
    expect(b.bands.first).to eq([125.0, 250.0])
    expect(b.bands.last).to eq([8000.0, 16000.0])
    expect(b.levels.shape).to eq([b.times.length, b.bands.length])
    expect(b.times[1] - b.times[0]).to be_within(1e-12).of(0.005)
    expect(b.top_bands.length).to eq(9)
    expect(b.top_bands.first[0]).to be_within(1e-9).of(2000)
    expect(b.relative.shape).to eq([b.times.length, 9])
  end

  it 'finds no movement on steady noise and movement on a swept top' do
    steady = envs.new(SyntheticSounds.noise(1), band: 16000)
    expect(steady.moving).to eq({})
    expect(steady.fluctuation.mean).to be < 1

    n = SyntheticSounds.noise(1, seed: 2)
    centers = SyntheticSounds.sweep(12000, 3000, n.length)
    swept = SyntheticSounds.bandpass(n, centers, 4) + n * 0.02
    m = envs.new(swept, band: 16000)
    expect(m.moving).not_to be_empty
    expect(m.std.max).to be > 6
    expect(m.to_s).to include('moving:')
  end

  it 'reads a top that fades as a negative slope' do
    t = SyntheticSounds.times(1)
    n = SyntheticSounds.noise(1, seed: 4)
    low = SyntheticSounds.tone(220, 1, harmonics: 5)
    high = MB::Sound::Analysis::DSP.brickwall(n, 48000, nil, low: 4000.0) * Numo::NMath.exp(-t * 4) * 0.2
    b = envs.new(low + high, band: 16000)
    expect(b.slope.mean).to be < -10
  end
end
