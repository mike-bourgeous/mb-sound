RSpec.describe MB::Sound::FFMPEGInput do
  describe '.parse_info' do
    it 'can read the metadata from a .flac sound' do
      info = MB::Sound::FFMPEGInput.parse_info('sounds/sine/sine_100_1s_mono.flac')

      expect(info).to be_a(Hash)
      expect(info[:duration_ts]).to eq(48000)
      expect(info[:duration].round(4)).to eq(1)
    end
  end

  pending '#initialize'

  pending '#read'

  pending '#close'
end
