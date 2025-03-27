RSpec.describe(MB::Sound::InputBufferWrapper, :aggregate_failures) do
  let(:buffer_size) { 7 }
  let(:length) { 100 }
  let(:c1) { 12000.hz.square.at(1).with_phase(0.0000001).sample(length) }
  let(:c2) { 8000.hz.square.at(-1).with_phase(0.0000001).sample(length) }
  let(:c3) { 6000.hz.square.at(1).with_phase(0.0000001).sample(length) }
  let(:nullinput) { MB::Sound::NullInput.new(channels: 13, buffer_size: buffer_size, rate: 1537, length: length) }
  let(:mono) { MB::Sound::ArrayInput.new(data: [c1], buffer_size: buffer_size) }
  let(:stereo) { MB::Sound::ArrayInput.new(data: [c1, c2], buffer_size: buffer_size) }
  let(:multi) { MB::Sound::ArrayInput.new(data: [c1, c2, c3], buffer_size: buffer_size) }
  let(:complex) { MB::Sound::ArrayInput.new(data: [1i * c1], buffer_size: buffer_size) }
  let(:file) { MB::Sound::FFMPEGInput.new('sounds/synth0.flac') }

  describe '#initialize' do
    it 'can wrap an FFMPEGInput' do
      b = MB::Sound::InputBufferWrapper.new(file)
      expect(b.channels).to eq(2)
      expect(b.rate).to eq(48000)
      expect(b.buffer_size).to eq(file.buffer_size)

      expect(b.closed?).to eq(false)
      file.close
      expect(b.closed?).to eq(true)
    end

    it 'can wrap a NullInput' do
      b = MB::Sound::InputBufferWrapper.new(nullinput)
      expect(b.channels).to eq(13)
      expect(b.rate).to eq(1537)
      expect(b.buffer_size).to eq(buffer_size)
    end

    it 'can wrap an ArrayInput' do
      b = MB::Sound::InputBufferWrapper.new(mono)
      expect(b.channels).to eq(1)
      expect(b.rate).to eq(48000)
      expect(b.buffer_size).to eq(buffer_size)
    end

    it 'accepts a buffer size override' do
      b = MB::Sound::InputBufferWrapper.new(mono, buffer_size: 42)
      expect(b.buffer_size).to eq(42)
    end
  end

  describe '#read' do
    it 'can read from a one-channel input' do
      b = MB::Sound::InputBufferWrapper.new(mono)
      expect(mono).to receive(:read).with(7).twice.and_call_original
      expect(b.read(8)).to eq([Numo::SFloat[1, 1, -1, -1, 1, 1, -1, -1]])
      expect(b.read(3)).to eq([Numo::SFloat[1, 1, -1]])
    end

    it 'can read from a two-channel input' do
      b = MB::Sound::InputBufferWrapper.new(stereo)
      expect(stereo).to receive(:read).with(7).twice.and_call_original
      expect(b.read(8)).to eq([Numo::SFloat[1, 1, -1, -1, 1, 1, -1, -1], Numo::SFloat[-1, -1, -1, 1, 1, 1, -1, -1]])
      expect(b.read(3)).to eq([Numo::SFloat[1, 1, -1], Numo::SFloat[-1, 1, 1]])
    end

    it 'can read from a multi-channel input' do
      b = MB::Sound::InputBufferWrapper.new(multi)
      expect(multi).to receive(:read).with(7).twice.and_call_original
      expect(b.read(8)).to eq([Numo::SFloat[1, 1, -1, -1, 1, 1, -1, -1], Numo::SFloat[-1, -1, -1, 1, 1, 1, -1, -1], Numo::SFloat[1, 1, 1, 1, -1, -1, -1, -1]])
      expect(b.read(3)).to eq([Numo::SFloat[1, 1, -1], Numo::SFloat[-1, 1, 1], Numo::SFloat[1, 1, 1]])
    end

    it 'can read from a file' do
      b = MB::Sound::InputBufferWrapper.new(file)
      expect(file).to receive(:read).with(32768).and_call_original
      expect(b.read(1500).sum.abs.sum).not_to eq(0)
      expect(b.read(1500)[0].length).to eq(1500)
    end

    it 'can return Complex data' do
      b = MB::Sound::InputBufferWrapper.new(complex)
      expect(b.read(42)[0]).to be_a(Numo::SComplex)
    end

    it 'can read less than one buffer' do
      b = MB::Sound::InputBufferWrapper.new(mono)
      expect(mono).to receive(:read).with(7).and_call_original
      expect(b.read(4)).to eq([Numo::SFloat[1, 1, -1, -1]])
    end

    it 'can read exactly one buffer' do
      b = MB::Sound::InputBufferWrapper.new(mono)
      expect(mono).to receive(:read).with(7).and_call_original
      expect(b.read(7)).to eq([Numo::SFloat[1, 1, -1, -1, 1, 1, -1]])
    end

    it 'can read more than one buffer' do
      b = MB::Sound::InputBufferWrapper.new(mono)
      expect(mono).to receive(:read).with(7).twice.and_call_original
      expect(b.read(8)).to eq([Numo::SFloat[1, 1, -1, -1, 1, 1, -1, -1]])
    end

    it 'returns less data when the end of input is reached' do
      b = MB::Sound::InputBufferWrapper.new(file)

      # File has 155642 samples
      d1 = b.read(155639)
      expect(d1.length).to eq(2)
      expect(d1[0].length).to eq(155639)

      d2 = b.read(17)
      expect(d2.length).to eq(2)
      expect(d2[0].length).to eq(3)

      expect(b.read(7)).to eq(nil)
    end

    it 'can handle an input that returns a different length than requested' do
      expect(mono).to receive(:read).with(7).exactly(4).times.and_return([Numo::SFloat[1, 2, 3]], [Numo::SFloat[4]], [Numo::SFloat[5, 6, 7]], [Numo::SFloat[]])
      b = MB::Sound::InputBufferWrapper.new(mono)

      expect(b.read(2)).to eq([Numo::SFloat[1, 2]])
      expect(b.read(5)).to eq([Numo::SFloat[3, 4, 5, 6, 7]])
      expect(b.read(1)).to eq(nil)
    end

    it 'raises a useful error message if count is not an integer' do
      b = MB::Sound::InputBufferWrapper.new(nullinput)
      expect { b.read(nil) }.to raise_error(ArgumentError, /Count must be an Integer.*nil/)
      expect { b.read(3.0) }.to raise_error(ArgumentError, /Count must be an Integer.*3.0/)
    end
  end
end
