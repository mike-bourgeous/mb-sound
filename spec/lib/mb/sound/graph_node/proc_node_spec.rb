RSpec.describe(MB::Sound::GraphNode::ProcNode) do
  describe '#initialize' do
    it 'can include extra source nodes' do
      a = 1.constant.named('A')
      b = 2.constant.named('B')
      pn = MB::Sound::GraphNode::ProcNode.new(a, [b]) do |v|
        v
      end

      expect(pn.find_by_name('A')).to equal(a)
      expect(pn.find_by_name('B')).to equal(b)
    end

    it 'allows parallel branching' do
      a = 6000.hz.square.at(1)
      # FIXME: need to discard first sample from square wave oscillators because of rounding on phase
      a.sample(1)

      b = a.get_sampler
      p = a.proc { |v| v + 1 }

      expect(b.sample(13)).to eq(Numo::SFloat[1, 1, 1, 1, -1, -1, -1, -1, 1, 1, 1, 1, -1])
      expect(p.sample(14)).to eq(Numo::SFloat[2, 2, 2, 2, 0, 0, 0, 0, 2, 2, 2, 2, 0, 0])
    end
  end

  describe '#sample' do
    it 'calls the block given to the constructor' do
      p = ->(d) { d * 4 }
      pn = MB::Sound::GraphNode::ProcNode.new(1.constant, &p)

      expect(pn.sample(1)[0]).to eq(4)
    end
  end
end
