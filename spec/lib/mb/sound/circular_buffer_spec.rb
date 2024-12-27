RSpec.describe(MB::Sound::CircularBuffer, :aggregate_failures) do
  let(:cbuf) { MB::Sound::CircularBuffer.new(buffer_size: 7) }

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
  end

  describe '#write' do
    it 'raises an error if writing more data than will fit in the buffer' do
      expect { cbuf.write(Numo::SFloat[1,2,3,4,5,6,7,8]) }.to raise_error(MB::Sound::CircularBuffer::BufferOverflow)

      cbuf.write(Numo::DComplex[1,2])
      expect { cbuf.write(Numo::SFloat[1,2,3,4,5,6]) }.to raise_error(MB::Sound::CircularBuffer::BufferOverflow)
    end
  end

  # TODO: add specs here if resizing is implemented
  pending 'can be resized'
end
