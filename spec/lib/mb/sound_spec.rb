RSpec.describe MB::Sound do
  describe '.array_to_narray' do
    it 'converts a 1D array' do
      expect(MB::Sound.array_to_narray([1,2,3])).to eq(Numo::NArray[1,2,3])
    end

    it 'converts a 2D array' do
      expect(MB::Sound.array_to_narray([[1,2],[3,4]])).to eq(Numo::NArray[[1,2],[3,4]])
    end

    it 'converts a 3D array' do
      expect(MB::Sound.array_to_narray([[[1,2],[3,4]],[[5,6],[7,8]]])).to eq(Numo::NArray[[[1,2],[3,4]],[[5,6],[7,8]]])
    end
  end
end
