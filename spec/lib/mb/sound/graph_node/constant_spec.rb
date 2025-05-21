RSpec.describe(MB::Sound::GraphNode::Constant) do
  let(:c123) { MB::Sound::GraphNode::Constant.new(123, sample_rate: 48000) }
  let(:c123i45) { MB::Sound::GraphNode::Constant.new(123+45i, sample_rate: 44100) }

  it 'returns a constant value forever' do
    expect(c123.sample(480)).to eq(Numo::SFloat.zeros(480).fill(123))
  end

  it 'can use a complex constant' do
    expect(c123i45.sample(480)).to eq(Numo::SComplex.zeros(480).fill(123+45i))
  end

  it 'can change to a complex constant' do
    expect(c123.sample(480)).to eq(Numo::SFloat.zeros(480).fill(123))

    c123.constant = 1+1i
    smoothed = c123.sample(480) # get past smoothstep
    expect(MB::M.round(smoothed[0])).to eq(123)
    expect(MB::M.round(smoothed[-1])).to eq(1+1i)
    expect(c123.sample(480)).to eq(Numo::SComplex.zeros(480).fill(1+1i))
  end

  [true, nil].each do |v|
    context "when smoothing is #{v.inspect}" do
      it 'interpolates changes between values' do
        c = MB::Sound::GraphNode::Constant.new(100, smoothing: v, sample_rate: 52341)

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
      c = MB::Sound::GraphNode::Constant.new(123, smoothing: false, sample_rate: 12121)
      expect(c.sample(480)).to eq(Numo::SFloat.zeros(480).fill(123))

      c.constant = 1+1i
      expect(c.sample(480)).to eq(Numo::SComplex.zeros(480).fill(1+1i))
    end
  end

  describe '#sample_rate' do
    it 'returns the rate given to the constructor' do
      expect(c123.sample_rate).to eq(48000)
      expect(c123i45.sample_rate).to eq(44100)
    end
  end

  describe '#for' do
    it 'resets the elapsed timer' do
      c = 1.constant.for(0)
      expect(c.sample(100)).to eq(nil)

      c.for(5.0 / 48000)
      expect(c.sample(100)).to eq(Numo::SFloat.ones(5))
    end

    context 'with a duration' do
      it 'returns only the requested length of data' do
        c = 1.constant(sample_rate: 1).for(10)
        expect(c.sample(6).length).to eq(6)
        expect(c.sample(6).length).to eq(4)
        expect(c.sample(1)).to eq(nil)
      end

      it 'handles fractional sample values' do
        c = 1.constant.for(0.00015)
        expect(c.sample(100).length).to eq(7)
      end
    end
  end
end
