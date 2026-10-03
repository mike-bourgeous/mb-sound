RSpec.describe(MB::FastSound) do
  describe '#narray_log' do
    it 'calculates the natural logarithm of SFloat' do
      data = Numo::SFloat[[1,2],[3,4]]
      expected = Numo::SFloat[[Math.log(1), Math.log(2)], [Math.log(3), Math.log(4)]]
      expect(MB::FastSound.narray_log(data)).to eq(expected)
    end

    it 'calculates the natural logarithm of DFloat' do
      data = Numo::DFloat[[1,2],[3,4]]
      expected = Numo::DFloat[[Math.log(1), Math.log(2)], [Math.log(3), Math.log(4)]]
      expect(MB::FastSound.narray_log(data)).to eq(expected)
    end

    it 'calculates the natural logarithm of SComplex' do
      data = Numo::SComplex[[1+1i,2+2i],[3+3i,4+4i]]
      expected = Numo::SComplex[[CMath.log(1+1i), CMath.log(2+2i)], [CMath.log(3+3i), CMath.log(4+4i)]]
      expect(MB::M.round(MB::FastSound.narray_log(data), 6)).to eq(MB::M.round(expected, 6))
    end

    it 'calculates the natural logarithm of DComplex' do
      data = Numo::DComplex[[1+1i,2+2i],[3+3i,4+4i]]
      expected = Numo::DComplex[[CMath.log(1+1i), CMath.log(2+2i)], [CMath.log(3+3i), CMath.log(4+4i)]]
      expect(MB::M.round(MB::FastSound.narray_log(data), 12)).to eq(MB::M.round(expected, 12))
    end
  end

  describe '#narray_log2' do
    it 'calculates the base two logarithm of SFloat' do
      data = Numo::SFloat[[1,2],[3,4]]
      expected = Numo::SFloat[[Math.log2(1), 1], [Math.log2(3), 2]]
      expect(MB::FastSound.narray_log2(data)).to eq(expected)
    end

    it 'calculates the base two logarithm of DFloat' do
      data = Numo::DFloat[[1,2],[3,4]]
      expected = Numo::DFloat[[Math.log2(1), 1], [Math.log2(3), 2]]
      expect(MB::FastSound.narray_log2(data)).to eq(expected)
    end

    it 'calculates the base two logarithm of SComplex' do
      data = Numo::SComplex[[1+1i,2+2i],[3+3i,4+4i]]
      expected = Numo::SComplex[[CMath.log2(1+1i), CMath.log2(2+2i)], [CMath.log2(3+3i), CMath.log2(4+4i)]]
      expect(MB::M.round(MB::FastSound.narray_log2(data), 5)).to eq(MB::M.round(expected, 5))
    end

    it 'calculates the base two logarithm of DComplex' do
      data = Numo::DComplex[[1+1i,2+2i],[3+3i,4+4i]]
      expected = Numo::DComplex[[CMath.log2(1+1i), CMath.log2(2+2i)], [CMath.log2(3+3i), CMath.log2(4+4i)]]
      expect(MB::M.round(MB::FastSound.narray_log2(data), 12)).to eq(MB::M.round(expected, 12))
    end
  end

  describe '#narray_log10' do
    it 'calculates the base ten logarithm of SFloat' do
      data = Numo::SFloat[[1,2],[3,4]]
      expected = Numo::SFloat[[Math.log10(1), Math.log10(2)], [Math.log10(3), Math.log10(4)]]
      expect(MB::M.round(MB::FastSound.narray_log10(data), 6)).to eq(MB::M.round(expected, 6))
    end

    it 'calculates the base ten logarithm of DFloat' do
      data = Numo::DFloat[[1,2],[3,4]]
      expected = Numo::DFloat[[Math.log10(1), Math.log10(2)], [Math.log10(3), Math.log10(4)]]
      expect(MB::FastSound.narray_log10(data)).to eq(expected)
    end

    it 'calculates the base ten logarithm of SComplex' do
      data = Numo::SComplex[[1+1i,2+2i],[3+3i,4+4i]]
      expected = Numo::SComplex[[CMath.log10(1+1i), CMath.log10(2+2i)], [CMath.log10(3+3i), CMath.log10(4+4i)]]
      expect(MB::M.round(MB::FastSound.narray_log10(data), 6)).to eq(MB::M.round(expected, 6))
    end

    it 'calculates the base ten logarithm of DComplex' do
      data = Numo::DComplex[[1+1i,2+2i],[3+3i,4+4i]]
      expected = Numo::DComplex[[CMath.log10(1+1i), CMath.log10(2+2i)], [CMath.log10(3+3i), CMath.log10(4+4i)]]
      expect(MB::M.round(MB::FastSound.narray_log10(data), 12)).to eq(MB::M.round(expected, 12))
    end
  end

  describe '#number_to_freq' do
    it 'converts note numbers to frequencies' do
      expect(MB::FastSound.number_to_freq(69, 69, 420)).to eq(420)
      expect(MB::FastSound.number_to_freq(57, 69, 420)).to eq(210)
    end

    it 'respects tune_note' do
      expect(MB::FastSound.number_to_freq(69, 57, 420)).to eq(840)
    end

    it 'respects tune_freq' do
      expect(MB::FastSound.number_to_freq(69, 69, 440)).to eq(440)
    end
  end

  describe '.matrix_mix' do
    let(:matrix) { Numo::DFloat[[1, -1, 0.5], [0, 2, -1]] }
    let(:inputs) { [Numo::SFloat[1, 2, 3, 9], Numo::SFloat[4, 5, 6, 9], Numo::SFloat[-2, 0, 2, 9]] }

    it 'multiplies the input column by the matrix into the outputs' do
      outputs = [Numo::SFloat.new(3).fill(7), Numo::SFloat.new(3).fill(7)]
      expect(MB::FastSound.matrix_mix(matrix, inputs, outputs)).to equal(outputs)
      expect(outputs[0].to_a).to eq([-4, -3, -2])
      expect(outputs[1].to_a).to eq([10, 10, 10])
    end

    it 'matches the Ruby Matrix product of NArrays' do
      m = Numo::DFloat.new(4, 4).rand(-1, 1)
      data = Array.new(4) { Numo::SFloat.new(100).rand(-1, 1) }
      expected = (Matrix[*m.to_a] * Vector[*data]).to_a
      result = MB::FastSound.matrix_mix(m, data, Array.new(4) { Numo::SFloat.zeros(100) })
      result.each_with_index do |r, idx|
        expect(r).to eq(expected[idx])
      end
    end

    it 'rejects outputs that are also inputs' do
      expect { MB::FastSound.matrix_mix(matrix, inputs, [inputs[0][0...3], Numo::SFloat.zeros(3)]) }.to raise_error(ArgumentError, /contiguous|also input/)
      expect { MB::FastSound.matrix_mix(matrix, inputs, [inputs[1], Numo::SFloat.zeros(4)]) }.to raise_error(ArgumentError, /also input/)
    end

    it 'rejects the wrong number or type of channels' do
      expect { MB::FastSound.matrix_mix(matrix, inputs[0..1], [Numo::SFloat.zeros(3)] * 2) }.to raise_error(ArgumentError, /inputs/)
      expect { MB::FastSound.matrix_mix(matrix, inputs, [Numo::SFloat.zeros(3)]) }.to raise_error(ArgumentError, /outputs/)
      expect { MB::FastSound.matrix_mix(matrix, inputs.map(&:to_a), [Numo::SFloat.zeros(3)] * 2) }.to raise_error(ArgumentError, /SFloat/)
      expect { MB::FastSound.matrix_mix(matrix, inputs, [Numo::SFloat.zeros(9), Numo::SFloat.zeros(9)]) }.to raise_error(ArgumentError, /shorter/)
    end
  end
end
