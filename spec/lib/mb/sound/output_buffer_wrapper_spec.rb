RSpec.describe(MB::Sound::OutputBufferWrapper) do
  let(:buffer_size) { 7 }
  let(:length) { 100 }
  let(:c1) { 12000.hz.square.at(1).with_phase(0.0000001).sample(length) }
  let(:c2) { 8000.hz.square.at(-1).with_phase(0.0000001).sample(length) }
  let(:c3) { 6000.hz.square.at(1).with_phase(0.0000001).sample(length) }
  let(:nulloutput) { MB::Sound::NullOutput.new(channels: 13, buffer_size: buffer_size, rate: 1537) }
  let(:mono) { MB::Sound::NullOutput.new(channels: 1, buffer_size: buffer_size) }
  let(:stereo) { MB::Sound::NullOutput.new(channels: 2, buffer_size: buffer_size) }
  let(:multi) { MB::Sound::NullOutput.new(channels: 3, buffer_size: buffer_size) }
  let(:exname) { |ex| ex.metadata[:full_description].inspect.downcase.gsub(/[^a-z0-9_-]+/, '_') }
  let(:filename) { "tmp/output_buffer_wrapper_spec_#{exname}.flac" }
  let(:file) { MB::Sound::FFMPEGOutput.new(filename, rate: 48000, channels: 2, buffer_size: buffer_size) }

  describe '#initialize' do
    it 'can wrap an FFMPEGOutput' do
      b = MB::Sound::OutputBufferWrapper.new(file)
      expect(b.channels).to eq(2)
      expect(b.rate).to eq(48000)
      expect(b.buffer_size).to eq(file.buffer_size)

      expect(b.closed?).to eq(false)
      b.close
      expect(b.closed?).to eq(true)
    end

    it 'can wrap a NullOutput' do
      b = MB::Sound::OutputBufferWrapper.new(nulloutput)
      expect(b.channels).to eq(13)
      expect(b.rate).to eq(1537)
      expect(b.buffer_size).to eq(buffer_size)
    end

    # TODO: Create an ArrayOutput that accumulates samples in an array?
  end

  describe '#write' do
    it 'can write to a one-channel output' do
      b = MB::Sound::OutputBufferWrapper.new(mono)
      expect(mono).to receive(:write).with(7).twice.and_call_original
      expect(b.write(8)).to eq([Numo::SFloat[1, 1, -1, -1, 1, 1, -1, -1]])
      expect(b.write(3)).to eq([Numo::SFloat[1, 1, -1]])
    end

    it 'can write to a two-channel output' do
      b = MB::Sound::OutputBufferWrapper.new(stereo)
      expect(stereo).to receive(:write).with(7).twice.and_call_original
      expect(b.write(8)).to eq([Numo::SFloat[1, 1, -1, -1, 1, 1, -1, -1], Numo::SFloat[-1, -1, -1, 1, 1, 1, -1, -1]])
      expect(b.write(3)).to eq([Numo::SFloat[1, 1, -1], Numo::SFloat[-1, 1, 1]])
    end

    it 'can write to a multi-channel output' do
      b = MB::Sound::OutputBufferWrapper.new(multi)
      expect(multi).to receive(:write).with(7).twice.and_call_original
      expect(b.write(8)).to eq([Numo::SFloat[1, 1, -1, -1, 1, 1, -1, -1], Numo::SFloat[-1, -1, -1, 1, 1, 1, -1, -1], Numo::SFloat[1, 1, 1, 1, -1, -1, -1, -1]])
      expect(b.write(3)).to eq([Numo::SFloat[1, 1, -1], Numo::SFloat[-1, 1, 1], Numo::SFloat[1, 1, 1]])
    end

    it 'can write to a file' do
      b = MB::Sound::OutputBufferWrapper.new(file)
      expect(file).to receive(:write).with(32768).and_call_original
      expect(b.write(1500).sum.abs.sum).not_to eq(0)
      expect(b.write(1500)[0].length).to eq(1500)
    end

    it 'can write less than one buffer' do
      b = MB::Sound::OutputBufferWrapper.new(mono)
      expect(mono).to receive(:write).with(7).and_call_original
      expect(b.write(4)).to eq([Numo::SFloat[1, 1, -1, -1]])
    end

    it 'can write exactly one buffer' do
      b = MB::Sound::OutputBufferWrapper.new(mono)
      expect(mono).to receive(:write).with(7).and_call_original
      expect(b.write(7)).to eq([Numo::SFloat[1, 1, -1, -1, 1, 1, -1]])
    end

    it 'can write more than one buffer' do
      b = MB::Sound::OutputBufferWrapper.new(mono)
      expect(mono).to receive(:write).with(7).twice.and_call_original
      expect(b.write(8)).to eq([Numo::SFloat[1, 1, -1, -1, 1, 1, -1, -1]])
    end
  end

  describe '#close' do
    let(:buffer_size) { 2345 }

    it 'flushes unwritten data before closing' do
      b = MB::Sound::OutputBufferWrapper.new(file)
      b.write(Numo::SFloat[1, 2, 3])
      b.write(Numo::SFloat[4, 5])
      b.close
      
      info = MB::Sound::FFMPEGInput.parse_info(filename)[:streams][0]
      expect(info[:sample_rate]).to eq(48000)
      expect(info[:duration_ts]).to eq(1337)
    end
  end
end
