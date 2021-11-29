RSpec.describe(MB::Sound::Mixer) do
  describe '#initialize' do
    it 'can create a mixer with no summands' do
      ss = MB::Sound::Mixer.new([])
      expect(ss.sample(800)).to eq(Numo::SFloat.zeros(800))
    end

    it 'can create a mixer from an Array of summands' do
      ss = MB::Sound::Mixer.new(
        [
          0.5,
          MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(600).fill(1.5)], repeat: true),
          MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(600).fill(-0.75)], repeat: true),
        ]
      )
      expect(ss.sample(800)).to eq(Numo::SFloat.zeros(800).fill(1.25))
    end

    it 'can create a mixer from an Array of summand-gain pairs' do
      ss = MB::Sound::Mixer.new(
        [
          [0.5, 3],
          [MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(600).fill(1.5)], repeat: true), 2],
          [MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(600).fill(-0.75)], repeat: true), 1],
        ]
      )
      expect(ss.sample(800)).to eq(Numo::SFloat.zeros(800).fill(3.75))
    end

    it 'can create a mixer from a Hash from summand to gain' do
      ss = MB::Sound::Mixer.new(
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
    pending 'can change the buffer size'
    pending 'can pass through a single input'
    pending 'can sum and apply gain to multiple inputs'
    pending 'returns SComplex if given a complex constant'
    pending 'returns SComplex if given a complex input'
    pending 'returns the same buffer object if size and data type have not changed'
    pending 'can change from SFloat to SComplex if the constant changes to complex'
  end

  pending '#clear'
  pending '#[]'
  pending '#[]='
  pending '#delete'
  pending '#count'
end
