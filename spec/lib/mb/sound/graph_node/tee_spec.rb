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
    expect(a1).to eq(b1)

    ref = a1.dup

    b2 = b.sample(100)
    a2 = a.sample(100)
    expect(a2).to eq(b2)
    expect(ref).not_to eq(b2)
  end

  it 'shares one frozen buffer among branches read in lockstep' do
    a, b = 157.hz.tee
    a1 = a.sample(100)
    b1 = b.sample(100)
    expect(a1).to equal(b1)
    expect(a1).to be_frozen
  end

  it 'passes a frozen source buffer through as it is' do
    buf = Numo::SFloat.new(100).fill(0.5).freeze
    a, b = 0.constant.proc { buf }.tee
    expect(a.sample(100)).to equal(buf)
    expect(b.sample(100)).to equal(buf)
    expect(a.sample(100)).to equal(buf)
  end

  it 'gives each branch a copy with sharing turned off' do
    MB::Sound::GraphNode::Tee.shared = false
    a, b = 157.hz.tee
    a1 = a.sample(100)
    b1 = b.sample(100)
    expect(a1).not_to equal(b1)
    expect(a1).to eq(b1)
  ensure
    MB::Sound::GraphNode::Tee.shared = true
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

    t1, t2 = source.tee

    expect(t1.sample(47999)).to eq(Numo::SFloat.zeros(47999).fill(1))
    expect(t1.sample(2)).to eq(Numo::SFloat[1,1])
    expect { t2.sample(1) }.to raise_error(MB::Sound::GraphNode::Tee::BranchBufferOverflow)
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

  describe '#add_branch' do
    it 'adds a new branch to an existing tee' do
      t = MB::Sound::GraphNode::Tee.new(13.constant)
      t1, t2 = t.branches

      t3 = t.add_branch

      expect(t.branches).to eq([t1, t2, t3])
    end

    it 'creates branches that function normally' do
      t = MB::Sound::GraphNode::Tee.new(13.constant, 0)
      t1 = t.add_branch

      expect(t1.sample(5)).to eq(Numo::SFloat[13,13,13,13,13])
    end
  end

  describe '::Branch' do
    describe '#destroy' do
      it 'removes a branch from the tee' do
        t = MB::Sound::GraphNode::Tee.new(5.constant)
        t1, t2 = t.branches
        t2.destroy
        expect(t.branches).to eq([t1])

        expect { t2.sample(4) }.to raise_error(MB::Sound::GraphNode::Tee::BranchDestroyedError)
      end
    end

  end

  describe 'shared buffers' do
    let(:source) { MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(4000).seq]) }

    it 'raises when a node writes to a shared buffer' do
      a, b = source.tee
      writer = a.proc { |buf| buf[0] = 5; buf }
      expect { writer.sample(100) }.to raise_error(/frozen/)
    end

    it 'raises at the next buffer when in-place arithmetic changes a shared buffer', :check_shared do
      a, b = source.tee
      doubler = a.proc { |buf| buf.inplace * 2 }
      doubler.sample(100)
      b.sample(100)
      expect { doubler.sample(100) }.to raise_error(MB::Sound::GraphNode::Tee::SharedBufferModified, /modified the buffer shared/)
    end

    it 'warns and copies for each branch from then on with :warn' do
      MB::Sound::GraphNode::Tee.shared_check = :warn
      a, b = source.tee
      doubler = a.proc { |buf| buf.inplace * 2 }
      doubler.sample(100)
      b.sample(100)
      expect { doubler.sample(100) }.to output(/Copying the buffer for each branch/).to_stderr
      expect(b.sample(100)).to eq(Numo::SFloat.new(100).seq + 100) # not doubled by the other branch
    ensure
      MB::Sound::GraphNode::Tee.shared_check = nil
    end

    it 'passes a well-behaved graph with checks on', :check_shared do
      a, b, c = source.tee(3)
      sum = (a * 2 + b.softclip + c.abs.filter(:lowpass, cutoff: 1000)).delay(0.001)
      expect { 20.times { sum.sample(100) } }.not_to raise_error
    end

    it 'falls back to copies when branches read out of step, and shares again once caught up' do
      a, b = source.tee
      a1 = a.sample(10).dup
      a2 = a.sample(10).dup # b hasn't read yet: buffered
      expect(b.sample(10)).to eq(a1)
      expect(b.sample(10)).to eq(a2)
      x = a.sample(10)
      y = b.sample(10)
      expect(x).to equal(y)
      expect(x).to eq(Numo::SFloat.new(10).seq + 20)
    end
  end
end
