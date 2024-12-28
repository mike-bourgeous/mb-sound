RSpec.describe(MB::Sound::CircularBuffer, :aggregate_failures) do
  let(:cbuf) { MB::Sound::CircularBuffer.new(buffer_size: 7) }

  describe '::Reader' do
    describe '#read' do
      it 'can adapt to changes in data type' do
        r1 = cbuf.reader
        r2 = cbuf.reader(1)
        cbuf.write(Numo::SFloat[1,2,3,4])
        expect(r1.read(2)).to be_a(Numo::SFloat).and eq(Numo::SFloat[1,2])
        cbuf.write(Numo::SComplex[-1i])

        expect(r2.read(2)).to be_a(Numo::SComplex).and eq(Numo::SComplex[0, 1])
        expect(r1.read(3)).to be_a(Numo::SComplex).and eq(Numo::SComplex[3, 4, -1i])
      end

      it 'raises an error if trying to read more data than is available' do
        r1 = cbuf.reader
        cbuf.write(Numo::SFloat[1,2])
        r2 = cbuf.reader
        expect { r2.read(1) }.to raise_error(MB::Sound::CircularBuffer::BufferUnderflow)
        expect { r1.read(3) }.to raise_error(MB::Sound::CircularBuffer::BufferUnderflow)
        expect(r1.read(1)).to eq(Numo::SFloat[1])
      end

      it 'returns an empty NArray if asked for zero samples' do
        r1 = cbuf.reader
        expect(r1.read(0)).to be_a(Numo::SFloat).and(eq(Numo::SFloat[]))

        cbuf.write(Numo::SComplex[1])
        expect(r1.read(0)).to be_a(Numo::SComplex).and(eq(Numo::SComplex[]))
      end
    end

    describe '#empty?' do
      it 'returns false if there are samples to read' do
        r1 = cbuf.reader
        cbuf.write(Numo::SFloat[1, 2])
        r2 = cbuf.reader
        cbuf.write(Numo::SFloat[3])
        r3 = cbuf.reader(1)

        expect(r1.empty?).to eq(false)
        expect(r2.empty?).to eq(false)
        expect(r3.empty?).to eq(false)
      end

      it 'returns true if there are no samples to read' do
        r1 = cbuf.reader
        expect(r1.empty?).to eq(true)

        cbuf.write(Numo::SFloat[1, 2])
        r2 = cbuf.reader
        expect(r2.empty?).to eq(true)
      end
    end

    describe '#length' do
      it 'starts at zero if there is no delay' do
        r1 = cbuf.reader
        expect(r1.length).to eq(0)

        cbuf.write(Numo::SFloat[1])
        r2 = cbuf.reader
        expect(r2.length).to eq(0)
      end

      it 'increases when the buffer is written' do
        r1 = cbuf.reader
        r2 = cbuf.reader(3)
        expect {
          cbuf.write(Numo::SFloat[-1, -2])
        }.to change { r1.length }.by(2).and(change { r2.length }.by(2))
      end

      it 'starts at the delay if a delay is given' do
        expect(cbuf.reader(4).length).to eq(4)
      end
    end
  end

  it 'maintains length and available values while reading and writing data' do
    expect(cbuf.buffer_size).to eq(7)

    expect(cbuf.write(Numo::SFloat[1, 2, 3])).to eq(3)
    expect(cbuf.write(Numo::SFloat[4, 5])).to eq(5)
    expect(cbuf.length).to eq(5)
    expect(cbuf.available).to eq(2)

    expect(cbuf.read(4)).to eq(Numo::SFloat[1,2,3,4])
    expect(cbuf.length).to eq(1)
    expect(cbuf.available).to eq(6)

    expect(cbuf.write(Numo::SFloat[-1, -2, -3, -4, -5, -6])).to eq(7)
    expect(cbuf.length).to eq(7)
    expect(cbuf.available).to eq(0)

    expect(cbuf.read(5)).to eq(Numo::SFloat[5, -1, -2, -3, -4])
    expect(cbuf.length).to eq(2)
    expect(cbuf.available).to eq(5)

    expect(cbuf.read(2)).to eq(Numo::SFloat[-5, -6])
    expect(cbuf.length).to eq(0)
    expect(cbuf.available).to eq(7)

    expect(cbuf.write(Numo::SFloat[1,2,3,4,5,6,7])).to eq(7)
    expect(cbuf.length).to eq(7)
    expect(cbuf.available).to eq(0)

    expect(cbuf.read(7)).to eq(Numo::SFloat[1,2,3,4,5,6,7])
    expect(cbuf.length).to eq(0)
    expect(cbuf.available).to eq(7)
  end

  it 'can fill and drain the entire buffer in a single call' do
    expect { cbuf.write(Numo::SFloat[1,2,3,4,5,6,7]) }.not_to raise_error
    expect(cbuf.read(7)).to eq(Numo::SFloat[1,2,3,4,5,6,7])
  end

  context 'with complex values' do
    it 'can write and read complex values' do
      cbuf.write(Numo::SComplex[1i, 1+1i])
      expect(cbuf.read(2)).to be_a(Numo::SComplex).and eq(Numo::SComplex[1i, 1+1i])
    end

    it 'changes buffer type to complex, preserving contents' do
      cbuf.write(Numo::SFloat[-1, 0])

      cbuf.write(Numo::SComplex[1])
      expect(cbuf.read(3)).to be_a(Numo::SComplex).and eq(Numo::SComplex[-1, 0, 1])

      cbuf.write(Numo::DComplex[2])
      expect(cbuf.read(1)).to be_a(Numo::DComplex).and eq(Numo::DComplex[2])
    end

    it 'never switches back to real after switching to complex' do
      cbuf.write(Numo::SComplex[1i])
      cbuf.read(1)
      cbuf.write(Numo::SFloat[1])
      expect(cbuf.read(1)).to be_a(Numo::SComplex).and eq(Numo::SComplex[1])
    end
  end

  context 'with double precision values' do
    it 'changes buffer type to double, preserving contents' do
      cbuf.write(Numo::SFloat[-1, 0])

      cbuf.write(Numo::DFloat[1])
      expect(cbuf.read(3)).to be_a(Numo::DFloat).and eq(Numo::DFloat[-1, 0, 1])
    end

    it 'never switches back to single precision after switching to double' do
      cbuf.write(Numo::DFloat[-1])
      cbuf.read(1)
      cbuf.write(Numo::SFloat[1])
      expect(cbuf.read(1)).to be_a(Numo::DFloat).and eq(Numo::DFloat[1])
    end
  end

  describe '#read' do
    it 'raises an error if reading from an empty buffer' do
      expect { cbuf.read(1) }.to raise_error(MB::Sound::CircularBuffer::BufferUnderflow)
    end

    it 'raises an error if reading more data than is available' do
      cbuf.write(Numo::SFloat[1,2,3,4])
      expect { cbuf.read(5) }.to raise_error(MB::Sound::CircularBuffer::BufferUnderflow)
    end

    it 'returns an empty NArray if reading zero samples' do
      expect(cbuf.read(0)).to eq(Numo::SFloat[])
      cbuf.write(Numo::DComplex[-1i])
      expect(cbuf.read(0)).to eq(Numo::DComplex[])
    end

    it 'raises an error if #reader has been called' do
      cbuf.reader
      expect { cbuf.read(0) }.to raise_error(MB::Sound::CircularBuffer::ReaderModeError)
    end
  end

  describe '#write' do
    context 'in single-reader mode' do
      it 'raises an error if writing more data than will fit in the buffer' do
        expect { cbuf.write(Numo::SFloat[1,2,3,4,5,6,7,8]) }.to raise_error(MB::Sound::CircularBuffer::BufferOverflow)

        cbuf.write(Numo::DComplex[1,2])
        expect { cbuf.write(Numo::SFloat[1,2,3,4,5,6]) }.to raise_error(MB::Sound::CircularBuffer::BufferOverflow)
      end
    end

    context 'in multi-reader mode' do
      it 'can write up to the position of the slowest reader' do
        r1 = cbuf.reader
        r2 = cbuf.reader(3)

        expect { cbuf.write(Numo::SFloat[1,2,3,4]) }.not_to raise_error

        expect(r1.read(2)).to eq(Numo::SFloat[1,2])
        expect(r2.read(4)).to eq(Numo::SFloat[0,0,0,1])
      end

      it 'raises an error if the write would pass any of the read positions' do
        _r1 = cbuf.reader
        _r2 = cbuf.reader(3)

        expect { cbuf.write(Numo::SFloat[1,2,3,4,5]) }.to raise_error(MB::Sound::CircularBuffer::BufferOverflow)
      end
    end
  end

  describe '#reader' do
    it 'can create multiple readers' do
      r1 = cbuf.reader
      r2 = cbuf.reader
      r3 = cbuf.reader

      cbuf.write(Numo::SFloat[1,2,3,4,5,6,7])

      expect(r1.read(7)).to eq(Numo::SFloat[1,2,3,4,5,6,7])
      expect(r2.read(4)).to eq(Numo::SFloat[1,2,3,4])
      expect(r3.read(3)).to eq(Numo::SFloat[1,2,3])
      expect(r2.read(2)).to eq(Numo::SFloat[5,6])
      expect(r3.read(1)).to eq(Numo::SFloat[4])
    end

    it 'creates readers at the write pointer' do
      r1 = cbuf.reader
      cbuf.write(Numo::SFloat[5,4,3])
      r2 = cbuf.reader
      cbuf.write(Numo::SFloat[-1,-2])
      expect(r1.read(4)).to eq(Numo::SFloat[5,4,3,-1])
      expect(r2.read(2)).to eq(Numo::SFloat[-1,-2])
    end

    it 'can create a delayed reader' do
      r1 = cbuf.reader(5)
      expect(r1.length).to eq(5)
      expect(cbuf.available).to eq(2)
      expect { cbuf.write(Numo::SFloat[1,2,3]) }.to raise_error(MB::Sound::CircularBuffer::BufferOverflow)
    end

    it 'raises an error if #write was called before calling #reader' do
      cbuf.write(Numo::SFloat[1])
      expect { cbuf.reader }.to raise_error(MB::Sound::CircularBuffer::ReaderModeError)
    end

    it 'raises an error if #read has been called' do
      cbuf.read(0)
      expect { cbuf.reader }.to raise_error(MB::Sound::CircularBuffer::ReaderModeError)
    end

    it 'raises an error if #length has been called' do
      cbuf.length
      expect { cbuf.reader }.to raise_error(MB::Sound::CircularBuffer::ReaderModeError)
    end

    it 'raises an error if #available was called first' do
      cbuf.available
      expect { cbuf.reader }.to raise_error(MB::Sound::CircularBuffer::ReaderModeError)
    end

    it 'raises an error if #empty? was called first' do
      cbuf.empty?
      expect { cbuf.reader }.to raise_error(MB::Sound::CircularBuffer::ReaderModeError)
    end
  end

  describe '#length' do
    context 'in multi-reader mode' do
      it 'raises an error' do
        cbuf.reader
        expect { cbuf.length }.to raise_error(MB::Sound::CircularBuffer::ReaderModeError)
      end
    end

    context 'in single-reader mode' do
      it 'returns samples available for writing' do
        expect(cbuf.length).to eq(0)
        cbuf.write(Numo::SFloat[1,2,3])
        expect(cbuf.length).to eq(3)
      end
    end
  end

  describe '#available' do
    context 'in multi-reader mode' do
      it 'returns the samples that can be written without passing the furthest-behind reader' do
        cbuf.reader
        expect(cbuf.available).to eq(7)
        cbuf.reader(2)
        expect(cbuf.available).to eq(5)
        cbuf.reader(7)
        expect(cbuf.available).to eq(0)
      end
    end

    context 'in single-reader mode' do
      it 'returns the number of samples that can be written' do
        expect(cbuf.available).to eq(7)
        cbuf.write(Numo::SFloat[1,2,3])
        expect(cbuf.available).to eq(4)
      end
    end
  end

  describe '#empty?' do
    context 'in multi-reader mode' do
      it 'returns true if all readers are empty' do
      end
    end

    context 'in single-reader mode' do
      it 'returns true if no samples are available for reading' do

      end
    end
  end

  # TODO: add specs here if resizing is implemented
  pending 'can be resized'
end
