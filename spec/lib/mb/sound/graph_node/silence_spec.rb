RSpec.describe(MB::Sound::GraphNode::Silence, :aggregate_failures) do
  it 'outputs zeros for its length, then ends' do
    s = MB::Sound.silence(10.0 / 48000)
    expect(s.sample(6)).to eq(Numo::SFloat.zeros(6))
    expect(s.sample(6)).to eq(Numo::SFloat.zeros(4))
    expect(s.sample(6)).to eq(nil)
  end

  it 'keeps its remaining length in seconds when the sample rate changes' do
    s = MB::Sound.silence(1, sample_rate: 100)
    s.sample(50)
    s.sample_rate = 200
    expect(s.sample(1000).length).to eq(100)
  end

  it 'rejects negative lengths' do
    expect { MB::Sound.silence(-1) }.to raise_error(ArgumentError, /seconds/)
  end
end
