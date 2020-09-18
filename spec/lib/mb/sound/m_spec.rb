RSpec.describe MB::Sound::M do
  describe '.scale' do
    it 'acceps reverse ranges' do
      expect(MB::Sound::M.scale(0.5, -1.0..1.0, 1.0..-1.0)).to eq(-0.5)
      expect(MB::Sound::M.scale(0.5, 1.0..-1.0, -1.0..1.0)).to eq(-0.5)
      expect(MB::Sound::M.scale(0.5, 1.0..-1.0, 2.0..1.0)).to eq(1.75)
    end

    it 'can scale an NArray' do
      expect(MB::Sound::M.scale(Numo::SFloat[1, 2, 3], 0.0..1.0, 0.0..2.0)).to eq(Numo::SFloat[2, 4, 6])
    end
  end

  describe '.clamp' do
    it 'passes through valid values' do
      expect(MB::Sound::M.clamp(0, 1, 0.5)).to eq(0.5)
    end

    it 'returns max for high values' do
      expect(MB::Sound::M.clamp(0, 1, 1.5)).to eq(1)
    end

    it 'returns min for low values' do
      expect(MB::Sound::M.clamp(0, 1, -1)).to eq(0)
    end

    it 'passes through high values but not low values if max is nil' do
      expect(MB::Sound::M.clamp(0, nil, Float::MAX)).to eq(Float::MAX)
      expect(MB::Sound::M.clamp(0, nil, -Float::MAX)).to eq(0)
      expect(MB::Sound::M.clamp(0, nil, 1)).to eq(1)
      expect(MB::Sound::M.clamp(0, nil, -1)).to eq(0)
    end

    it 'passes through low values but not high values if min is nil' do
      expect(MB::Sound::M.clamp(nil, 1, Float::MAX)).to eq(1)
      expect(MB::Sound::M.clamp(nil, 1, -Float::MAX)).to eq(-Float::MAX)
      expect(MB::Sound::M.clamp(nil, 1, 0.1)).to eq(0.1)
      expect(MB::Sound::M.clamp(nil, 1, 1.1)).to eq(1)
    end

    it 'can clamp an NArray' do
      expect(MB::Sound::M.clamp(-1, 1, Numo::SFloat[-3, -2, -1, 0, 1, 2, 3])).to eq(Numo::SFloat[-1, -1, -1, 0, 1, 1, 1])
    end

    it 'converts ints to to floats if clamping an integer narray to a float range' do
      expect(MB::Sound::M.clamp(-1.5, 1.5, Numo::Int32[-3, -2, -1, 0, 1, 2, 3])).to eq(Numo::SFloat[-1.5, -1.5, -1, 0, 1, 1.5, 1.5])
    end
  end

  describe '.safe_power' do
    it 'scales positive values' do
      expect(MB::Sound::M.safe_power(0.25, 0.5)).to eq(0.5)
    end

    it 'scales negative values' do
      expect(MB::Sound::M.safe_power(-0.25, 0.5)).to eq(-0.5)
    end
  end

  describe '.array_to_narray' do
    it 'converts a 1D array' do
      expect(MB::Sound::M.array_to_narray([1,2,3])).to eq(Numo::NArray[1,2,3])
    end

    it 'converts a 2D array' do
      expect(MB::Sound::M.array_to_narray([[1,2],[3,4]])).to eq(Numo::NArray[[1,2],[3,4]])
    end

    it 'converts a 3D array' do
      expect(MB::Sound::M.array_to_narray([[[1,2],[3,4]],[[5,6],[7,8]]])).to eq(Numo::NArray[[[1,2],[3,4]],[[5,6],[7,8]]])
    end
  end
end
