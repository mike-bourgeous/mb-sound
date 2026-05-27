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

      describe '#timed_change' do
        it 'interpolates values starting at the specified time' do
          c = 0.constant(smoothing: v)
          c.sample(800) # set buffer size

          c.timed_change(20.5, 150)
          c.timed_change(-20.5, 275)

          data = c.sample(800)
          expect(data[0...150].minmax).to eq([0, 0])
          expect(data[151]).to be_within(0.01).of(0)
          expect(data[274]).to be_within(0.01).of(20.5)
          expect(data[276]).to be_within(0.01).of(20.5)
          expect(data[799]).to be_within(0.01).of(-20.5)
        end

        it 'coalesces changes that happen at the same time' do
          c = 0.constant(smoothing: v)
          c.sample(800) # set buffer size

          c.timed_change(20, 50)
          c.timed_change(25, 50)
          c.timed_change(30, 250)

          data = c.sample(800)
          expect(data[0...50].minmax).to eq([0, 0])
          expect(data[50]).to be_within(0.1).of(0)
          expect(data[250]).to be_within(0.1).of(25)
          expect(data[799]).to be_within(0.1).of(30)
          expect(data[650]).not_to be_within(0.1).of(30)
        end

        it 'works with a single change' do
          c = 0.constant(smoothing: v)
          c.sample(800) # set buffer size

          c.timed_change(30, 250)

          data = c.sample(800)
          expect(data[0...50].minmax).to eq([0, 0])
          expect(data[250]).to be_within(0.1).of(0)
          expect(data[650]).not_to be_within(0.1).of(30)
          expect(data[799]).to be_within(0.1).of(30)
        end

        it 'accepts changes out of order' do
          c = 0.constant(smoothing: v)
          c.sample(800) # set buffer size

          c.timed_change(-20.5, 275)
          c.timed_change(20.5, 150)
          c.timed_change(10, 360)
          c.timed_change(5, 10)

          data = c.sample(800)
          expect(data[0...10].minmax).to eq([0, 0])
          expect(data[11]).to be_within(0.25).of(0)
          expect(data[10...150].mean).to be_within(0.01).of(2.5)
          expect(data[151]).to be_within(0.01).of(5)
          expect(data[274]).to be_within(0.01).of(20.5)
          expect(data[276]).to be_within(0.1).of(20.5)
          expect(data[359]).to be_within(0.01).of(-20.5)
          expect(data[799]).to be_within(0.01).of(10)
        end
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

    describe '#timed_change' do
      it 'jumps instantly at each specified change' do
        c = 30.constant(smoothing: false)
        c.sample(800) # set buffer size

        c.timed_change(10, 50)
        c.timed_change(-5, 105)

        data = c.sample(800)
        expect(data[0...50].mean).to eq(30)
        expect(data[50...105].mean).to eq(10)
        expect(data[105...].mean).to eq(-5)
      end

      it 'works with just one change' do
        c = 30.constant(smoothing: false)
        c.sample(200) # set buffer size

        c.timed_change(-5, 105)

        data = c.sample(200)
        expect(data[0...105].mean).to eq(30)
        expect(data[105...].mean).to eq(-5)
      end

      it 'works with no changes' do
        c = 30.constant(smoothing: false)
        c.sample(200) # set buffer size
        c.timed_change(-5, 105)
        c.sample(200)

        expect(c.sample(200).minmax).to eq([-5, -5])
      end
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

  describe '#or_for' do
    it 'changes the default duration' do
      n = 0.constant
      expect { n.or_for(1.5) }.to change { n.duration }.to(1.5)
    end

    it 'does not change the duration if set with #for' do
      n = 0.constant.for(3)
      expect { n.or_for(1.5) }.not_to change { n.duration }
    end
  end

  describe '#to_s' do
    it 'includes units if given' do
      expect(500.constant(unit: 'Hz').to_s).to include('500Hz')
    end

    it 'uses si formatting by default' do
      expect(5000.constant.to_s).to include('5k')
    end

    it 'can remove si formatting' do
      expect(0.0125.constant(si: true).to_s).to include('12.500m')
      expect(0.0125.constant(si: false).to_s).to include('0.0125')
    end

    it 'removes trailing zeros' do
      expect(5.5.constant(si: false).to_s).to end_with('5.5')
    end
  end
end
