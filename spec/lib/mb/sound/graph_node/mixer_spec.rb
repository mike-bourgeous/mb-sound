RSpec.describe(MB::Sound::GraphNode::Mixer) do
  describe '#initialize' do
    it 'can create a mixer with no summands' do
      ss = MB::Sound::GraphNode::Mixer.new([])
      expect(ss.sample(800)).to eq(Numo::SFloat.zeros(800))
    end

    it 'can create a mixer from an Array of summands' do
      ss = MB::Sound::GraphNode::Mixer.new(
        [
          0.5,
          MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(600).fill(1.5)], repeat: true),
          MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(600).fill(-0.75)], repeat: true),
        ]
      )
      expect(ss.sample(800)).to eq(Numo::SFloat.zeros(800).fill(1.25))
    end

    it 'can create a mixer from an Array of summand-gain pairs' do
      ss = MB::Sound::GraphNode::Mixer.new(
        [
          [0.5, 3],
          [MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(600).fill(1.5)], repeat: true), 2],
          [MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(600).fill(-0.75)], repeat: true), 1],
        ]
      )
      expect(ss.sample(800)).to eq(Numo::SFloat.zeros(800).fill(3.75))
    end

    it 'can create a mixer from a Hash from summand to gain' do
      ss = MB::Sound::GraphNode::Mixer.new(
        {
          0.5 => 3,
          MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(600).fill(1.5)], repeat: true) => 2,
          MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(600).fill(-0.75)], repeat: true) => 1,
        }
      )
      expect(ss.sample(800)).to eq(Numo::SFloat.zeros(800).fill(3.75))
    end
  end

  describe '#sample' do
    it 'can change the buffer size' do
      ss = MB::Sound::GraphNode::Mixer.new([1, 0.hz.square.at(0.5).oscillator])
      expect(ss.sample(100)).to eq(Numo::SFloat.zeros(100).fill(1.5))
      expect(ss.sample(200)).to eq(Numo::SFloat.zeros(200).fill(1.5))
      expect(ss.sample(123)).to eq(Numo::SFloat.zeros(123).fill(1.5))
    end

    it 'returns the same buffer object if size and data type have not changed' do
      ss = MB::Sound::GraphNode::Mixer.new([1, 0.hz.square.at(0.5).oscillator])
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
      ss = MB::Sound::GraphNode::Mixer.new([1.hz.square.at_rate(1000).at(0.5).oscillator])
      expect(ss.sample(500)).to eq(Numo::SFloat.zeros(500).fill(0.5))
      expect(ss.sample(500)).to eq(Numo::SFloat.zeros(500).fill(-0.5))
    end

    it 'can sum and apply gain to multiple inputs' do
      # With at least some sample rates, the square wave oscillator returns n+1
      # samples due to rounding inaccuracy in the oscillator's phase
      # advancement coefficient.  Sample rate of 1kHz was chosen to avoid this.
      ss = MB::Sound::GraphNode::Mixer.new({
        1 => 1, # constants should cancel out
        -1 => 1,
        1.hz.square.at_rate(1000).at(1).oscillator => 0.5,
        2.hz.square.at_rate(1000).at(0.25).oscillator => 3,
      })

      expect(ss.sample(250)).to eq(Numo::SFloat.zeros(250).fill(1.25))
      expect(ss.sample(250)).to eq(Numo::SFloat.zeros(250).fill(-0.25))
      expect(ss.sample(250)).to eq(Numo::SFloat.zeros(250).fill(0.25))
      expect(ss.sample(250)).to eq(Numo::SFloat.zeros(250).fill(-1.25))
    end

    it 'returns SComplex if given a complex constant' do
      ss = MB::Sound::GraphNode::Mixer.new([0+1i, 0.hz.square.at(1).oscillator])
      expect(ss.sample(800)).to eq(Numo::SComplex.zeros(800).fill(1+1i))
    end

    it 'returns SComplex if given a complex input' do
      ss = MB::Sound::GraphNode::Mixer.new([180.hz.complex_sine.at(1).oscillator])
      osc = 180.hz.complex_sine.at(1).oscillator
      result = ss.sample(800)
      expect(result).to be_a(Numo::SComplex)
      expect(result).to eq(osc.sample(800))
    end

    it 'can change from SFloat to SComplex if the constant changes to complex' do
      osc = 0.hz.square.at(0).oscillator
      ss = MB::Sound::GraphNode::Mixer.new([1, osc])

      result = ss.sample(100)
      expect(result).to be_a(Numo::SFloat)
      expect(result).to eq(Numo::SFloat.ones(100))

      ss.constant = 1+1i
      expect(ss.sample(100)).to be_a(Numo::SComplex)
    end

    it 'can change from SFloat to SComplex if an input changes to complex' do
      osc = 0.hz.square.at(0).oscillator
      ss = MB::Sound::GraphNode::Mixer.new([1, osc])

      result = ss.sample(100)
      expect(result).to be_a(Numo::SFloat)
      expect(result).to eq(Numo::SFloat.ones(100))

      osc.wave_type = :complex_square
      expect(ss.sample(100)).to be_a(Numo::SComplex)
    end

    it 'can change from SFloat to SComplex if a gain changes to complex' do
      osc = 0.hz.square.at(0).oscillator
      ss = MB::Sound::GraphNode::Mixer.new([1, osc])

      result = ss.sample(100)
      expect(result).to be_a(Numo::SFloat)
      expect(result).to eq(Numo::SFloat.ones(100))

      ss[osc] = 1+1i
      expect(ss.sample(100)).to be_a(Numo::SComplex)
    end

    it 'returns nil when any input returns nil, if stop_early is true' do
      t1 = 0.hz.square.at(1).for(1).at_rate(50)
      t2 = 0.hz.square.at(0.5).for(1).at_rate(100)
      ss = MB::Sound::GraphNode::Mixer.new([t1, t2])

      result = ss.sample(50)
      expect(result).to eq(Numo::SFloat.zeros(50).fill(1.5))

      expect(ss.sample(50)).to eq(nil)
    end

    it 'returns nil only when all inputs return nil, if stop_early is false' do
      t1 = 0.hz.square.at(1).for(1).at_rate(50)
      t2 = 0.hz.square.at(0.5).for(1).at_rate(100)
      ss = MB::Sound::GraphNode::Mixer.new([t1, t2], stop_early: false)

      result = ss.sample(50)
      expect(result).to eq(Numo::SFloat.zeros(50).fill(1.5))

      result = ss.sample(50)
      expect(result).to eq(Numo::SFloat.zeros(50).fill(0.5))

      expect(ss.sample(50)).to eq(nil)
    end
  end

  describe '#clear' do
    it 'removes all non-constant summands' do
      ss = MB::Sound::GraphNode::Mixer.new([2, 0.hz.square.at(2).oscillator, 0.hz.square.at(-1).oscillator])
      expect(ss.sample(100)).to eq(Numo::SFloat.zeros(100).fill(3))

      ss.clear
      expect(ss.constant).to eq(2)
      expect(ss.sample(100)).to eq(Numo::SFloat.zeros(100).fill(2))
    end
  end

  describe '#[]' do
    it 'returns the gain for a given summand' do
      o1 = 0.hz.square.at(2).oscillator
      o2 = 0.hz.square.at(-1).oscillator
      ss = MB::Sound::GraphNode::Mixer.new([2, [o1, 2], [o2, 3-1i]])
      expect(ss[o1]).to eq(2)
      expect(ss[o2]).to eq(3-1i)
    end

    it 'returns the gain for a summand by index excluding constant summands' do
      o1 = 0.hz.square.at(2).oscillator
      o2 = 0.hz.square.at(-1).oscillator
      ss = MB::Sound::GraphNode::Mixer.new([2, [o1, 2], 4, 5, [o2, 3-1i]])
      expect(ss[0]).to eq(2)
      expect(ss[1]).to eq(3-1i)
      expect(ss.constant).to eq(11)
    end
  end

  describe '#[]=' do
    it 'can change the gain of a summand by reference' do
      o1 = 0.hz.square.at(2).oscillator
      o2 = 0.hz.square.at(-1).oscillator
      ss = MB::Sound::GraphNode::Mixer.new([2, [o1, 2], [o2, 3]])
      expect(ss.sample(100)).to eq(Numo::SFloat.zeros(100).fill(3))

      ss[o1] = 1
      expect(ss.sample(100)).to eq(Numo::SFloat.ones(100))

      ss[o2] = -0.5
      expect(ss.sample(100)).to eq(Numo::SFloat.zeros(100).fill(4.5))
    end

    it 'can change the gain of a summand by index' do
      o1 = 0.hz.square.at(2).oscillator
      o2 = 0.hz.square.at(-1).oscillator
      ss = MB::Sound::GraphNode::Mixer.new([2, [o1, 2], [o2, 3]])
      expect(ss.sample(100)).to eq(Numo::SFloat.zeros(100).fill(3))

      ss[0] = 1
      expect(ss.sample(100)).to eq(Numo::SFloat.ones(100))

      ss[1] = -0.5
      expect(ss.sample(100)).to eq(Numo::SFloat.zeros(100).fill(4.5))
    end
  end

  describe '#delete' do
    it 'removes a summand from the mixer' do
      ss = MB::Sound::GraphNode::Mixer.new([2, 0.hz.square.at(2).oscillator, 0.hz.square.at(-1).oscillator])
      ss.delete(ss.summands.last)
      expect(ss.count).to eq(1)
      expect(ss.sample(100)).to eq(Numo::SFloat.zeros(100).fill(4))
    end

    it 'can remove a summand by index' do
      ss = MB::Sound::GraphNode::Mixer.new([2, 0.hz.square.at(2).oscillator, 0.hz.square.at(-1).oscillator])
      ss.delete(0)
      expect(ss.count).to eq(1)
      expect(ss.sample(100)).to eq(Numo::SFloat.zeros(100).fill(1))
    end
  end

  describe '#count' do
    it 'returns the number of summands' do
      ss = MB::Sound::GraphNode::Mixer.new([2, 0.hz.square.at(2).oscillator, 0.hz.square.at(-1).oscillator])
      expect(ss.count).to eq(2)

      ss.clear
      expect(ss.count).to eq(0)
    end
  end
end
