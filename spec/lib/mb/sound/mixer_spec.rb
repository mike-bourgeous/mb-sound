RSpec.describe(MB::Sound::Mixer) do
  describe '#initialize' do
    it 'can create a mixer with no summands' do
      ss = MB::Sound::Mixer.new([])
      expect(ss.sample(800)).to eq(Numo::SFloat.zeros(800))
    end

    pending 'can create a mixer from an Array of summands'

    pending 'can create a mixer from an Array of summand-gain pairs'

    pending 'can create a mixer from a Hash from summand to gain'
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
end
