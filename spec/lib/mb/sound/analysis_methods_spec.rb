RSpec.describe(MB::Sound::AnalysisMethods) do
  pending '#crosscorrelate'
  pending '#peak_correlation'

  describe '#freq_estimate' do
    it 'works with complex values' do
      data = 150.hz.complex_ramp.sample(48000)
      expect(MB::Sound.freq_estimate(data).round(6)).to eq(150)
    end

    it 'returns nil if no correlation peak is in range' do
      data = 300.hz.ramp.sample(48000)
      expect(MB::Sound.freq_estimate(data, range: 10000..12000)).to eq(nil)
    end
  end
end
