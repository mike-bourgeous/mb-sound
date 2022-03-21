RSpec.describe(MB::Sound::GraphNode::Constant) do
  it 'returns a constant value forever' do
    expect(MB::Sound::GraphNode::Constant.new(123).sample(480)).to eq(Numo::SFloat.zeros(480).fill(123))
  end

  it 'can use a complex constant' do
    expect(MB::Sound::GraphNode::Constant.new(123+45i).sample(480)).to eq(Numo::SComplex.zeros(480).fill(123+45i))
  end

  it 'can change to a complex constant' do
    c = MB::Sound::GraphNode::Constant.new(123)
    expect(c.sample(480)).to eq(Numo::SFloat.zeros(480).fill(123))

    c.constant = 1+1i
    c.sample(480) # get past smoothstep
    expect(c.sample(480)).to eq(Numo::SComplex.zeros(480).fill(1+1i))
  end

  context 'when smooth is true' do
    it 'smooths changes between values' do
      c = MB::Sound::GraphNode::Constant.new(100)

      c.constant = -100

      result = c.sample(480)
      expect(result.mean.round(2)).to eq(0)
      expect(result.max.round(2)).to eq(100)
      expect(result.min.round(2)).to eq(-100)
      expect(result[0].round(2)).to eq(100)
      expect(result[-1].round(2)).to eq(-100)
      expect((result[239] + result[240]).round(2)).to eq(0)
    end
  end

  context 'when smooth is false' do
    it 'changes values instantly' do
      c = MB::Sound::GraphNode::Constant.new(123, smooth: false)
      expect(c.sample(480)).to eq(Numo::SFloat.zeros(480).fill(123))

      c.constant = 1+1i
      expect(c.sample(480)).to eq(Numo::SComplex.zeros(480).fill(1+1i))
    end
  end
end
