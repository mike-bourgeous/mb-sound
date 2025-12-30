RSpec.describe(MB::Sound::Filter::FilterSum) do
  describe '#initialize' do
    it 'raises an error if filters have different sample rates' do
      a = 15.hz.at_rate(32170).lowpass
      b = 25.hz.at_rate(45678).lowpass
      b.singleton_class.undef_method(:sample_rate=)
      expect { MB::Sound::Filter::FilterSum.new(a, b) }.to raise_error(/rate.*45678.*32170/)
    end

    it 'raises an error if given inputs for a filter that lacks #dynamic_process' do
      a = 100.hz.lowpass
      a.singleton_class.undef_method(:dynamic_process)
      expect { MB::Sound::Filter::FilterSum.new({ filter: a, inputs: { cutoff: 150.constant, quality: 3.constant } }) }.to raise_error(/dynamic_process/)
    end
  end

  describe '#process' do
    it 'calls dynamic_process when given extra inputs for a filter' do
      f = 100.hz.lowpass
      sum = MB::Sound::Filter::FilterSum.new({ filter: f, inputs: { cutoff: 200.constant, quality: 10.constant } })

      expect { sum.process(Numo::SFloat[0]) }.to change { f.cutoff }.to(200).and(change { f.quality }.to(10))
    end
  end
end
