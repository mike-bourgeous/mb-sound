RSpec.describe MB::Sound::FFMPEGInput do
  describe '.parse_info' do
    it 'can read stream info from a .flac sound file' do
      info = MB::Sound::FFMPEGInput.parse_info('sounds/sine/sine_100_1s_mono.flac')

      expect(info).to be_a(Array)
      info = info.first
      expect(info).to be_a(Hash)
      expect(info[:duration_ts]).to eq(48000)
      expect(info[:duration].round(4)).to eq(1)
      expect(info[:channels]).to eq(1)
    end
  end

  let(:input) {
    MB::Sound::FFMPEGInput.new('sounds/sine/sine_100_1s_mono.flac')
  }

  let(:input_2ch) {
    MB::Sound::FFMPEGInput.new('sounds/sine/sine_100_1s_mono.flac', channels: 2)
  }

  let(:input_441) {
    MB::Sound::FFMPEGInput.new('sounds/sine/sine_100_1s_mono.flac', resample: 44100)
  }

  describe '#initialize' do
    it 'can load and parse info from a .flac sound' do
      expect(input.frames).to eq(48000)
      expect(input.rate).to eq(48000)
      expect(input.channels).to eq(1)
    end

    it 'can change the number of channels' do
      expect(input_2ch.channels).to eq(2)
    end

    it 'can change the sample rate' do
      expect(input_441.frames).to eq(44100)
      expect(input_441.rate).to eq(44100)
    end
  end

  pending '#read'

  pending '#close'
end
