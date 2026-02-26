RSpec.describe(MB::Sound::GraphNode::BufferAdapter, :aggregate_failures) do
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
      allow(us).to receive(:sample_rate).and_return(48000)
      expect(us).to receive(:get_sampler).and_return(MB::Sound::GraphNode::Tee.new(us, 1).branches[0])
      expect(us).to receive(:graph_buffer_size).and_return(800)

      b = MB::Sound::GraphNode::BufferAdapter.new(upstream: us, upstream_count: 4)
      expect(b.sample(4)).to eq(Numo::SFloat[1,2,3,4])
      expect(b.sample(4)).to eq(nil)
    end

    it 'shuts down cleanly when upstream returns less than expected' do
      us = double(MB::Sound::GraphNode)
      expect(us).to receive(:sample).with(4).at_least(3).times.and_return(Numo::SFloat[1,2,3,4], Numo::SFloat[5,6,7], nil)
      allow(us).to receive(:sample_rate).and_return(48000)
      expect(us).to receive(:get_sampler).and_return(MB::Sound::GraphNode::Tee.new(us, 1).branches[0])
      expect(us).to receive(:graph_buffer_size).and_return(800)

      b = MB::Sound::GraphNode::BufferAdapter.new(upstream: us, upstream_count: 4)
      expect(b.sample(3)).to eq(Numo::SFloat[1,2,3])
      expect(b.sample(3)).to eq(Numo::SFloat[4,5,6])
      expect(b.sample(3)).to eq(Numo::SFloat[7])
      expect(b.sample(3)).to eq(nil)
    end

    it 'continues working after many iterations' do
      # TODO: it would be nice if node sequences could repeat but they would
      # have to know how to reset their upstream node graph
      # FIXME: 120.hz.square has its phase off by one sample after the first half wave
      seq = 1.constant.for(200.0 / 48000)
        .and_then(-1.constant.for(200.0 / 48000))
        .and_then(1.constant.for(200.0 / 48000))
        .and_then(-1.constant.for(200.0 / 48000))

      b = seq.with_buffer(17)

      expect(b.sample(200)).to eq(Numo::SFloat.zeros(200).fill(1))
      expect(b.sample(200)).to eq(Numo::SFloat.zeros(200).fill(-1))

      50.times do
        expect(b.sample(4)).to eq(Numo::SFloat[1,1,1,1])
      end

      expect(b.sample(3)).to eq(Numo::SFloat[-1,-1,-1])
    end

    it 'can buffer split inputs' do
      ai = MB::Sound::ArrayInput.new(
        data: [
          Numo::SFloat[1,2,3,4,5,6,7,8,9,10],
          Numo::SFloat[9,8,7,6,5,4,3,2,1,0],
        ]
      )

      l, r = ai.split.map { |c| c.with_buffer(2) }

      expect(l.sample(3)).to eq(Numo::SFloat[1,2,3])
      expect(r.sample(3)).to eq(Numo::SFloat[9,8,7])
      expect(l.sample(2)).to eq(Numo::SFloat[4,5])
      expect(r.sample(2)).to eq(Numo::SFloat[6,5])
      expect(l.sample(5)).to eq(Numo::SFloat[6,7,8,9,10])
      expect(r.sample(5)).to eq(Numo::SFloat[4,3,2,1,0])
    end

    it 'can use different buffers on different branches of a tee' do
      t1, t2 = 1.constant.tee
      expect(t1).to receive(:sample).with(17).twice.and_call_original
      expect(t2).to receive(:sample).with(11).exactly(3).times.and_call_original

      b1 = t1.with_buffer(17)
      b2 = t2.with_buffer(11)

      expect(b1.sample(24)).to eq(Numo::SFloat.ones(24))
      expect(b1.sample(3)).to eq(Numo::SFloat[1,1,1])

      expect(b2.sample(23)).to eq(Numo::SFloat.ones(23))
    end
  end

  describe '#sources' do
    it 'returns the upstream tee/sampler as its sole source' do
      source = 5.constant
      chain = source.with_buffer(37)
      expect(chain).to be_a(MB::Sound::GraphNode::BufferAdapter)
      expect(chain.sources.keys).to eq([:input])
      expect(chain.sources[:input].original_source).to eq(source)
    end
  end

  describe '#sample_rate=' do
    it 'delegates to the source' do
      a = 10.constant
      b = a.with_buffer(123)

      expect(b).to be_a(MB::Sound::GraphNode::BufferAdapter)

      b.sample_rate = 51515

      expect(a.sample_rate).to eq(51515)
      expect(b.sample_rate).to eq(51515)
    end
  end

  describe '#at_rate' do
    it 'delegates to the source but returns self' do
      a = 10.constant
      b = a.with_buffer(123)

      expect(b).to be_a(MB::Sound::GraphNode::BufferAdapter)

      expect(b.at_rate(51515)).to equal(b)

      expect(a.sample_rate).to eq(51515)
      expect(b.sample_rate).to eq(51515)
    end
  end
end
