RSpec.describe(MB::Sound::MultiWriter) do
  let(:null_out_1) { MB::Sound::NullOutput.new(channels: 1, sleep: false) }
  let(:null_out_2) { MB::Sound::NullOutput.new(channels: 2, sleep: false) }
  let(:null_out_5) { MB::Sound::NullOutput.new(channels: 5, sleep: false) }
  let(:null_out_44k) { MB::Sound::NullOutput.new(channels: 1, sample_rate: 44100, sleep: false) }
  let(:null_out_longbuf) { MB::Sound::NullOutput.new(channels: 1, buffer_size: 1600, sleep: false) }

  let(:data5) {
    [
      Numo::DFloat.ones(800),
      Numo::SFloat.zeros(800),
      Numo::SFloat.zeros(800).rand,
      Numo::DFloat.zeros(800).rand(-1, 1),
      Numo::SFloat.ones(800) * 0.1,
    ]
  }
  let(:data4) { data5[0...4] }
  let(:data3) { data5[0...3] }
  let(:data2) { data5[0...2] }
  let(:data1) { data5[0...1] }

  describe '#initialize' do
    it 'can be instantiated with a single 48k output' do
      multi = MB::Sound::MultiWriter.new([null_out_1])
      expect(multi.channels).to eq(1)
      expect(multi.sample_rate).to eq(48000)
      expect(multi.buffer_size).to eq(800)
    end

    it 'returns 44.1k for sample rate if given an output with a 44.1k rate' do
      multi = MB::Sound::MultiWriter.new([null_out_44k])
      expect(multi.sample_rate).to eq(44100)
      expect(multi.buffer_size).to eq(800)
      expect(multi.channels).to eq(1)
    end

    it 'returns the expected buffer size if given an output with a nonstandard buffer size' do
      multi = MB::Sound::MultiWriter.new([null_out_longbuf])
      expect(multi.buffer_size).to eq(1600)
      expect(multi.sample_rate).to eq(48000)
      expect(multi.channels).to eq(1)
    end

    it 'sets the number of channels to the largest output' do
      multi2 = MB::Sound::MultiWriter.new([null_out_1, null_out_2])
      expect(multi2.channels).to eq(2)

      multi5 = MB::Sound::MultiWriter.new([null_out_1, null_out_2, null_out_5])
      expect(multi5.channels).to eq(5)
      expect(multi5.sample_rate).to eq(48000)
      expect(multi5.buffer_size).to eq(800)
    end

    it 'raises an error if sample rates do not match' do
      expect {
        MB::Sound::MultiWriter.new([null_out_1, null_out_44k])
      }.to raise_error(MB::Sound::MultiWriter::SampleRateMismatch)
    end

    it 'raises an error if buffer sizes do not match' do
      expect {
        MB::Sound::MultiWriter.new([null_out_1, null_out_longbuf])
      }.to raise_error(MB::Sound::MultiWriter::BufferSizeMismatch)
    end
  end

  describe '#write' do
    it 'can write audio to a single output' do
      multi = MB::Sound::MultiWriter.new([null_out_1])
      expect(null_out_1).to receive(:write).with(data1).and_call_original
      multi.write(data1)

      multi2 = MB::Sound::MultiWriter.new([null_out_2])
      expect(null_out_2).to receive(:write).with(data2).and_call_original
      multi2.write(data2)

      expect(null_out_1.frames_written).to eq(800)
      expect(null_out_2.frames_written).to eq(800)
    end

    it 'raises an error if given the wrong number of channels' do
      multi1 = MB::Sound::MultiWriter.new([null_out_1])
      expect { multi1.write(data2) }.to raise_error(MB::Sound::MultiWriter::ChannelCountMismatch)

      multi2 = MB::Sound::MultiWriter.new([null_out_2])
      expect { multi2.write(data1) }.to raise_error(MB::Sound::MultiWriter::ChannelCountMismatch)
      expect { multi2.write(data3) }.to raise_error(MB::Sound::MultiWriter::ChannelCountMismatch)

      multi5 = MB::Sound::MultiWriter.new([null_out_1, null_out_2, null_out_5])
      expect { multi5.write(data4) }.to raise_error(MB::Sound::MultiWriter::ChannelCountMismatch)
      expect { multi5.write(data4 + data2) }.to raise_error(MB::Sound::MultiWriter::ChannelCountMismatch)
    end

    it 'can write to a 44.1kHz sample rate output' do
      multi = MB::Sound::MultiWriter.new([null_out_44k])
      expect(null_out_44k.frames_written).to eq(0)
      multi.write([Numo::SFloat.zeros(800)])
      expect(null_out_44k.frames_written).to eq(800)
    end

    it 'can write to a non-standard buffer size output' do
      multi = MB::Sound::MultiWriter.new([null_out_longbuf])
      expect(null_out_longbuf.frames_written).to eq(0)
      multi.write([Numo::SFloat.zeros(1600)])
      expect(null_out_longbuf.frames_written).to eq(1600)
    end

    it 'delivers audio to all outputs even if channel counts differ' do
      multi5 = MB::Sound::MultiWriter.new([null_out_1, null_out_2, null_out_5])
      expect(null_out_1).to receive(:write).with(data1).and_call_original
      expect(null_out_2).to receive(:write).with(data2).and_call_original
      expect(null_out_5).to receive(:write).with(data5).and_call_original

      multi5.write(data5)

      expect(null_out_1.frames_written).to eq(800)
      expect(null_out_2.frames_written).to eq(800)
      expect(null_out_5.frames_written).to eq(800)
    end
  end
end
