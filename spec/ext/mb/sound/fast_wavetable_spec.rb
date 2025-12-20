RSpec.describe(MB::Sound::FastWavetable) do
  # Additional tests are in wavetable_spec.rb
  describe '.outer_lookup' do
    it 'can retrieve a value from a wavetable' do
      expect(MB::Sound::FastWavetable.outer_lookup(Numo::SFloat[[0, 1], [-1, 2]], 0, 0)).to eq(0)
      expect(MB::Sound::FastWavetable.outer_lookup(Numo::SFloat[[0, 1], [-1, 2]], 0.5, 0.5)).to eq(2)
      expect(MB::Sound::FastWavetable.outer_lookup(Numo::SFloat[[0, 1], [-1, 2]], 0.5, 0)).to eq(-1)
    end
  end

  describe '.wavetable_lookup' do
    it 'can retrieve values from a wavetable using narrays' do
      table = Numo::SFloat[[0, 1], [-1, 2]]
      number = Numo::SFloat[0, 0.5, 0.5]
      phase = Numo::SFloat[0, 0.5, 0]

      expect(MB::Sound::FastWavetable.wavetable_lookup(table, number, phase)).to eq(Numo::SFloat[0, 2, -1])
    end
  end
end
