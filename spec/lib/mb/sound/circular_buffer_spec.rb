RSpec.describe(MB::Sound::CircularBuffer) do
  it 'can read and write data' do
    cbuf = MB::Sound::CircularBuffer.new(buffer_size: 7)
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

  pending 'with complex values'
  pending 'with double precision values'

  pending 'raises errors on buffer underflow and overflow'
  pending 'can be resized'
  pending 'can be switched from real to complex'
  pending 'when reading zero samples'
end
