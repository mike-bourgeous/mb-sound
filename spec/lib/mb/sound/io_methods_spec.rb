RSpec.describe(MB::Sound::IOMethods) do
  describe '#output' do
    before(:each) {
      ENV['OUTPUT_TYPE'] = ':null'
    }

    after(:each) {
      ENV.delete('OUTPUT_TYPE')
    }

    it 'returns a working null output when ENV["OUTPUT_TYPE"] is :null' do
      o = MB::Sound.output
      expect(o).to be_a(MB::Sound::NullOutput)
      expect { o.write([Numo::SFloat.zeros(800)] * 2) }.not_to raise_error
      o.close
    end

    it 'returns a working PlotOutput when plot is set' do
      begin
        ENV['OUTPUT_TYPE'] = ':null'
        o = MB::Sound.output(plot: { plot: MB::M::Plot.terminal.tap { |p| p.print = false } })
        expect(o).to be_a(MB::Sound::PlotOutput)
        expect(o.output).to be_a(MB::Sound::NullOutput)

        o.sleep = false
        expect { o.write([Numo::SFloat.zeros(800)] * 2) }.not_to raise_error

      ensure
        o&.close
      end
    end
  end

  describe '#read' do
    it 'can read a sound file' do
      a = MB::Sound.read('sounds/sine/sine_100_1s_mono.flac')
      expect(a.length).to eq(1)
      expect(a[0].length).to eq(48000)
      expect(a[0].max).to be_between(0.4, 1.0)
    end

    it 'resamples to 48k' do
      a = MB::Sound.read('sounds/sine/sine_100_44k.flac')
      expect(a.length).to eq(1)
      expect(a[0].length).to eq(48000)
      expect(a[0].max).to be_between(0.4, 1.0)
    end

    it 'can read without resampling' do
      a = MB::Sound.read('sounds/sine/sine_100_44k.flac', rate: nil)
      expect(a.length).to eq(1)
      expect(a[0].length).to eq(44100)
      expect(a[0].max).to be_between(0.4, 1.0)
    end

    it 'can read part of a sound file' do
      a = MB::Sound.read('sounds/sine/sine_100_1s_mono.flac', max_frames: 500)
      expect(a.length).to eq(1)
      expect(a[0].length).to eq(500)
    end
  end

  describe '#write' do
    before(:each) do
      FileUtils.mkdir_p('tmp')
      File.unlink('tmp/sound_write_test.flac') rescue nil
      File.unlink('tmp/sound_write_exists.flac') rescue nil
    end

    context 'when writing to a file that does not yet exist' do
      let(:name) { 'tmp/sound_write_test.flac' }
      let(:data) { Numo::SFloat[0, 0.5, -0.5, 0] }

      it 'can write an array of NArrays to a sound file' do
        MB::Sound.write(name, [data], rate: 48000)
        info = MB::Sound::FFMPEGInput.parse_info(name)
        expect(info[:streams][0][:duration_ts]).to eq(4)
      end

      it 'can write a raw NArray to a sound file' do
        MB::Sound.write(name, data, rate: 48000)
        info = MB::Sound::FFMPEGInput.parse_info(name)
        expect(info[:streams][0][:duration_ts]).to eq(4)
      end

      it 'can write a Tone to a sound file' do
        MB::Sound.write(name, 100.hz.for(1), rate: 48000)
        info = MB::Sound::FFMPEGInput.parse_info(name)
        expect(info[:streams][0][:duration_ts]).to eq(48000)
        expect(info[:streams][0][:channels]).to eq(1)
      end

      it 'can write multiple tones to a sound file' do
        MB::Sound.write(name, [100.hz.for(1), 200.hz.for(1)], rate: 48000)
        info = MB::Sound::FFMPEGInput.parse_info(name)
        expect(info[:streams][0][:duration_ts]).to eq(48000)
        expect(info[:streams][0][:channels]).to eq(2)
      end
    end

    context 'when overwrite is false (by default)' do
      it 'raises an error if the sound already exists' do
        name = 'tmp/sound_write_exists.flac'
        FileUtils.touch(name)
        expect {
          MB::Sound.write(name, [Numo::SFloat[0, 0.1, -0.2, 0.3]], rate: 48000)
        }.to raise_error(MB::Sound::FileExistsError)
      end
    end

    context 'when overwrite is true' do
      it 'overwrites an existing file' do
        name = 'tmp/sound_write_exists.flac'

        FileUtils.touch(name)
        expect(File.size(name)).to eq(0)

        MB::Sound.write(name, [Numo::SFloat[0, 0.1, -0.2, 0.3]], rate: 48000, overwrite: true)
        expect(File.size(name)).to be > 0
      end
    end
  end

  describe '#file_input' do
    it 'can open a mono sound for reading' do
      begin
        input = MB::Sound.file_input('sounds/sine/sine_100_1s_mono.flac')
        expect(input.rate).to eq(48000)
        expect(input.channels).to eq(1)
        expect(input).to respond_to(:read)
      ensure
        input&.close
      end
    end

    it 'can read without resampling' do
      begin
        input = MB::Sound.file_input('sounds/sine/sine_100_44k.flac', resample: nil)
        expect(input.frames).to eq(44100)
        expect(input.channels).to eq(1)
        expect(input.read(1).length).to eq(1)
      ensure
        input&.close
      end
    end

    it 'can resample when reading' do
      begin
        input = MB::Sound.file_input('sounds/sine/sine_100_44k.flac', resample: 75000)
        expect(input.rate).to eq(75000)
        a = input.read(75000)
        expect(a.length).to eq(1)
        expect(a[0].length).to eq(75000)
        expect(a[0].max).to be_between(0.4, 1.0)
      ensure
        input&.close
      end
    end
  end

  describe '#file_output' do
    before(:each) do
      FileUtils.mkdir_p('tmp')
      File.unlink('tmp/file_output_test.flac') rescue nil
      File.unlink('tmp/file_output_exists.flac') rescue nil
    end

    it 'can generate an audio file' do
      name = 'tmp/file_output_test.flac'

      begin
        output = MB::Sound.file_output(name, rate: 32000, channels: 3)
        output.write([Numo::SFloat.zeros(127)] * 3)
      ensure
        output&.close
      end

      expect(File.readable?(name)).to eq(true)

      info = MB::Sound::FFMPEGInput.parse_info(name)
      expect(info[:streams][0][:duration_ts]).to eq(127)
      expect(info[:streams][0][:channels]).to eq(3)
      expect(info[:streams][0][:sample_rate]).to eq(32000)

      begin
        input = MB::Sound.file_input(name, resample: nil)
        expect(input.rate).to eq(32000)
        data = input.read(10000)
        expect(data.length).to eq(3)
        expect(data[0].length).to eq(127)
      ensure
        input&.close
      end
    end

    context 'when overwrite is false (by default)' do
      it 'raises an error if the sound already exists' do
        name = 'tmp/file_output_exists.flac'
        FileUtils.touch(name)
        expect {
          MB::Sound.file_output(name, channels: 2)
        }.to raise_error(MB::Sound::FileExistsError)
      end
    end

    context 'when overwrite is true' do
      it 'overwrites an existing file' do
        name = 'tmp/file_output_exists.flac'

        FileUtils.touch(name)
        expect(File.size(name)).to eq(0)

        output = MB::Sound.file_output(name, rate: 48000, channels: 1, overwrite: true)
        output.close
        expect(File.size(name)).to be > 0
      end
    end
  end
end
