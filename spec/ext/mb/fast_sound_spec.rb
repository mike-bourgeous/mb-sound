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
end
