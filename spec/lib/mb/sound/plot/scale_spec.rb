RSpec.describe(MB::Sound::Plot::Scale) do
  let(:s) { MB::Sound::Plot::Scale }

  it 'fits linear scales to nice ticks' do
    sc = s::Linear.new.fit(0.03, 0.97)
    expect([sc.lo, sc.hi]).to eq([0.0, 1.0])
    expect(sc.ticks(5).map(&:label)).to eq(%w[0.0 0.2 0.4 0.6 0.8 1.0])
    expect(sc.map(Numo::DFloat[0, 0.5, 1]).to_a).to eq([0, 0.5, 1])
    expect(sc.invert(0.25)).to eq(0.25)
  end

  it 'keeps a given domain and widens flat data' do
    expect(s::Linear.new(-3..3).fit(0, 1).hi).to eq(3)
    flat = s::Linear.new(nice: false).fit(2, 2)
    expect([flat.lo, flat.hi]).to eq([1.0, 3.0])
  end

  it 'centers symmetric scales on zero' do
    sc = s::Symmetric.new.fit(-0.3, 0.83)
    expect([sc.lo, sc.hi]).to eq([-1.0, 1.0])
  end

  it 'floors dB scales so silence fits' do
    sc = s::DB.new(floor: -90).fit(-Float::INFINITY, -3)
    expect(sc.lo).to eq(-90)
    expect(sc.title).to eq('level (dB)')
  end

  it 'makes decade ticks on log scales and rejects nonpositive values' do
    sc = s::Log.new(1..10_000)
    expect(sc.ticks.select(&:label).map(&:label)).to eq(%w[1 10 100 1k 10k])
    expect(sc.ticks.count { |t| t.label.nil? }).to eq(32)
    expect(sc.map(1000)).to be_within(1e-12).of(0.75)
    expect(sc.valid(Numo::DFloat[-1, 0, 1]).to_a).to eq([0, 0, 1])
    expect { s::Log.new(0..10) }.to raise_error(ArgumentError, /positive/)
  end

  it 'labels frequency scales with note names of every C' do
    sc = s::Frequency.new(50..5000, notes: true)
    names = sc.secondary_ticks.map(&:label)
    expect(names).to eq(%w[C2 C3 C4 C5 C6 C7 C8])
    expect(s::Frequency.new(20..20000, notes: true).secondary_ticks.map(&:label)).to eq(%w[C1 C3 C5 C7 C9])
    expect(s::Frequency.new(100..200, notes: 1).secondary_ticks.map(&:label)).to eq(%w[G#2 A2 A#2 B2 C3 C#3 D3 D#3 E3 F3 F#3 G3])
    c4 = sc.secondary_ticks.find { |t| t.label == 'C4' }
    expect(c4.value).to be_within(0.01).of(261.63)
    expect(sc.title).to eq('frequency (Hz)')
  end

  it 'labels time in ms from sample indexes' do
    sc = s::Time.new(sample_rate: 48000).fit(0, 4799)
    expect(sc.title).to eq('time (ms)')
    ticks = sc.ticks(5)
    expect(ticks.map(&:label)).to eq(%w[0 20 40 60 80])
    expect(ticks[1].value).to be_within(1e-9).of(960)
  end

  it 'labels bars and beats' do
    sc = s::Time.new(0..2, unit: :bars)
    expect(sc.ticks(8).map(&:label)).to start_with('1', '1.2', '1.3', '1.4', '2')
  end

  it 'names categories' do
    sc = s::Categorical.new(%w[kick snare hat])
    expect(sc.ticks.map(&:label)).to eq(%w[kick snare hat])
    expect(sc.map(1)).to eq(0.5)
  end

  it 'builds scales from builder arguments' do
    expect(s.build(:freq)).to be_a(s::Frequency)
    expect(s.build(-1..1).fixed?).to eq(true)
    expect(s.build(:db, -60..0).lo).to eq(-60)
    expect { s.build(:bogus) }.to raise_error(ArgumentError, /Unknown scale/)
  end
end
