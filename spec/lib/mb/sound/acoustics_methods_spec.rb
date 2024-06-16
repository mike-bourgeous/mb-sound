RSpec.describe(MB::Sound::AcousticsMethods) do
  describe '#rt60' do
    it 'defaults to -60dB and a sample rate of 48kHz' do
      data = Numo::SFloat.logspace(0, -4, 48000)
      expect(MB::Sound.rt60(data)).to be_within(0.05).of(0.75)
    end
  end
end
