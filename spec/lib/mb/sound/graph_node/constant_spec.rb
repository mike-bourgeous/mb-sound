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

      describe '#indexed_change' do
        it 'interpolates values starting at the specified time' do
          c = 0.constant(smoothing: v)
          c.sample(800) # set buffer size

          c.indexed_change(20.5, 150)
          c.indexed_change(-20.5, 275)

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

          c.indexed_change(20, 50)
          c.indexed_change(25, 50)
          c.indexed_change(30, 250)

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

          c.indexed_change(30, 250)

          data = c.sample(800)
          expect(data[0...50].minmax).to eq([0, 0])
          expect(data[250]).to be_within(0.1).of(0)
          expect(data[650]).not_to be_within(0.1).of(30)
          expect(data[799]).to be_within(0.1).of(30)
        end

        it 'accepts changes out of order' do
          c = 0.constant(smoothing: v)
          c.sample(800) # set buffer size

          c.indexed_change(-20.5, 275)
          c.indexed_change(20.5, 150)
          c.indexed_change(10, 360)
          c.indexed_change(5, 10)

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

    describe '#indexed_change' do
      it 'jumps instantly at each specified change' do
        c = 30.constant(smoothing: false)
        c.sample(800) # set buffer size

        c.indexed_change(10, 50)
        c.indexed_change(-5, 105)

        data = c.sample(800)
        expect(data[0...50].mean).to eq(30)
        expect(data[50...105].mean).to eq(10)
        expect(data[105...].mean).to eq(-5)
      end

      it 'works with just one change' do
        c = 30.constant(smoothing: false)
        c.sample(200) # set buffer size

        c.indexed_change(-5, 105)

        data = c.sample(200)
        expect(data[0...105].mean).to eq(30)
        expect(data[105...].mean).to eq(-5)
      end

      it 'works with no changes' do
        c = 30.constant(smoothing: false)
        c.sample(200) # set buffer size
        c.indexed_change(-5, 105)
        c.sample(200)

        expect(c.sample(200).minmax).to eq([-5, -5])
      end
    end
  end

  describe '#timed_change' do
    it 'calls #indexed_change with sample count derived from sample rate' do
      c = 10.constant(sample_rate: 12345)
      c.sample(800)

      expect(c).to receive(:indexed_change).with(42, 256).and_call_original
      c.timed_change(42.0, 256.1 / 12345.0)

      data = c.sample(800)
      expect(data[255]).to eq(10)
      expect(data[257]).to be_within(0.1).of(10)
      expect(data[799]).to be_within(0.01).of(42)
    end
  end

  describe '#sample_rate' do
    it 'returns the rate given to the constructor' do
      expect(c123.sample_rate).to eq(48000)
      expect(c123i45.sample_rate).to eq(44100)
    end
  end

  describe 'steady buffers' do
    let(:c) { 0.25.constant }

    it 'returns one frozen buffer while the value and count stay the same' do
      a = c.sample(128)
      expect(a).to be_frozen
      expect(a.to_a).to eq([0.25] * 128)
      expect(c.sample(128)).to equal(a)
    end

    it 'allocates nothing for a steady value' do
      c.sample(128)
      before = GC.stat(:total_allocated_objects)
      100.times { c.sample(128) }
      expect(GC.stat(:total_allocated_objects) - before).to be < 5
    end

    it 'makes a new buffer when the count changes' do
      a = c.sample(128)
      b = c.sample(64)
      expect(b).not_to equal(a)
      expect(b.to_a).to eq([0.25] * 64)
    end

    it 'follows value changes with and without smoothing' do
      a = c.sample(4)
      c.constant = 1
      changed = c.sample(4)
      expect(changed).not_to equal(a)
      expect(changed.to_a).to all(be_between(0.25, 1).exclusive)
      expect(changed[-1]).to be > changed[0]

      steady = c.sample(4)
      expect(steady).to be_frozen
      expect(steady.to_a).to eq([1, 1, 1, 1])

      c.smoothing = false
      c.constant = -0.5
      expect(c.sample(4).to_a).to eq([-0.5] * 4)
      expect(c.sample(4).to_a).to eq([-0.5] * 4)
    end

    it 'changes to a complex buffer for a complex value' do
      c.sample(4)
      c.smoothing = false
      c.constant = 1 + 2i
      c.sample(4)
      buf = c.sample(4)
      expect(buf).to be_a(Numo::SComplex)
      expect(buf.to_a).to eq([1 + 2i] * 4)
    end

    it 'gives a new buffer for a signed zero' do
      z = 0.0.constant(smoothing: false)
      a = z.sample(4)
      z.constant = -0.0
      z.sample(4)
      b = z.sample(4)
      expect(b.to_a.map { |v| 1 / v }).to eq([-Float::INFINITY] * 4)
      expect(a.to_a.map { |v| 1 / v }).to eq([Float::INFINITY] * 4)
    end

    it 'cannot be changed by a consumer' do
      a = c.sample(8)
      expect { a.inplace * 2 }.to raise_error(/frozen/)
      expect { a[0] = 1 }.to raise_error(/frozen/)
      expect(c.sample(8).to_a).to eq([0.25] * 8)
    end
  end

  it 'never ends' do
    c = 1.constant(sample_rate: 1)
    3.times { expect(c.sample(6)).to eq(Numo::SFloat.ones(6)) }
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
