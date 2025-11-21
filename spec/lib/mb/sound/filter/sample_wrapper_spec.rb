RSpec.describe(MB::Sound::Filter::SampleWrapper, :aggregate_failures) do
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

  describe '#at_rate' do
    it 'changes upstream sample rates' do
      a = 2.constant
      b = 15.hz
      c = a * b
      d = c.delay(samples: 1)

      expect(d).to be_a(MB::Sound::Filter::SampleWrapper)
      d.at_rate(1234)

      expect(a.sample_rate).to eq(1234)
      expect(b.sample_rate).to eq(1234)
      expect(c.sample_rate).to eq(1234)
      expect(d.sample_rate).to eq(1234)
    end

    it 'supports method chaining' do
      d = 10.hz.filter(10.hz.lowpass)
      expect(d.at_rate(12345)).to equal(d)
    end
  end
end
