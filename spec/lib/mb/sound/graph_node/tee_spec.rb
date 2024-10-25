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

  pending 'when the upstream is nil'
end
