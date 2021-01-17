RSpec.describe(MB::Sound::A) do
  describe '.append_shift' do
    let(:base) { Numo::SFloat[1,2,3,4,5].freeze }

    it 'leaves the array unmodified and returns an empty array for a zero-length append' do
      data = base.copy
      expect(MB::Sound::A.append_shift(data, Numo::SFloat[])).to eq(Numo::SFloat[])
      expect(data).to eq(base)
    end

    it 'returns the original array and entirely replaces its contents for an equal-length append' do
      data = base.copy
      append = Numo::SFloat[5,4,3,2,1].freeze
      result = MB::Sound::A.append_shift(data, append)
      expect(result).to eq(base)
      expect(data).to eq(append)
    end

    it 'returns the expected shifted values for a partial append' do
      data = base.copy
      append = Numo::SFloat[6,7].freeze
      expect(MB::Sound::A.append_shift(data, append)).to eq(Numo::SFloat[1,2])
      expect(MB::Sound::A.append_shift(data, append)).to eq(Numo::SFloat[3,4])

      MB::Sound::A.append_shift(data, append)
      expect(data).to eq(Numo::SFloat[7,6,7,6,7])
    end
  end

  describe '.pad' do
    it 'can right-pad with a single value' do
      expect(MB::Sound::A.pad(Numo::SFloat[1], 3, value: 2, alignment: 0)).to eq(Numo::SFloat[1, 2, 2])
    end

    it 'can left-pad with a single value' do
      expect(MB::Sound::A.pad(Numo::SFloat[1], 3, value: 2, alignment: 1)).to eq(Numo::SFloat[2, 2, 1])
    end

    it 'can center with a single value' do
      expect(MB::Sound::A.pad(Numo::SFloat[1], 3, value: 2, alignment: 0.5)).to eq(Numo::SFloat[2, 1, 2])
      expect(MB::Sound::A.pad(Numo::SFloat[1], 5, value: 2, alignment: 0.5)).to eq(Numo::SFloat[2, 2, 1, 2, 2])
    end

    it 'can bias alignment left' do
      expect(MB::Sound::A.pad(Numo::SFloat[1], 5, before: 0, after: 2, alignment: 0.25)).to eq(Numo::SFloat[0, 1, 2, 2, 2])
    end

    it 'can bias alignment right' do
      expect(MB::Sound::A.pad(Numo::SFloat[1], 5, before: 0, after: 2, alignment: 0.75)).to eq(Numo::SFloat[0, 0, 0, 1, 2])
    end

    it 'can left-pad an empty narray' do
      expect(MB::Sound::A.pad(Numo::SFloat[], 4, before: 1, after: 2, alignment: 0)).to eq(Numo::SFloat[2, 2, 2, 2])
    end

    it 'can left-biased-pad an empty narray' do
      expect(MB::Sound::A.pad(Numo::SFloat[], 4, before: 1, after: 2, alignment: 0.25)).to eq(Numo::SFloat[1, 2, 2, 2])
    end

    it 'can center-pad an empty narray' do
      expect(MB::Sound::A.pad(Numo::SFloat[], 2, before: 1, after: 2, alignment: 0.5)).to eq(Numo::SFloat[1, 2])
    end

    it 'can right-biased-pad an empty narray' do
      expect(MB::Sound::A.pad(Numo::SFloat[], 4, before: 1, after: 2, alignment: 0.75)).to eq(Numo::SFloat[1, 1, 1, 2])
    end

    it 'can right-pad an empty narray' do
      expect(MB::Sound::A.pad(Numo::SFloat[], 4, before: 1, after: 2, alignment: 1)).to eq(Numo::SFloat[1, 1, 1, 1])
    end

    it 'leaves an empty narray alone when the target size is zero' do
      result = MB::Sound::A.pad(Numo::SFloat[], 0, before: 1, after: 2, alignment: 0.5)
      expect(result).to be_a(Numo::SFloat)
      expect(result.length).to eq(0)
    end

    it 'can pad a complex narray' do
      result = MB::Sound::A.pad(Numo::DComplex[1+0i, 0+1i], 4, before: 2, after: -2, alignment: 0.5)
      expect(result).to be_a(Numo::DComplex)
      expect(result).to eq(Numo::DComplex[2, 1+0i, 0+1i, -2])
    end

    fromto = [
      [3, 4],
      [3, 5],
      [17, 31],
      [17, 32],
      [1000, 563567],
    ]

    alignments = [0.0, 0.25, (1.0 / 3.0), 0.5, (5.0 / 7.0), 0.9, 1.0]

    fromto.each do |(from_size, to_size)|
      alignments.each do |align|
        it "results in the correct length for #{from_size}->#{to_size}@#{align.round(5)}" do
          base = Numo::SFloat.zeros(from_size)
          expect(MB::Sound::A.pad(base, to_size, alignment: align).length).to eq(to_size)
        end
      end
    end
  end

  describe '.zpad' do
    it 'defaults to right-pad' do
      expect(MB::Sound::A.zpad(Numo::SFloat[1], 2)).to eq(Numo::SFloat[1, 0])
    end

    it 'can pad an empty narray' do
      expect(MB::Sound::A.zpad(Numo::SFloat[], 2)).to eq(Numo::SFloat[0, 0])
    end
  end

  describe '.opad' do
    it 'defaults to right-pad' do
      expect(MB::Sound::A.opad(Numo::SFloat[2], 2)).to eq(Numo::SFloat[2, 1])
    end

    it 'can pad an empty narray' do
      expect(MB::Sound::A.opad(Numo::SFloat[], 2)).to eq(Numo::SFloat[1, 1])
    end
  end

  describe '.rol' do
    it 'returns the same array with a rotation of 0' do
      expect(MB::Sound::A.rol(Numo::SFloat[1,2,3], 0)).to eq(Numo::SFloat[1,2,3])
    end

    it 'can rotate left' do
      expect(MB::Sound::A.rol(Numo::SFloat[1,2,3], 1)).to eq(Numo::SFloat[2,3,1])
      expect(MB::Sound::A.rol(Numo::SFloat[1,2,3], 2)).to eq(Numo::SFloat[3,1,2])
    end

    it 'can rotate right' do
      expect(MB::Sound::A.rol(Numo::SFloat[1,2,3], -1)).to eq(Numo::SFloat[3,1,2])
      expect(MB::Sound::A.rol(Numo::SFloat[1,2,3], -2)).to eq(Numo::SFloat[2,3,1])
    end
  end

  describe '.ror' do
    it 'returns the same array with a rotation of 0' do
      expect(MB::Sound::A.ror(Numo::SFloat[1,2,3], 0)).to eq(Numo::SFloat[1,2,3])
    end

    it 'can rotate left' do
      expect(MB::Sound::A.ror(Numo::SFloat[1,2,3], -1)).to eq(Numo::SFloat[2,3,1])
      expect(MB::Sound::A.ror(Numo::SFloat[1,2,3], -2)).to eq(Numo::SFloat[3,1,2])
    end

    it 'can rotate right' do
      expect(MB::Sound::A.ror(Numo::SFloat[1,2,3], 1)).to eq(Numo::SFloat[3,1,2])
      expect(MB::Sound::A.ror(Numo::SFloat[1,2,3], 2)).to eq(Numo::SFloat[2,3,1])
    end
  end

  describe '.shl' do
    it 'returns the same array with a shift of 0' do
      expect(MB::Sound::A.shl(Numo::SFloat[1,2,3], 0)).to eq(Numo::SFloat[1,2,3])
    end

    it 'can shift left' do
      expect(MB::Sound::A.shl(Numo::SFloat[1,2,3], 1)).to eq(Numo::SFloat[2,3,0])
      expect(MB::Sound::A.shl(Numo::SFloat[1,2,3], 2)).to eq(Numo::SFloat[3,0,0])
      expect(MB::Sound::A.shl(Numo::SFloat[1,2,3], 3)).to eq(Numo::SFloat[0,0,0])
    end

    it 'cannot shift right' do
      expect { MB::Sound::A.shl(Numo::SFloat[1,2,3], -1) }.to raise_error(ArgumentError)
    end
  end

  describe '.shr' do
    it 'returns the same array with a shift of 0' do
      expect(MB::Sound::A.shr(Numo::SFloat[1,2,3], 0)).to eq(Numo::SFloat[1,2,3])
    end

    it 'can shift right' do
      expect(MB::Sound::A.shr(Numo::SFloat[1,2,3], 1)).to eq(Numo::SFloat[0,1,2])
      expect(MB::Sound::A.shr(Numo::SFloat[1,2,3], 2)).to eq(Numo::SFloat[0,0,1])
      expect(MB::Sound::A.shr(Numo::SFloat[1,2,3], 3)).to eq(Numo::SFloat[0,0,0])
    end

    it 'cannot shift left' do
      expect { MB::Sound::A.shr(Numo::SFloat[1,2,3], -1) }.to raise_error(ArgumentError)
    end
  end
end
