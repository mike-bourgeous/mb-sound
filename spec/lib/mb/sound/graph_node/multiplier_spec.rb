RSpec.describe(MB::Sound::GraphNode::Multiplier) do
  describe '#initialize' do
    it 'can create a multiplier with no multiplicands' do
      ss = MB::Sound::GraphNode::Multiplier.new([])
      expect(ss.sample(800)).to eq(Numo::SFloat.ones(800))
    end

    it 'can create a multiplier from an Array of multiplicands' do
      ss = MB::Sound::GraphNode::Multiplier.new(
        [
          0.5,
          MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(600).fill(1.5)], repeat: true),
          MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(600).fill(-0.75)], repeat: true),
        ]
      )
      expect(ss.sample(800)).to eq(Numo::SFloat.zeros(800).fill(-0.5625))
    end

    it 'can create a multiplier from a variable length argument list' do
      ss = MB::Sound::GraphNode::Multiplier.new(
          0.5,
          3,
          MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(600).fill(1.5)], repeat: true),
          MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(600).fill(-0.75)], repeat: true),
      )
      expect(ss.sample(800)).to eq(Numo::SFloat.zeros(800).fill(-1.6875))
    end
  end

  describe '#sample' do
    it 'can change the buffer size' do
      ss = MB::Sound::GraphNode::Multiplier.new([1, 0.hz.square.at(1.5).oscillator])
      expect(ss.sample(100)).to eq(Numo::SFloat.zeros(100).fill(1.5))
      expect(ss.sample(200)).to eq(Numo::SFloat.zeros(200).fill(1.5))
      expect(ss.sample(123)).to eq(Numo::SFloat.zeros(123).fill(1.5))
    end

    it 'raises an error if upstream nodes give different buffer sizes' do
      inp_a = double(MB::Sound::GraphNode)
      inp_b = double(MB::Sound::GraphNode)
      allow(inp_a).to receive(:sample).and_return(Numo::SFloat[1,2,3,4])
      allow(inp_b).to receive(:sample).and_return(Numo::SFloat[1,2,3,4,5])

      m = MB::Sound::GraphNode::Multiplier.new(inp_a, inp_b)
      expect { m.sample(4) }.to raise_error(/Input 1.*asked/)
      expect { m.sample(5) }.to raise_error(/Input 0.*asked/)
    end

    it 'returns the same buffer object if size and data type have not changed' do
      ss = MB::Sound::GraphNode::Multiplier.new([1, 0.hz.square.at(0.5).oscillator])
      a = ss.sample(100)
      b = ss.sample(100)
      c = ss.sample(100)
      expect(a.__id__).to eq(b.__id__)
      expect(b.__id__).to eq(c.__id__)
    end

    it 'can pass through a single input' do
      # With at least some sample rates, the square wave oscillator returns n+1
      # samples due to rounding inaccuracy in the oscillator's phase
      # advancement coefficient.  Sample rate of 1kHz was chosen to avoid this.
      ss = MB::Sound::GraphNode::Multiplier.new([1.hz.square.at_rate(1000).at(0.5).oscillator])
      expect(ss.sample(500)).to eq(Numo::SFloat.zeros(500).fill(0.5))
      expect(ss.sample(500)).to eq(Numo::SFloat.zeros(500).fill(-0.5))
    end

    it 'can multiply many inputs' do
      # With at least some sample rates, the square wave oscillator returns n+1
      # samples due to rounding inaccuracy in the oscillator's phase
      # advancement coefficient.  Sample rate of 1kHz was chosen to avoid this.
      ss = MB::Sound::GraphNode::Multiplier.new(
        1,
        -1,
        1.hz.square.at_rate(1000).at(1).oscillator,
        2.hz.square.at_rate(1000).at(0.25).oscillator,
      )

      expect(ss.sample(250)).to eq(Numo::SFloat.zeros(250).fill(-0.25))
      expect(ss.sample(250)).to eq(Numo::SFloat.zeros(250).fill(0.25))
      expect(ss.sample(250)).to eq(Numo::SFloat.zeros(250).fill(0.25))
      expect(ss.sample(250)).to eq(Numo::SFloat.zeros(250).fill(-0.25))
    end

    it 'returns SComplex if given a complex constant' do
      ss = MB::Sound::GraphNode::Multiplier.new([0+1i, 0.hz.square.at(1).oscillator])
      expect(ss.sample(800)).to eq(Numo::SComplex.zeros(800).fill(0+1i))
    end

    it 'returns SComplex if given a complex input' do
      ss = MB::Sound::GraphNode::Multiplier.new([180.hz.complex_sine.at(1).oscillator])
      osc = 180.hz.complex_sine.at(1).oscillator
      result = ss.sample(800)
      expect(result).to be_a(Numo::SComplex)
      expect(result).to eq(osc.sample(800))
    end

    it 'can change from SFloat to SComplex if the constant changes to complex' do
      osc = 0.hz.square.at(1).oscillator
      ss = MB::Sound::GraphNode::Multiplier.new([1, osc])

      result = ss.sample(100)
      expect(result).to be_a(Numo::SFloat)
      expect(result).to eq(Numo::SFloat.ones(100))

      ss.constant = 1+1i
      expect(ss.sample(100)).to be_a(Numo::SComplex)
    end

    it 'can change from SFloat to SComplex if an input changes to complex' do
      osc = 0.hz.square.at(1).oscillator
      ss = MB::Sound::GraphNode::Multiplier.new([1, osc])

      result = ss.sample(100)
      expect(result).to be_a(Numo::SFloat)
      expect(result).to eq(Numo::SFloat.ones(100))

      osc.wave_type = :complex_square
      expect(ss.sample(100)).to be_a(Numo::SComplex)
    end

    it 'returns nil when any input returns nil, if stop_early is true' do
      t1 = 0.hz.square.at(1).for(1).at_rate(50)
      t2 = 0.hz.square.at(0.5).for(1).at_rate(100)
      ss = MB::Sound::GraphNode::Multiplier.new(t1, t2)

      result = ss.sample(50)
      expect(result).to eq(Numo::SFloat.zeros(50).fill(0.5))

      expect(ss.sample(50)).to eq(nil)
    end

    it 'returns nil only when all inputs return nil, if stop_early is false' do
      t1 = 0.hz.square.at(1.5).for(1).at_rate(50)
      t2 = 0.hz.square.at(0.5).for(1).at_rate(100)
      ss = MB::Sound::GraphNode::Multiplier.new(t1, t2, stop_early: false)

      result = ss.sample(50)
      expect(result).to eq(Numo::SFloat.zeros(50).fill(0.75))

      result = ss.sample(50)
      expect(result).to eq(Numo::SFloat.zeros(50).fill(0.5))

      expect(ss.sample(50)).to eq(nil)
    end
  end

  describe '#clear' do
    it 'removes all non-constant multiplicands' do
      ss = MB::Sound::GraphNode::Multiplier.new([2, 0.hz.square.at(2).oscillator, 0.hz.square.at(-1).oscillator])
      expect(ss.sample(100)).to eq(Numo::SFloat.zeros(100).fill(-4))

      ss.clear
      expect(ss.constant).to eq(2)
      expect(ss.sample(100)).to eq(Numo::SFloat.zeros(100).fill(2))
    end
  end

  describe '#[]' do
    it 'returns a multiplicand by identity' do
      o1 = 0.hz.square.at(2).oscillator
      o2 = 0.hz.square.at(-1).oscillator
      ss = MB::Sound::GraphNode::Multiplier.new([2, o1, o2, 3-1i])
      expect(ss[o1]).to eq(o1)
      expect(ss[o2]).to eq(o2)
      expect(ss[ss]).to eq(nil)
      expect(ss.constant).to eq(6-2i)
    end

    it 'returns a multiplicand by index' do
      o1 = 0.hz.square.at(2).oscillator
      o2 = 0.hz.square.at(-1).oscillator
      ss = MB::Sound::GraphNode::Multiplier.new([2, o1, 4, 5, o2, 3-1i])
      expect(ss[0]).to equal(o1)
      expect(ss[1]).to equal(o2)
      expect(ss.constant).to eq(120-40i)
    end
  end

  describe '#delete' do
    it 'removes a multiplicand from the multiplier' do
      ss = MB::Sound::GraphNode::Multiplier.new([2, 0.hz.square.at(2).oscillator, 0.hz.square.at(-1).oscillator])
      ss.delete(ss.multiplicands.last)
      expect(ss.count).to eq(1)
      expect(ss.sample(100)).to eq(Numo::SFloat.zeros(100).fill(4))
    end

    it 'can remove a multiplicand by index' do
      ss = MB::Sound::GraphNode::Multiplier.new([2, 0.hz.square.at(2).oscillator, 0.hz.square.at(-1).oscillator])
      expect(ss.count).to eq(2)
      expect(ss.sample(100)).to eq(Numo::SFloat.zeros(100).fill(-4))

      ss.delete(0)
      expect(ss.count).to eq(1)
      expect(ss.sample(100)).to eq(Numo::SFloat.zeros(100).fill(-2))
    end
  end

  describe '#count' do
    it 'returns the number of multiplicands' do
      ss = MB::Sound::GraphNode::Multiplier.new([2, 0.hz.square.at(2).oscillator, 0.hz.square.at(-1).oscillator])
      expect(ss.count).to eq(2)

      ss.clear
      expect(ss.count).to eq(0)
    end
  end
end
