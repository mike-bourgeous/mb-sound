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
    smoothed = c.sample(480) # get past smoothstep
    expect(MB::M.round(smoothed[0])).to eq(123)
    expect(MB::M.round(smoothed[-1])).to eq(1+1i)
    expect(c.sample(480)).to eq(Numo::SComplex.zeros(480).fill(1+1i))
  end

  [true, nil].each do |v|
    context "when smoothing is #{v.inspect}" do
      it 'interpolates changes between values' do
        c = MB::Sound::GraphNode::Constant.new(100, smoothing: v)

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
  end

  context 'when smoothing is false' do
    it 'changes values instantly' do
      c = MB::Sound::GraphNode::Constant.new(123, smoothing: false)
      expect(c.sample(480)).to eq(Numo::SFloat.zeros(480).fill(123))

      c.constant = 1+1i
      expect(c.sample(480)).to eq(Numo::SComplex.zeros(480).fill(1+1i))
    end
  end
end
