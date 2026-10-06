RSpec.describe(MB::Sound::GraphNode::FrozenCopy) do
  let(:copier) { described_class.new }

  it 'returns a writable copy of a frozen buffer' do
    a = Numo::SFloat[1, 2, 3].freeze
    c = copier.copy(a)
    expect(c).not_to be_frozen
    expect(c).to eq(a)
    c[0] = 5
    expect(a[0]).to eq(1)
  end

  it 'reuses its buffer while the type and length stay the same' do
    c = copier.copy(Numo::SFloat[1, 2, 3].freeze)
    d = copier.copy(Numo::SFloat[4, 5, 6].freeze)
    expect(d).to equal(c)
    expect(d.to_a).to eq([4, 5, 6])
  end

  it 'makes a new buffer for another type or length' do
    c = copier.copy(Numo::SFloat[1, 2, 3].freeze)
    d = copier.copy(Numo::SComplex[1, 2i].freeze)
    expect(d).not_to equal(c)
    expect(d.to_a).to eq([1, 2i])
    e = copier.copy(Numo::SComplex[1, 2i, 3].freeze)
    expect(e.to_a).to eq([1, 2i, 3])
  end

  it 'copies non-contiguous views' do
    base = Numo::SFloat.new(8).seq
    copier.copy(Numo::SFloat.zeros(4).freeze)
    expect(copier.copy(base[(0..) % 2].freeze).to_a).to eq([0, 2, 4, 6])
  end

  it 'lets arithmetic nodes use frozen constant buffers without changing them' do
    c = 10.constant
    node = c ** (220.hz.sine * 0.5)
    expected = 10 ** (Numo::DFloat.cast(220.hz.sine.sample(800)) * 0.5)
    out = node.sample(800)
    expect(out).to all_be_within(1e-4).of_array(expected)
    expect(c.sample(4).to_a).to eq([10] * 4)
  end
end
