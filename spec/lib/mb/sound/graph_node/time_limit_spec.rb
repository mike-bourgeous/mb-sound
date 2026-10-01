RSpec.describe(MB::Sound::GraphNode::TimeLimit, :aggregate_failures) do
  describe 'GraphNode#until' do
    it 'passes the source through for its length, then ends' do
      node = 1.constant.until(10.0 / 48000)
      expect(node).to be_a(described_class)
      expect(node.sample(6)).to eq(Numo::SFloat.ones(6))
      expect(node.sample(6)).to eq(Numo::SFloat.ones(4))
      expect(node.sample(6)).to eq(nil)
    end

    it 'rounds the length to the nearest sample' do
      node = 1.constant.until(0.6 / 48000)
      expect(node.sample(30)).to eq(Numo::SFloat.ones(1))
      expect(node.sample(30)).to eq(nil)
    end

    it 'ends sooner if the source does' do
      node = 1.constant.until(3.0 / 48000).until(1)
      expect(node.sample(10)).to eq(Numo::SFloat.ones(3))
      expect(node.sample(10)).to eq(nil)
    end

    it 'counts at the sample rate, keeping elapsed seconds when it changes' do
      node = 1.constant.until(1).at_rate(100)
      expect(node.sample_rate).to eq(100)
      expect(node.sample(50).length).to eq(50)
      node.at_rate(200)
      expect(node.sample(1000).length).to eq(100)
      expect(node.sample(1)).to eq(nil)
    end

    it 'ends sums and products' do
      graph = 100.hz.ramp.until(0.1) * 0.5
      total = 0
      while (buf = graph.sample(800))
        total += buf.length
      end
      expect(total).to eq(4800)
    end

    it 'runs per channel on bundles' do
      bundle = MB::Sound.stereo(1.constant, 2.constant).until(2.0 / 48000)
      expect(bundle).to be_a(MB::Sound::GraphNode::Channels)
      expect(bundle.map { |c| c.sample(5).to_a }.to_a).to eq([[1, 1], [2, 2]])
    end

    it 'rejects negative and non-numeric lengths' do
      expect { 1.constant.until(-1) }.to raise_error(ArgumentError, /seconds/)
      expect { 1.constant.until('3') }.to raise_error(ArgumentError, /seconds/)
    end
  end
end
