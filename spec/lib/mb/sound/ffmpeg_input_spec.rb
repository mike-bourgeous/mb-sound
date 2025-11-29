require 'benchmark'

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

    it 'raises an error if an invalid format override is given' do
      expect {
        MB::Sound::FFMPEGInput.parse_info('spec/test_data/two_audio_streams.mkv', format: 'wav')
      }.to raise_error(/ffprobe/)
    end
  end

  let(:input) {
    MB::Sound::FFMPEGInput.new('sounds/sine/sine_100_1s_mono.flac')
  }

  let(:input_2ch) {
    MB::Sound::FFMPEGInput.new('sounds/sine/sine_100_1s_mono.flac', channels: 2)
  }

  let(:input_6ch) {
    MB::Sound::FFMPEGInput.new('sounds/sine/sine_100_1s_mono.flac', channels: 6)
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

  let(:mp3_48k) {
    MB::Sound::FFMPEGInput.new('spec/test_data/48k_300hz_1s.mp3')
  }

  let(:mp3_44k) {
    MB::Sound::FFMPEGInput.new('spec/test_data/44k_300hz_1s.mp3')
  }

  describe '#initialize' do
    it 'can load and parse info from a .flac file' do
      expect(input.frames).to eq(48000)
      expect(input.sample_rate).to eq(48000)
      expect(input.channels).to eq(1)
      expect(input.info[:tags][:title]).to eq('Sine 100Hz 1s mono')

      input.read(100000) # allow ffmpeg to empty its buffer
      expect(input.close.success?).to eq(true)
    end

    it 'can load and parse info from a .mp3 file' do
      # For some reason ffprobe returns a longer duration than can actually be
      # read from the file.
      expect(mp3_48k.frames).to be_between(45000, 51000)
      expect(mp3_44k.frames).to be_between(41000, 49000)

      data_48k = mp3_48k.read(1000000).first
      data_44k = mp3_44k.read(1000000).first
      expect(data_48k.length).to eq(48000)
      expect(data_44k.length).to eq(44100)

      expect(MB::Sound.real_fft(data_48k).abs.max_index).to eq(300)
      expect(MB::Sound.real_fft(data_44k).abs.max_index).to eq(300)

      expect(mp3_48k.close.success?).to eq(true)
      expect(mp3_44k.close.success?).to eq(true)
    end

    it 'can change the number of channels' do
      expect(input_2ch.channels).to eq(2)
      expect(input_2ch.read(100000).size).to eq(2)
      expect(input_2ch.close.success?).to eq(true)
    end

    it 'can change the sample rate' do
      expect(input_441.frames).to eq(44100)
      expect(input_441.sample_rate).to eq(44100)
      expect(input_441.read(100000)[0].size).to eq(44100)
      expect(input_441.close.success?).to eq(true)
    end

    it 'can load a second audio stream' do
      expect(input_multi_0.sample_rate).to eq(48000)
      expect(input_multi_0.channels).to eq(1)
      expect(input_multi_1.sample_rate).to eq(44100)
      expect(input_multi_1.channels).to eq(2)

      expect(input_multi_0.read(100000)[0].size).to eq(48000)
      expect(input_multi_1.read(100000)[0].size).to eq(44100)

      expect(input_multi_0.close.success?).to eq(true)
      expect(input_multi_1.close.success?).to eq(true)
    end

    context 'with format override' do
      it 'raises an error for an invalid format' do
        expect {
          MB::Sound::FFMPEGInput.new('sounds/sine/sine_100_1s_mono.flac', format: 'avi')
        }.to raise_error(/ffprobe/)
      end

      it 'does not raise an error for a matching format' do
        a = MB::Sound::FFMPEGInput.new('sounds/sine/sine_100_1s_mono.flac', format: 'flac')
        d = a.read(a.frames)
        expect(d[0].max).to be_between(0.4, 1.0)
        expect(a.close.success?).to eq(true)
      end
    end
  end

  describe '#read' do
    it 'can read all data at once' do
      d1 = input.read(100000)
      expect(d1.length).to eq(input.channels)
      expect(d1[0].length).to eq(input.frames)

      expect(input.close.success?).to eq(true)
    end

    it 'can read data in chunks' do
      d1 = input.read(5000)[0]
      d2 = input.read(input.frames - 5000)[0]
      expect(d1.length).to eq(5000)
      expect(d2.length).to eq(43000)

      # Compare to the stereo version (compensating for pan law)
      dref = input_2ch.read(input_2ch.frames)[0]
      d3 = d1.concatenate(d2)
      scale = d3.max / dref.max
      expect(d1.concatenate(d2).map { |v| v.round(3) }).to eq(dref.map { |v| (v * scale).round(3) })

      expect(input.close.success?).to eq(true)
    end

    it 'reads data correctly' do
      d = input.read(input.frames)[0]

      # Check for statistical characteristics of a sine wave
      expect(d.sum.abs).to be < 0.01
      expect(d.median).to be < 0.1
      expect(d.max).to be_between(0.4, 1.0).inclusive
      expect(d.min).to be_between(-1.0, -0.4).inclusive

      expect(input.close.success?).to eq(true)
    end

    it 'reads the correct input stream' do
      d1 = input_multi_0.read(48000)
      d2 = input_multi_1.read(48000)

      expect(d1.length).to eq(1)
      expect(d2.length).to eq(2)
      expect(d1[0].length).to eq(48000)
      expect(d2[0].length).to eq(44100)

      expect(input_multi_0.close.success?).to eq(true)
      expect(input_multi_1.close.success?).to eq(true)
    end
  end

  describe '#frames_read' do
    it 'returns the expected number of frames read for 2 channels' do
      input_2ch.read(1234)
      expect(input_2ch.frames_read).to eq(1234)
      input_2ch.read(5)
      expect(input_2ch.frames_read).to eq(1239)
    end

    it 'returns the expected number of frames read for 6 channels' do
      input_6ch.read(1234)
      expect(input_6ch.frames_read).to eq(1234)
      input_6ch.read(5)
      expect(input_6ch.frames_read).to eq(1239)
    end
  end

  describe '#close' do
    it 'can close a file before finishing reading' do
      result = nil
      delay = Benchmark.realtime do
        expect { result = input.close }.not_to raise_exception
      end

      expect(delay).to be < 3
      expect(result).to be_a(Process::Status)

      expect { input.read(1) }.to raise_exception(IOError)
    end
  end

  context 'progress and time functions' do
    let(:filename) { |ex| "tmp/file_io_time_funcs_#{ex.description.downcase.gsub(/[^a-z0-9]+/, '_')}.flac" }
    let(:sample_rate) { 48000 }
    let(:input) { |ex|
      FileUtils.mkdir_p('tmp')
      File.unlink(filename) rescue nil
      MB::Sound.write(filename, [Numo::SFloat.zeros(sample_rate * 2)], sample_rate: sample_rate)
      MB::Sound::FFMPEGInput.new(filename)
    }

    describe '#progress' do
      it 'returns the percentage of playback progress' do
        expect(input.progress).to eq(0)

        input.read(48000)
        expect(input.progress).to eq(50)
      end

      context 'with sample rate at 32k' do
        let(:sample_rate) { 32000 }

        it 'works with different sample rates' do
        expect(input.progress).to eq(0)

        input.read(32000)
        expect(input.progress).to eq(50)
        end
      end
    end

    describe '#elapsed' do
      it 'returns the time played in seconds' do
        expect(input.elapsed).to eq(0)
        input.read(24000)
        expect(input.elapsed).to eq(0.5)
      end

      context 'with sample rate at 32k' do
        let(:sample_rate) { 32000 }

        it 'supports different sample rates' do
          expect(input.elapsed).to eq(0)
          input.read(16000)
          expect(input.elapsed).to eq(0.5)
        end
      end
    end

    describe '#duration' do
      it 'returns the total length of data in seconds' do
        expect(input.duration).to eq(2)
      end

      context 'with sample rate at 32k' do
        let(:sample_rate) { 32000 }

        it 'supports different sample rates' do
          expect(input.duration).to eq(2)
          expect(input.sample_rate).to eq(sample_rate)
        end
      end
    end
  end
end
