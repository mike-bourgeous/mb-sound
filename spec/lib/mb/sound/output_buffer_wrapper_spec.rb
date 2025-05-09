RSpec.describe(MB::Sound::OutputBufferWrapper, :aggregate_failures) do
  let(:buffer_size) { 7 }
  let(:length) { 100 }
  let(:c1) { 12000.hz.square.at(1).with_phase(0.0000001).sample(length) }
  let(:c2) { 8000.hz.square.at(-1).with_phase(0.0000001).sample(length) }
  let(:c3) { 6000.hz.square.at(1).with_phase(0.0000001).sample(length) }
  let(:nulloutput) { MB::Sound::NullOutput.new(channels: 13, buffer_size: buffer_size, sample_rate: 1537) }
  let(:mono) { MB::Sound::NullOutput.new(channels: 1, buffer_size: buffer_size) }
  let(:stereo) { MB::Sound::NullOutput.new(channels: 2, buffer_size: buffer_size) }
  let(:multi) { MB::Sound::NullOutput.new(channels: 3, buffer_size: buffer_size) }

  let(:exname) { |ex| ex.metadata[:full_description].inspect.downcase.gsub(/[^a-z0-9_-]+/, '_') }
  let(:filename) { "tmp/output_buffer_wrapper_spec_#{exname}.flac" }
  let(:file) { MB::Sound::FFMPEGOutput.new(filename, sample_rate: 48000, channels: 2, buffer_size: buffer_size) }

  let(:mono_filename) { "tmp/output_buffer_wrapper_spec_mono_#{exname}.flac" }
  let(:mono_file) { MB::Sound::FFMPEGOutput.new(mono_filename, sample_rate: 48000, channels: 1, buffer_size: buffer_size) }

  before do
    File.unlink(filename) if File.exist?(filename)
  end

  after do
    File.unlink(filename) if File.exist?(filename)
  end

  describe '#initialize' do
    it 'can wrap an FFMPEGOutput' do
      b = MB::Sound::OutputBufferWrapper.new(file)
      expect(b.channels).to eq(2)
      expect(b.sample_rate).to eq(48000)
      expect(b.buffer_size).to eq(file.buffer_size)

      expect(b.closed?).to eq(false)
      b.close
      expect(b.closed?).to eq(true)
    end

    it 'can wrap a NullOutput' do
      b = MB::Sound::OutputBufferWrapper.new(nulloutput)
      expect(b.channels).to eq(13)
      expect(b.sample_rate).to eq(1537)
      expect(b.buffer_size).to eq(buffer_size)
    end

    # TODO: Create an ArrayOutput that accumulates samples in an array?

    it 'accepts a buffer size override' do
      b = MB::Sound::OutputBufferWrapper.new(mono, buffer_size: 42)
      expect(b.buffer_size).to eq(42)
    end
  end

  describe '#write' do
    it 'can write to a one-channel output' do
      b = MB::Sound::OutputBufferWrapper.new(mono)
      expect(mono).to receive(:write).with([Numo::SFloat[1, -1, 1, -1, 1, -1, 1]]).and_call_original
      b.write([Numo::SFloat[1, -1, 1, -1, 1, -1, 1]])
    end

    it 'can write to a two-channel output' do
      b = MB::Sound::OutputBufferWrapper.new(stereo)
      expect(stereo).to receive(:write).with([Numo::SFloat[1, -1, 1, -1, 1, -1, 1]] * 2).and_call_original
      b.write([Numo::SFloat[1, -1, 1, -1, 1, -1, 1]] * 2)
    end

    it 'can write to a multi-channel output' do
      b = MB::Sound::OutputBufferWrapper.new(multi)
      expect(multi).to receive(:write).with([Numo::SFloat[1, -1, 1, -1, 1, -1, 1]] * 3).and_call_original
      b.write([Numo::SFloat[1, -1, 1, -1, 1, -1, 1]] * 3)
    end

    it 'can write to a file' do
      b = MB::Sound::OutputBufferWrapper.new(file)
      expect(file).to receive(:write).with([Numo::SFloat[1,2,3,4,5,6,7]] * 2).and_call_original
      expect(file).to receive(:write).with([Numo::SFloat[8]] * 2).and_call_original
      b.write([Numo::SFloat[1,2,3,4,5,6,7,8]] * 2)
      b.close

      # FLAC will have clipped the values to 1
      expect(MB::Sound.read(filename)[0].round).to eq(Numo::SFloat[1,1,1,1,1,1,1,1])
    end

    it 'can write less than one buffer' do
      b = MB::Sound::OutputBufferWrapper.new(mono)
      expect(mono).not_to receive(:write)
      b.write([Numo::SFloat[1,2,3,4,5,6]])
    end

    it 'can write less than one buffer until one buffer is filled' do
      b = MB::Sound::OutputBufferWrapper.new(mono)
      expect(mono).to receive(:write).with([Numo::SFloat[1,2,3,4,5,6,7]]).and_call_original
      b.write([Numo::SFloat[1,2,3]])
      b.write([Numo::SFloat[4,5,6,7]])
    end

    it 'can write exactly one buffer' do
      b = MB::Sound::OutputBufferWrapper.new(mono)
      expect(mono).to receive(:write).with([Numo::SFloat[1,2,3,4,5,6,7]]).and_call_original
      b.write([Numo::SFloat[1,2,3,4,5,6,7]])
    end

    it 'can write more than one buffer' do
      b = MB::Sound::OutputBufferWrapper.new(mono)
      expect(mono).to receive(:write).with([Numo::SFloat[1,2,3,4,5,6,7]]).and_call_original
      b.write([Numo::SFloat[1,2,3,4,5,6,7,8]])
    end
  end

  describe '#close' do
    let(:buffer_size) { 2345 }

    it 'flushes unwritten data before closing' do
      b = MB::Sound::OutputBufferWrapper.new(mono_file)
      b.write([Numo::SFloat[1, 2, 3]])
      b.write([Numo::SFloat[4, 5]])
      b.close

      info = MB::Sound::FFMPEGInput.parse_info(mono_filename)[:streams][0]
      expect(info[:sample_rate]).to eq(48000)
      expect(info[:duration_ts]).to eq(5)
    end

    it 'can be forced to pad flushed data' do
      b = MB::Sound::OutputBufferWrapper.new(mono_file, always_pad: true)
      b.write([Numo::SFloat[1, 2, 3]])
      b.write([Numo::SFloat[4, 5]])
      b.close

      info = MB::Sound::FFMPEGInput.parse_info(mono_filename)[:streams][0]
      expect(info[:sample_rate]).to eq(48000)
      expect(info[:duration_ts]).to eq(2345)
    end
  end
end
