RSpec.describe(MB::Sound::GraphNode::Tee, aggregate_failures: true) do
  it 'can be created' do
    a, b = 123.hz.tee
    expect(a).to be_a(MB::Sound::GraphNode::Tee::Branch)
    expect(b).to be_a(MB::Sound::GraphNode::Tee::Branch)
  end

  it 'can create more than two branches' do
    branches = 123.hz.tee(5)
    expect(branches.length).to eq(5)
    expect(branches).to all(be_a(MB::Sound::GraphNode::Tee::Branch))
  end

  it 'gives the same data to two branches' do
    a, b = 157.hz.tee

    a1 = a.sample(100)
    b1 = b.sample(100)
    expect(a1).not_to equal(b1)
    expect(a1).to eq(b1)

    ref = a1.dup

    b2 = b.sample(100)
    a2 = a.sample(100)
    expect(a2).not_to equal(b2)
    expect(a2).to eq(b2)
    expect(ref).not_to eq(b2)
  end

  it 'gives the same data to many branches' do
    branches = 123.hz.tee(24)
    expect(branches.length).to eq(24)
    expect(branches.all?(MB::Sound::GraphNode::Tee::Branch)).to eq(true)

    samples = branches.map { |b| b.sample(100) }
    expect(samples.uniq(&:to_a).count).to eq(1)
  end

  it 'does not zero pad if the source returns less data at the very end' do
    source = MB::Sound::ArrayInput.new(data: [Numo::SFloat[]])
    expect(source).to receive(:sample).with(5).and_return(Numo::SFloat[1,2,3,4], Numo::SFloat[5,6,7], nil)
    allow(source).to receive(:tee).and_call_original

    t1, t2 = source.tee

    expect(t1.sample(5)).to eq(Numo::SFloat[1,2,3,4,5])
    expect(t2.sample(5)).to eq(Numo::SFloat[1,2,3,4,5])

    expect(t1.sample(5)).to eq(Numo::SFloat[6,7])
    expect(t2.sample(5)).to eq(Numo::SFloat[6,7])
  end

  it 'allows branches to be sampled more than once with different sample counts' do
    source = MB::Sound::ArrayInput.new(data: [Numo::SFloat[1,2,3,4,5,6,7,8,9,-10]])

    t1, t2, t3 = source.tee(3)

    expect(t1.sample(4)).to eq(Numo::SFloat[1,2,3,4])
    expect(t1.sample(3)).to eq(Numo::SFloat[5,6,7])
    expect(t2.sample(10)).to eq(Numo::SFloat[1,2,3,4,5,6,7,8,9,-10])
    expect(t3.sample(5)).to eq(Numo::SFloat[1,2,3,4,5])
    expect(t1.sample(3)).to eq(Numo::SFloat[8,9,-10])
    expect(t3.sample(5)).to eq(Numo::SFloat[6,7,8,9,-10])
  end

  it 'raises an error if one branch gets too far out of sync' do
    source = 1.constant

    t1, _t2 = source.tee

    expect(t1.sample(47999)).to eq(Numo::SFloat.zeros(47999).fill(1))
    expect(t1.sample(1)).to eq(Numo::SFloat[1])
    expect { t1.sample(1) }.to raise_error(MB::Sound::GraphNode::Tee::BranchBufferOverflow)
  end

  it 'returns nil if the source returns nil' do
    source = double(MB::Sound::GraphNode)
    allow(source).to receive(:sample_rate).and_return(48000)
    allow(source).to receive(:sample).and_return(Numo::SFloat[1,2,3], nil)

    t1, t2 = MB::Sound::GraphNode::Tee.new(source).branches

    expect(t1.sample(3)).to eq(Numo::SFloat[1,2,3])
    expect(t2.sample(3)).to eq(Numo::SFloat[1,2,3])

    expect(t1.sample(3)).to eq(nil)
    expect(t2.sample(3)).to eq(nil)
    expect(t1.sample(3)).to eq(nil)
    expect(t2.sample(3)).to eq(nil)
  end

  it 'returns nil if the source returns empty' do
    source = double(MB::Sound::GraphNode)
    allow(source).to receive(:sample_rate).and_return(48000)
    allow(source).to receive(:sample).and_return(Numo::SFloat[1,2,3], Numo::SFloat[])

    t1, t2 = MB::Sound::GraphNode::Tee.new(source).branches

    expect(t1.sample(3)).to eq(Numo::SFloat[1,2,3])
    expect(t2.sample(3)).to eq(Numo::SFloat[1,2,3])

    expect(t1.sample(3)).to eq(nil)
    expect(t2.sample(3)).to eq(nil)
    expect(t1.sample(3)).to eq(nil)
    expect(t2.sample(3)).to eq(nil)
  end

  describe '#at_rate' do
    it 'can change the source sample rate' do
      source = 100.constant
      t1, t2 = MB::Sound::GraphNode::Tee.new(source).branches

      expect(t1.at_rate(5432)).to equal(t1)

      expect(t1.sample_rate).to eq(5432)
      expect(t2.sample_rate).to eq(5432)
      expect(source.sample_rate).to eq(5432)
    end
  end

  describe '#sample_rate=' do
    it 'can change the source sample rate' do
      source = 100.constant
      t1, t2 = MB::Sound::GraphNode::Tee.new(source).branches

      t1.sample_rate = 5432

      expect(t1.sample_rate).to eq(5432)
      expect(t2.sample_rate).to eq(5432)
      expect(source.sample_rate).to eq(5432)
    end
  end

  describe '::Branch#for' do
    it 'allows resetting time-limited upstream nodes' do
      a = 0.hz.square.at(1).for(0.0001).get_sampler
      expect(a).to be_a(MB::Sound::GraphNode::Tee::Branch)

      expect(a.sample(10)).to eq(Numo::SFloat.ones(5))
      expect(a.sample(10)).to eq(nil)

      a.for(0.0002)
      expect(a.sample(20)).to eq(Numo::SFloat.ones(10))
      expect(a.sample(1)).to eq(nil)
    end
  end
end
