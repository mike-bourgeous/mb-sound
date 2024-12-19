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

    # FIXME: right now any internal buffer size must be an exact factor of the
    # upstream input's buffer size, or else the input will have to be read
    # twice and the two channels will get out of sync.
    pending 'with split inputs that reset themselves when re-sampled'
  end

  describe '#sources' do
    it 'returns the upstream as its sole source' do
      source = 5.constant
      chain = source.with_buffer(37)
      expect(chain).to be_a(MB::Sound::GraphNode::BufferAdapter)
      expect(chain.sources).to eq([source])
    end
  end

  pending 'when switching from real to complex'
  pending 'when resizing downstream count'
  pending 'when resizing upstream count'
  pending 'when the upstream is empty or nil'
end
