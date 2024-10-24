RSpec.describe(MB::Sound::GraphNode::BufferAdapter) do
  describe '#sample' do
    it 'can read more samples than the upstream count' do
      upstream = 42.constant
      expect(upstream).to receive(:sample).twice.with(13).and_call_original
      b = MB::Sound::GraphNode::BufferAdapter.new(upstream: upstream, upstream_count: 13)
      expect(b.sample(21)).to eq(Numo::SFloat.zeros(21).fill(42))
    end

    it 'can read fewer samples than the upstream count' do
      upstream = 42.constant
      expect(upstream).to receive(:sample).with(17).and_call_original
      b = MB::Sound::GraphNode::BufferAdapter.new(upstream: upstream, upstream_count: 17)
      expect(b.sample(6)).to eq(Numo::SFloat.zeros(6).fill(42))
    end

    pending 'with values that are common factors'
    pending 'with a very large number of iterations'
  end

  pending 'when switching from real to complex'
  pending 'when resizing downstream count'
  pending 'when resizing upstream count'
end
