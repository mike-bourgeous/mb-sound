RSpec.describe(MB::Sound::Tone::State) do
  it 'starts at the given phase, unprimed' do
    s = described_class.new(phase: 0.25)
    expect(s.phi).to eq(0.25)
    expect(s.phase).to eq([0.25])
    expect(s.blep[3]).to eq(0)
    expect(s.blit[6]).to eq(0)
    expect(s.jump_residual).to eq(nil)
    expect(s.random?).to eq(false)
  end

  it 'wraps phases set with #phi=' do
    s = described_class.new
    s.phi = 1.75
    expect(s.phi).to eq(0.75)
    s.phi = -0.25
    expect(s.phi).to eq(0.75)
  end

  it 'round-trips through plain values, including the random generator' do
    s = described_class.new(phase: 0.1)
    s.seed = 42
    3.times { s.random }
    s.blep.replace([0.5, 0.01, 0.0, 1])
    s.jump_residual = Numo::DFloat[0.1, -0.2]
    s.last_freq = 440.0
    s.last_width = 0.3

    h = s.to_h
    expect(h.values.flatten.map(&:class).uniq - [Float, Integer, NilClass, FalseClass, TrueClass]).to be_empty

    copy = described_class.new(**h)
    expect(copy.to_h).to eq(h)
    expect(copy.random).to eq(s.random)
  end

  it 'counts random draws and restarts the generator when reseeded' do
    s = described_class.new
    s.seed = 7
    a = s.random
    expect(s.draws).to eq(1)
    s.seed = 7
    expect(s.draws).to eq(0)
    expect(s.random).to eq(a)
  end

  it 'forgets band-limiting history on #unprime' do
    s = described_class.new(phase: 0.4)
    s.blep[3] = 1
    s.blit[6] = 1
    s.sync.replace([0.9, 0.1, -1.0, 3, 1])
    s.sync_ring.fill(1)
    s.unprime(sync: true)
    expect(s.blep[3]).to eq(2) # unprimed after a jump (a fresh 0 means a first sample)
    expect(s.blit[6]).to eq(0)
    expect(s.sync).to eq([0.4, 0.0, 1.0, 0, 0])
    expect(s.sync_ring.abs.max).to eq(0)
  end

  it 'rejects unknown fields' do
    expect { described_class.new(volume: 1) }.to raise_error(ArgumentError, /volume/)
  end
end
