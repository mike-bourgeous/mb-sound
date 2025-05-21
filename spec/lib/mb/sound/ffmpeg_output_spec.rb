require 'fileutils'

RSpec.describe MB::Sound::FFMPEGOutput do
  let(:test_data) {
    [
      Numo::SFloat[0, 0.5, -0.5, 0],
      Numo::SFloat[0, -0.75, 0.25, 0],
      Numo::SFloat[0, -0.25, 0.75, 0],
    ]
  }

  before(:each) do
    FileUtils.mkdir_p('./tmp')
    File.unlink('./tmp/test_out.flac') rescue nil
    File.unlink('./tmp/test_out.wav') rescue nil
    File.unlink('./tmp/test_out.ogg') rescue nil
  end

  describe '#write' do
    ['flac', 'wav'].each do |format|
      context "when writing .#{format}" do
        it 'can write a file that can be read by FFMPEGInput' do
          name = "tmp/test_out.#{format}"
          output = MB::Sound::FFMPEGOutput.new(name, sample_rate: 44100, channels: 3)
          expect(output.filename).to include(name)
          output.write(test_data)
          expect(output.close.success?).to eq(true)

          expect(File.readable?(name)).to eq(true)
          expect(File.size(name)).to be > 0

          input = MB::Sound::FFMPEGInput.new(name)
          expect(input.sample_rate).to eq(44100)
          expect(input.channels).to eq(3)
          expect(input.frames).to eq(4)

          data = input.read(input.frames).map { |c|
            c.map { |v| v.round(3) }
          }

          expect(input.close.success?).to eq(true)

          expect(data).to eq(test_data)
        end
      end
    end

    it 'can write a bare Numo::NArray if channel count is 1' do
      output = MB::Sound::FFMPEGOutput.new('tmp/test_out.flac', sample_rate: 48000, channels: 1)
      expect { output.write(Numo::SFloat.zeros(100)) }.not_to raise_error
      expect(output.close.success?).to eq(true)
    end

    it 'raises an error if the wrong number of channels are given' do
      name = "tmp/test_out.flac"
      output = MB::Sound::FFMPEGOutput.new(name, sample_rate: 44100, channels: 2)
      expect {
        output.write(test_data)
      }.to raise_error(ArgumentError, /channel/)
    ensure
      output&.close
    end

    it 'raises an error if given a bare Numo::NArray for 2 channels' do
      name = "tmp/test_out.flac"
      output = MB::Sound::FFMPEGOutput.new(name, sample_rate: 44100, channels: 2)
      expect {
        output.write(Numo::SFloat.zeros(100))
      }.to raise_error(ArgumentError, /channel/)
    ensure
      output&.close
    end
  end

  describe '#initialize' do
    it 'can override the default format for an extension' do
      name = 'tmp/test_out.wav'
      output = MB::Sound::FFMPEGOutput.new(name, sample_rate: 48000, channels: 1, format: 'flac')
      output.write(test_data[0..0])
      expect(output.close.success?).to eq(true)

      info = MB::Sound::FFMPEGInput.parse_info(name)
      expect(info[:format][:format_name]).to match(/flac/)
    end

    it 'can specify a bitrate' do
      name = 'tmp/test_out.ogg'
      data = [Numo::SFloat.zeros(48000).rand]
      output = MB::Sound::FFMPEGOutput.new(name, sample_rate: 48000, channels: 1, bitrate: '32k')
      output.write(data)
      expect(output.close.success?).to eq(true)

      size32 = File.size(name)

      output = MB::Sound::FFMPEGOutput.new(name, sample_rate: 48000, channels: 1, bitrate: '128k')
      output.write(data)
      expect(output.close.success?).to eq(true)

      size128 = File.size(name)

      expect(size128).to be > size32
    end

    it 'defaults .wav files to 32-bit float' do
      name = 'tmp/test_out.wav'
      output = MB::Sound::FFMPEGOutput.new(name, sample_rate: 48000, channels: 1)
      output.write(Numo::SFloat.zeros(48000))
      expect(output.close.success?).to eq(true)

      info = MB::Sound::FFMPEGInput.parse_info(name)
      expect(info[:streams][0][:bits_per_sample]).to eq(32)
      expect(info[:streams][0][:codec_name]).to eq('pcm_f32le')
    end

    it 'accepts a different codec for .wav files' do
      name = 'tmp/test_out.wav'
      output = MB::Sound::FFMPEGOutput.new(name, sample_rate: 48000, channels: 1, codec: 'pcm_s16le')
      output.write(Numo::SFloat.zeros(48000))
      expect(output.close.success?).to eq(true)

      info = MB::Sound::FFMPEGInput.parse_info(name)
      expect(info[:streams][0][:bits_per_sample]).to eq(16)
      expect(info[:streams][0][:codec_name]).to eq('pcm_s16le')
    end
  end
end
