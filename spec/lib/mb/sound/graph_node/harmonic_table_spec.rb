RSpec.describe(MB::Sound::GraphNode::HarmonicTable, aggregate_failures: true) do
  let(:w) { MB::Sound::Wavetable }

  def collect(node, buffers, count = 800)
    Numo::NArray.concatenate(Array.new(buffers) { node.sample(count).dup })
  end

  it 'plays a fixed spectrum like the same table' do
    a = 100.hz.harmonics([1, 0.5, 0, 0.25]).sample(960)
    b = 100.hz.wavetable(w.from_harmonics([1, 0.5, 0, 0.25])).sample(960)
    expect(a).to all_be_within(1e-4).of_array(b)
  end

  it 'is also Pitch#additive' do
    expect(MB::Sound::Pitch.instance_method(:additive)).to eq(MB::Sound::Pitch.instance_method(:harmonics))
    a = 100.hz.additive([1, 0.5, 0, 0.25], phases: [0, 1, 0, 2])
    expect(a).to be_a(described_class)
    expect(a.sample(960)).to eq(100.hz.harmonics([1, 0.5, 0, 0.25], phases: [0, 1, 0, 2]).sample(960))
    expect(MB::Sound::C4.additive([1, 0.5])).to be_a(described_class)
  end

  it 'takes phases' do
    a = 100.hz.harmonics([1, 1], phases: [0, Math::PI / 2]).sample(480)
    b = 100.hz.wavetable(w.from_harmonics([1, 1], [0, Math::PI / 2])).sample(480)
    expect(a).to all_be_within(1e-4).of_array(b)
  end

  it 'reads spectrum nodes at each update and crossfades to the new spectrum' do
    amp = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(4800).tap { |z| z[1024..] = 1 }])
    node = 100.hz.harmonics([0, amp], update: 512)
    data = collect(node, 6)
    expect(data[0...1024].abs.max).to eq(0)
    # The rebuild after sample 1024 crossfades over 512 samples
    expect(data[1024...1536].abs.max).to be > 0.1
    expect(data[2048..].abs.max).to be_within(1e-3).of(1)
    expect(node.sources.keys).to eq([:harmonic_2])
  end

  it 'calls a callable with the time' do
    times = []
    node = 100.hz.harmonics(->(t) { times << t; [1] }, update: 480)
    collect(node, 3)
    expect(times).to eq([0.0, 0.01, 0.02, 0.03, 0.04])
  end

  it 'keeps only harmonics below the alias ceiling at its pitch' do
    node = 3000.hz.harmonics(Array.new(40, 0.1))
    node.sample(100)
    expect(node.table.harmonics).to eq(9)

    node = 100.hz.harmonics(Array.new(40, 0.1))
    node.sample(100)
    expect(node.table.harmonics).to eq(40)
  end

  it 'follows a frequency node' do
    node = MB::Sound::Pitch.new(200.constant).harmonics([1])
    expect(node.sample(240)).to all_be_within(1e-4).of_array(200.hz.sine.sample(240))
    expect(node.sources.keys).to include(:frequency)
  end

  it 'rejects bad arguments' do
    expect { 100.hz.harmonics(5) }.to raise_error(ArgumentError, /Spectrum/)
    expect { 100.hz.harmonics([1], update: 0) }.to raise_error(ArgumentError, /Update/)
  end
end
