RSpec.describe MB::Sound::FFMPEGInput do
  describe '.parse_info' do
    let(:info) {
      MB::Sound::FFMPEGInput.parse_info('sounds/sine/sine_100_1s_mono.flac')
    }

    let(:info_multi) {
      MB::Sound::FFMPEGInput.parse_info('spec/test_data/two_audio_streams.mkv')
    }

    it 'can read stream info from a .flac sound file' do
      expect(info).to be_a(Hash)
      expect(info[:streams][0][:duration_ts]).to eq(48000)
      expect(info[:streams][0][:duration].round(4)).to eq(1)
      expect(info[:streams][0][:channels]).to eq(1)
    end

    it 'can read format info from a .flac sound file' do
      expect(info[:format][:tags][:title]).to eq('Sine 100Hz 1s mono')
    end

    it 'can read info about multiple audio streams' do
      expect(info[:streams].length).to eq(1)
      expect(info_multi[:streams].length).to eq(2)
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

  let(:input_multi_0) {
    MB::Sound::FFMPEGInput.new('spec/test_data/two_audio_streams.mkv', stream_idx: 0)
  }

  let(:input_multi_1) {
    MB::Sound::FFMPEGInput.new('spec/test_data/two_audio_streams.mkv', stream_idx: 1)
  }

  describe '#initialize' do
    it 'can load and parse info from a .flac sound' do
      expect(input.frames).to eq(48000)
      expect(input.rate).to eq(48000)
      expect(input.channels).to eq(1)
      expect(input.info[:tags][:title]).to eq('Sine 100Hz 1s mono')
    end

    it 'can change the number of channels' do
      expect(input_2ch.channels).to eq(2)
    end

    it 'can change the sample rate' do
      expect(input_441.frames).to eq(44100)
      expect(input_441.rate).to eq(44100)
    end

    it 'can load a second audio stream' do
      expect(input_multi_0.rate).to eq(48000)
      expect(input_multi_0.channels).to eq(1)
      expect(input_multi_1.rate).to eq(44100)
      expect(input_multi_1.channels).to eq(2)
    end
  end

  pending '#read'

  pending '#close'
end
