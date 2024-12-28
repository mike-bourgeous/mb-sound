RSpec.describe(MB::Sound::GraphNode::Tee) do
  it 'can be created' do
    a, b = 123.hz.tee
    expect(a).to be_a(MB::Sound::GraphNode::Tee::Branch)
    expect(b).to be_a(MB::Sound::GraphNode::Tee::Branch)
  end

  it 'can create more than two branches' do
    branches = 123.hz.tee(5)
    expect(branches.length).to eq(5)
    expect(branches.all?(MB::Sound::GraphNode::Tee::Branch)).to eq(true)
  end

  it 'gives the same data to each branch' do
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

  it 'zero pads if the source returns less data' do
    source = MB::Sound::ArrayInput.new(data: [Numo::SFloat[]])
    expect(source).to receive(:sample).with(5).and_return(Numo::SFloat[1,2,3,4,5], Numo::SFloat[6,7])
    allow(source).to receive(:tee).and_call_original

    t1, t2 = source.tee

    t1.sample(5)
    t2.sample(5)

    expect(t1.sample(5)).to eq(Numo::SFloat[6,7,0,0,0])
    expect(t2.sample(5)).to eq(Numo::SFloat[6,7,0,0,0])
  end

  it 'returns nil if the source returns nil' do
    source = double(MB::Sound::GraphNode)
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
    allow(source).to receive(:sample).and_return(Numo::SFloat[1,2,3], Numo::SFloat[])

    t1, t2 = MB::Sound::GraphNode::Tee.new(source).branches

    expect(t1.sample(3)).to eq(Numo::SFloat[1,2,3])
    expect(t2.sample(3)).to eq(Numo::SFloat[1,2,3])

    expect(t1.sample(3)).to eq(nil)
    expect(t2.sample(3)).to eq(nil)
    expect(t1.sample(3)).to eq(nil)
    expect(t2.sample(3)).to eq(nil)
  end
end
