RSpec.describe(MB::Sound::GraphNode::BufferAdapter) do
  describe '#sample' do
    let(:upstream) { 42.constant }

    it 'can read more samples than the upstream count' do
      expect(upstream).to receive(:sample).twice.with(13).and_call_original
      b = MB::Sound::GraphNode::BufferAdapter.new(upstream: upstream, upstream_count: 13)
      expect(b.sample(21)).to eq(Numo::SFloat.zeros(21).fill(42))
    end

    it 'can read fewer samples than the upstream count' do
      expect(upstream).to receive(:sample).with(17).and_call_original
      b = MB::Sound::GraphNode::BufferAdapter.new(upstream: upstream, upstream_count: 17)
      expect(b.sample(6)).to eq(Numo::SFloat.zeros(6).fill(42))
    end

    it 'behaves well when the downstream size is a factor of the upstream size' do
      expect(upstream).to receive(:sample).with(24).twice.and_call_original
      b = upstream.with_buffer(24)
      6.times do
        expect(b.sample(8)).to eq(Numo::SFloat.zeros(8).fill(42))
      end
    end

    it 'behaves well when the downstream size is a multiple of the upstream size' do
      expect(upstream).to receive(:sample).with(8).exactly(6).times.and_call_original
      b = upstream.with_buffer(8)
      2.times do
        expect(b.sample(24)).to eq(Numo::SFloat.zeros(24).fill(42))
      end
    end

    it 'behaves well when the downstream size is smaller and not a factor' do
      expect(upstream).to receive(:sample).with(41).twice.and_call_original
      b = upstream.with_buffer(41)
      6.times do
        expect(b.sample(13)).to eq(Numo::SFloat.zeros(13).fill(42))
      end
    end

    it 'behaves well when the downstream size is larger and not a multiple' do
      expect(upstream).to receive(:sample).with(13).exactly(3).times.and_call_original
      b = upstream.with_buffer(13)
      2.times do
        expect(b.sample(17)).to eq(Numo::SFloat.zeros(17).fill(42))
      end
    end

    it 'can switch from real to complex' do
      cplx = 10.constant.for(0.001).and_then(-5i.constant.for(0.002))
      b = cplx.with_buffer(46)
      expect(b.sample(44)).to eq(Numo::SFloat.zeros(44).fill(10))
      expect(b.sample(8)).to eq(Numo::SComplex[10, 10, 10, 10, -5i, -5i, -5i, -5i])
    end

    it 'can handle changing downstream sizes' do
      expect(upstream).to receive(:sample).with(12).twice.and_call_original
      b = upstream.with_buffer(12)
      expect(b.sample(9)).to eq(Numo::SFloat.zeros(9).fill(42))
      expect(b.sample(13)).to eq(Numo::SFloat.zeros(13).fill(42))
      expect(b.sample(2)).to eq(Numo::SFloat.zeros(2).fill(42))
    end

    it 'shuts down cleanly when the upstream returns nil' do
      b = upstream.for(4.0 / 48000).with_buffer(4)
      expect(b.sample(4)).to eq(Numo::SFloat[42, 42, 42, 42])
      expect(b.sample(4)).to eq(nil)
    end

    it 'shuts down cleanly when the upstream returns empty' do
      us = double(MB::Sound::GraphNode)
      expect(us).to receive(:sample).with(4).twice.and_return(Numo::SFloat[1,2,3,4], Numo::SFloat[])

      b = MB::Sound::GraphNode::BufferAdapter.new(upstream: us, upstream_count: 4)
      expect(b.sample(4)).to eq(Numo::SFloat[1,2,3,4])
      expect(b.sample(4)).to eq(nil)
    end

    it 'shuts down cleanly when upstream returns less than expected' do
      us = double(MB::Sound::GraphNode)
      expect(us).to receive(:sample).with(4).exactly(3).times.and_return(Numo::SFloat[1,2,3,4], Numo::SFloat[5,6,7], nil)

      b = MB::Sound::GraphNode::BufferAdapter.new(upstream: us, upstream_count: 4)
      expect(b.sample(3)).to eq(Numo::SFloat[1,2,3])
      expect(b.sample(3)).to eq(Numo::SFloat[4,5,6])
      expect(b.sample(3)).to eq(Numo::SFloat[7])
      expect(b.sample(3)).to eq(nil)
    end

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
end
