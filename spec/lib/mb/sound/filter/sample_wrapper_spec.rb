RSpec.describe(MB::Sound::Filter::SampleWrapper) do
  describe '#sample' do
    it 'pads short inputs' do
      i = 1000.hz.lowpass.wrap(0.hz.square.at(0).at_rate(50).for(1))
      expect(i.sample(10)).to eq(Numo::SFloat.zeros(10))
      expect(i.sample(80)).to eq(Numo::SFloat.zeros(80))
      expect(i.sample(50)).to eq(nil)
    end

    it 'returns nil when the input returns nil' do
      i = 1000.hz.lowpass.wrap(0.hz.square.at(0).at_rate(50).for(1))
      expect(i.sample(50)).to eq(Numo::SFloat.zeros(50))
      expect(i.sample(50)).to eq(nil)
    end
  end
end
