RSpec.describe(MB::Sound::MatrixProcess) do
  let(:l) { Numo::SFloat[1, 2, 3, 0] }
  let(:r) { Numo::SFloat[-1, 0, 3, -4] }

  describe '#initialize' do
    it 'sets the expected number of input and output channels' do
      m = Matrix.build(5, 3) { 0 }
      p = MB::Sound::MatrixProcess.new(m)
      expect(p.input_channels).to eq(3)
      expect(p.output_channels).to eq(5)
    end

    describe '#process' do
      it 'raises an error if given the wrong number of channels' do
        m = Matrix.build(2, 4) { 0 }
        p = MB::Sound::MatrixProcess.new(m)
        expect { p.process([Numo::SFloat[1, 2, 3]]) }.to raise_error(/channels/)
      end

      it 'can pass through inputs unmodified when given a unit matrix' do
        m = Matrix.unit(2)
        p = MB::Sound::MatrixProcess.new(m)
        expect(p.process([l, r])).to eq([l, r])
      end

      it 'can swap two inputs' do
        m = Matrix[[0, 1], [1, 0]]
        p = MB::Sound::MatrixProcess.new(m)
        expect(p.process([l, r])).to eq([r, l])
      end

      it 'can add and subtract inputs' do
        m = Matrix[[1, 1], [-1, 1]]
        p = MB::Sound::MatrixProcess.new(m)
        expect(p.process([l, r])).to eq([l + r, r - l])
      end

      it 'can scale inputs' do
        m = Matrix[[2, 0], [0, 3]]
        p = MB::Sound::MatrixProcess.new(m)
        expect(p.process([l, r])).to eq([2 * l, 3 * r])
      end

      it 'can increase the number of outputs compared to inputs' do
        m = Matrix[[1, 0], [0, 1], [1, 1]]
        p = MB::Sound::MatrixProcess.new(m)
        expect(p.process([l, r])).to eq([l, r, l + r])
      end

      it 'can decrease the number of outputs compared to inputs' do
        m = Matrix[[1, -1]]
        p = MB::Sound::MatrixProcess.new(m)
        expect(p.process([l, r])).to eq([l - r])
      end

      it 'can use complex numbers in inputs' do
        m = Matrix[[1, 1], [1, -1]]
        p = MB::Sound::MatrixProcess.new(m)
        expected = [
          (l - r) * 1i,
          (l + r) * 1i
        ]
        expect(p.process([l * 1i, r * -1i])).to eq(expected)
      end

      it 'can use complex numbers in the matrix' do
        m = Matrix[[1i, 0], [0, -1i]]
        p = MB::Sound::MatrixProcess.new(m)
        expect(p.process([l, r])).to eq([l * 1i, r * -1i])
      end

      it 'can use complex numbers in both the inputs and matrix' do
        m = Matrix[[1i, 1i], [1i, -1i]]
        p = MB::Sound::MatrixProcess.new(m)
        expected = [
          r - l,
          -(l + r)
        ]
        expect(p.process([l * 1i, r * -1i])).to eq(expected)
      end
    end
  end
end
