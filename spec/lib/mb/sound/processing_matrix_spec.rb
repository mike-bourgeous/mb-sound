RSpec.describe(MB::Sound::ProcessingMatrix) do
  let(:l) { Numo::SFloat[1, 2, 3, 0] }
  let(:r) { Numo::SFloat[-1, 0, 3, -4] }

  describe '.from_file' do
    let(:matrix_flat) {
      [ 1, 2, 3, 4 ]
    }
    let(:matrix_5_1) {
      [ [1], [2], [3], [4], [5] ]
    }
    let(:matrix_1_5) {
      [ [1, 2, 3, 4, 5] ]
    }
    let(:matrix_2_2) {
      [ [1, 0], [0, 1] ]
    }
    let(:matrix_complex_3_2) {
      [ [1+1i, 0], [0-1i, 1], ['0 + 1i', '2i'] ]
    }

    before(:all) {
      FileUtils.mkdir_p('tmp')
    }

    def save_matrix(ext, matrix)
      case ext
      when :csv
        File.write('tmp/matrix_test.csv', matrix.map { |row| Array(row).join(',') }.join("\n") + "\n")

      when :tsv
        File.write('tmp/matrix_test.tsv', matrix.map { |row| Array(row).join("\t") }.join("\n") + "\n")

      when :yml
        File.write('tmp/matrix_test.yml', matrix.to_yaml)

      when :json
        File.write('tmp/matrix_test.json', matrix.to_json)

      else
        raise ArgumentError
      end
    end

    [:csv, :tsv, :yml, :json].each do |ext|
      context "when reading from .#{ext}" do
        before(:each) {
          File.unlink("tmp/matrix_test.#{ext}") rescue nil
        }

        it 'can load a one-row matrix' do
          save_matrix(ext, matrix_1_5)
          p = MB::Sound::ProcessingMatrix.from_file("tmp/matrix_test.#{ext}")
          expect(p.input_channels).to eq(5)
          expect(p.output_channels).to eq(1)
        end

        it 'can load a one-column matrix' do
          save_matrix(ext, matrix_5_1)
          p = MB::Sound::ProcessingMatrix.from_file("tmp/matrix_test.#{ext}")
          expect(p.input_channels).to eq(1)
          expect(p.output_channels).to eq(5)
        end

        it 'can load a flat 1D array of numbers' do
          save_matrix(ext, matrix_flat)
          p = MB::Sound::ProcessingMatrix.from_file("tmp/matrix_test.#{ext}")
          expect(p.input_channels).to eq(1)
          expect(p.output_channels).to eq(4)
        end

        it 'can load complex numbers' do
          save_matrix(ext, matrix_complex_3_2)
          p = MB::Sound::ProcessingMatrix.from_file("tmp/matrix_test.#{ext}")
          expect(p.input_channels).to eq(2)
          expect(p.output_channels).to eq(3)
        end

        it 'raises an error if the data contains non-numeric entries' do
          save_matrix(ext, [[1, 2, 3], ['d', 'e', 'f']])
          expect {
            MB::Sound::ProcessingMatrix.from_file("tmp/matrix_test.#{ext}")
          }.to raise_error(MB::Sound::ProcessingMatrix::MatrixTypeError)
        end

        it 'raises an error if the data is not an Array' do
          save_matrix(ext, {a: 1, b: 2})
          expect {
            MB::Sound::ProcessingMatrix.from_file("tmp/matrix_test.#{ext}")
          }.to raise_error(MB::Sound::ProcessingMatrix::MatrixTypeError)
        end
      end
    end

    pending 'can load example matrix files' # TODO: create these example matrices
  end

  describe '#initialize' do
    it 'sets the expected number of input and output channels' do
      m = Matrix.build(5, 3) { 0 }
      p = MB::Sound::ProcessingMatrix.new(m)
      expect(p.input_channels).to eq(3)
      expect(p.output_channels).to eq(5)
    end

    describe '#process' do
      it 'raises an error if given the wrong number of channels' do
        m = Matrix.build(2, 4) { 0 }
        p = MB::Sound::ProcessingMatrix.new(m)
        expect { p.process([Numo::SFloat[1, 2, 3]]) }.to raise_error(/channels/)
      end

      it 'can pass through inputs unmodified when given a unit matrix' do
        m = Matrix.unit(2)
        p = MB::Sound::ProcessingMatrix.new(m)
        expect(p.process([l, r])).to eq([l, r])
      end

      it 'can swap two inputs' do
        m = Matrix[[0, 1], [1, 0]]
        p = MB::Sound::ProcessingMatrix.new(m)
        expect(p.process([l, r])).to eq([r, l])
      end

      it 'can add and subtract inputs' do
        m = Matrix[[1, 1], [-1, 1]]
        p = MB::Sound::ProcessingMatrix.new(m)
        expect(p.process([l, r])).to eq([l + r, r - l])
      end

      it 'can scale inputs' do
        m = Matrix[[2, 0], [0, 3]]
        p = MB::Sound::ProcessingMatrix.new(m)
        expect(p.process([l, r])).to eq([2 * l, 3 * r])
      end

      it 'can increase the number of outputs compared to inputs' do
        m = Matrix[[1, 0], [0, 1], [1, 1]]
        p = MB::Sound::ProcessingMatrix.new(m)
        expect(p.process([l, r])).to eq([l, r, l + r])
      end

      it 'can decrease the number of outputs compared to inputs' do
        m = Matrix[[1, -1]]
        p = MB::Sound::ProcessingMatrix.new(m)
        expect(p.process([l, r])).to eq([l - r])
      end

      it 'can use complex numbers in inputs' do
        m = Matrix[[1, 1], [1, -1]]
        p = MB::Sound::ProcessingMatrix.new(m)
        expected = [
          (l - r) * 1i,
          (l + r) * 1i
        ]
        expect(p.process([l * 1i, r * -1i])).to eq(expected)
      end

      it 'can use complex numbers in the matrix' do
        m = Matrix[[1i, 0], [0, -1i]]
        p = MB::Sound::ProcessingMatrix.new(m)
        expect(p.process([l, r])).to eq([l * 1i, r * -1i])
      end

      it 'can use complex numbers in both the inputs and matrix' do
        m = Matrix[[1i, 1i], [1i, -1i]]
        p = MB::Sound::ProcessingMatrix.new(m)
        expected = [
          r - l,
          -(l + r)
        ]
        expect(p.process([l * 1i, r * -1i])).to eq(expected)
      end
    end
  end
end
